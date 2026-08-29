// A small bank: one Go binary serves the customer frontend and the API, and
// drives the interest engine. Every "now" comes from Postgres, which runs on the
// warped runtime; this process runs on the normal runtime and never reads its
// own clock for anything the customer sees.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed index.html
var static embed.FS

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	cfg, err := pgxpool.ParseConfig(env("DATABASE_URL", "postgres://postgres:postgres@bankpg:5432/bank"))
	if err != nil {
		log.Fatal(err)
	}
	// Postgres drops idle connections in warped time; keep the pool shallow and short-lived.
	cfg.MaxConns = 4
	cfg.MaxConnIdleTime = 10 * time.Second
	cfg.MaxConnLifetime = 20 * time.Second
	db, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatal(err)
	}
	for i := 1; ; i++ {
		if err := db.Ping(context.Background()); err == nil {
			break
		} else if i == 60 {
			log.Fatalf("db: %v", err)
		}
		time.Sleep(time.Second)
	}

	// The interest engine: poll on a real interval, reason in database time.
	go func() {
		for {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			if _, err := db.Exec(ctx, "SELECT bank_tick()"); err != nil {
				log.Printf("tick: %v", err)
			}
			cancel()
			time.Sleep(300 * time.Millisecond)
		}
	}()

	rows := func(w http.ResponseWriter, ctx context.Context, sql string, args ...any) {
		r, err := db.Query(ctx, sql, args...)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		out, err := pgx.CollectRows(r, pgx.RowToMap)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("content-type", "application/json")
		json.NewEncoder(w).Encode(out)
	}

	http.Handle("/", http.FileServer(http.FS(static)))

	http.HandleFunc("/api/account", func(w http.ResponseWriter, r *http.Request) {
		rows(w, r.Context(), `
			SELECT id, owner, name, number, apy, balance, round(accrued, 2) AS accrued, opened_at,
			       now() AS now,
			       date_trunc('month', current_date) + interval '1 month' AS next_posting,
			       date_trunc('month', current_date)::date AS month_start,
			       (SELECT coalesce(sum(amount), 0) FROM transactions WHERE account_id = accounts.id AND kind = 'interest') AS interest_to_date
			FROM accounts WHERE id = 1`)
	})

	http.HandleFunc("/api/transactions", func(w http.ResponseWriter, r *http.Request) {
		rows(w, r.Context(), `
			SELECT id, posted_at, kind, amount, balance_after, description
			FROM transactions WHERE account_id = 1 ORDER BY posted_at DESC, id DESC LIMIT 200`)
	})

	// One point per account day: the posted balance at end of that day plus the
	// interest accrued so far in that month. The line the customer would draw.
	http.HandleFunc("/api/series", func(w http.ResponseWriter, r *http.Request) {
		rows(w, r.Context(), `
			WITH days AS (
			  SELECT day, sum(amount) OVER (PARTITION BY date_trunc('month', day) ORDER BY day) AS accrued_mtd
			  FROM accruals WHERE account_id = 1
			)
			SELECT d.day,
			       (SELECT balance_after FROM transactions t
			         WHERE t.account_id = 1 AND t.posted_at < (d.day + 1)::timestamptz
			         ORDER BY posted_at DESC, id DESC LIMIT 1) AS posted,
			       round(d.accrued_mtd, 2) AS accrued
			FROM days d ORDER BY d.day`)
	})

	http.HandleFunc("/api/deposit", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", 405)
			return
		}
		var body struct{ Amount float64 }
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Amount <= 0 || body.Amount > 1_000_000 {
			http.Error(w, "amount must be between 0 and 1,000,000", 400)
			return
		}
		if _, err := db.Exec(r.Context(), "SELECT deposit(1, $1, 'Deposit')", body.Amount); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.WriteHeader(204)
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })

	addr := ":" + env("PORT", "8090")
	log.Printf("bank listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
