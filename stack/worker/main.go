// Temporal worker for the time-warp demo.
//
// Runs in a warped sandbox next to the Temporal server (same multiplier, started
// together). The UI on the normal runtime reaches it over plain HTTP, never over
// gRPC: a gRPC deadline set on a normal clock and read on a warped one expires
// at once. See docs/temporal-plan.md.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	enums "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/worker"
)

const taskQueue = "timewarp"

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func dur(k, def string) time.Duration {
	d, err := time.ParseDuration(env(k, def))
	if err != nil {
		log.Fatalf("%s: %v", k, err)
	}
	return d
}

func main() {
	// Defaults are for the 30x runtime: 15m is 30 real seconds.
	durations := Durations{
		BonusTerm:      dur("BONUS_TERM", "90m"),
		StatementEvery: dur("STATEMENT_EVERY", "20m"),
		RetryInitial:   dur("RETRY_INITIAL", "1m"),
		SLATimeout:     dur("SLA_TIMEOUT", "20m"),
		HeartbeatStep:  dur("HEARTBEAT_STEP", "1m"),
	}

	// Postgres in a warped sandbox drops idle connections in warped time; keep
	// the pool shallow and short-lived, like the UI does.
	pgcfg, err := pgxpool.ParseConfig(env("DATABASE_URL", "postgres://postgres:postgres@pg:5432/timewarp"))
	if err != nil {
		log.Fatal(err)
	}
	pgcfg.MaxConns = 4
	pgcfg.MaxConnIdleTime = 10 * time.Second
	pgcfg.MaxConnLifetime = 20 * time.Second
	db, err := pgxpool.NewWithConfig(context.Background(), pgcfg)
	if err != nil {
		log.Fatal(err)
	}
	acts := &Activities{db: db}

	var c client.Client
	for attempt := 1; ; attempt++ {
		c, err = client.Dial(client.Options{HostPort: env("TEMPORAL_ADDRESS", "temporal:7233")})
		if err == nil {
			break
		}
		if attempt >= 60 {
			log.Fatalf("temporal: %v", err)
		}
		log.Printf("waiting for temporal (attempt %d): %v", attempt, err)
		time.Sleep(2 * time.Second)
	}
	defer c.Close()

	w := worker.New(c, taskQueue, worker.Options{
		// Default 10 s; at 30x that is 0.3 real seconds and every task would fall
		// off the sticky queue. Hours are free in warped time.
		StickyScheduleToStartTimeout: time.Hour,
	})
	w.RegisterWorkflow(LoyaltyBonus)
	w.RegisterWorkflow(StatementCycle)
	w.RegisterWorkflow(FlakyReconciliation)
	w.RegisterWorkflow(SlaEscalation)
	w.RegisterWorkflow(LongHeartbeat)
	w.RegisterWorkflow(NightlyClose)
	w.RegisterActivity(acts)
	if err := w.Start(); err != nil {
		log.Fatal(err)
	}
	defer w.Stop()

	ensureSchedule(c, env("CLOSE_CRON", "*/5 * * * *"))

	start := func(ctx context.Context, id string, wf any, args ...any) error {
		_, err := c.ExecuteWorkflow(ctx, client.StartWorkflowOptions{
			ID:                    id,
			TaskQueue:             taskQueue,
			WorkflowIDReusePolicy: enums.WORKFLOW_ID_REUSE_POLICY_REJECT_DUPLICATE,
		}, wf, args...)
		var already *serviceerror.WorkflowExecutionAlreadyStarted
		if errors.As(err, &already) {
			return nil
		}
		return err
	}
	jsonErr := func(w http.ResponseWriter, err error) {
		log.Print(err)
		http.Error(w, err.Error(), 500)
	}

	// POST /start {"depositId": N}: the UI calls this for every deposit, more
	// than once. Stable workflow IDs make it idempotent.
	http.HandleFunc("/start", func(w http.ResponseWriter, r *http.Request) {
		var body struct{ DepositID int64 `json:"depositId"` }
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.DepositID == 0 {
			http.Error(w, "depositId required", 400)
			return
		}
		id := strconv.FormatInt(body.DepositID, 10)
		if err := start(r.Context(), "bonus-"+id, LoyaltyBonus, body.DepositID, durations); err != nil {
			jsonErr(w, err)
			return
		}
		if err := start(r.Context(), "statements-"+id, StatementCycle, body.DepositID, durations); err != nil {
			jsonErr(w, err)
			return
		}
		w.WriteHeader(202)
	})

	// POST /run {"workflow": "FlakyReconciliation" | "SlaEscalation" | "LongHeartbeat", "id": "..."}
	http.HandleFunc("/run", func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Workflow, ID string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.ID == "" {
			body.ID = time.Now().UTC().Format("20060102T150405.000")
		}
		var err error
		switch body.Workflow {
		case "FlakyReconciliation":
			err = start(r.Context(), "recon-"+body.ID, FlakyReconciliation, durations)
		case "SlaEscalation":
			err = start(r.Context(), "sla-"+body.ID, SlaEscalation, body.ID, durations)
		case "LongHeartbeat":
			err = start(r.Context(), "heartbeat-"+body.ID, LongHeartbeat, durations)
		default:
			http.Error(w, "unknown workflow", 400)
			return
		}
		if err != nil {
			jsonErr(w, err)
			return
		}
		w.WriteHeader(202)
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })

	addr := ":" + env("PORT", "8088")
	log.Printf("timewarp worker: task queue %q, http %s, durations %+v", taskQueue, addr, durations)
	log.Fatal(http.ListenAndServe(addr, nil))
}

// ensureSchedule creates the cron Schedule once; AlreadyScheduled is fine.
func ensureSchedule(c client.Client, cron string) {
	_, err := c.ScheduleClient().Create(context.Background(), client.ScheduleOptions{
		ID:   "nightly-close",
		Spec: client.ScheduleSpec{CronExpressions: []string{cron}},
		Action: &client.ScheduleWorkflowAction{
			ID: "nightly-close-run", Workflow: NightlyClose, TaskQueue: taskQueue,
		},
	})
	if err != nil && !errors.Is(err, temporal.ErrScheduleAlreadyRunning) {
		log.Printf("schedule: %v", err)
	}
}
