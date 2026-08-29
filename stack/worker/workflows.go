package main

import (
	"strconv"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

// Durations is passed into every workflow as an argument. Workflows must not
// read the environment (determinism), so main reads it once and hands it over.
// Defaults are sized for the 30x runtime: the longest job is a few real minutes.
type Durations struct {
	BonusTerm      time.Duration // LoyaltyBonus: sleep before paying
	StatementEvery time.Duration // StatementCycle: gap between statements
	RetryInitial   time.Duration // FlakyReconciliation: first backoff
	SLATimeout     time.Duration // SlaEscalation: how long to wait for the signal
	HeartbeatStep  time.Duration // LongHeartbeat: gap between heartbeats
}

func activityOpts(ctx workflow.Context, timeout time.Duration) workflow.Context {
	return workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: timeout,
		RetryPolicy:         &temporal.RetryPolicy{MaximumAttempts: 3},
	})
}

// LoyaltyBonus waits out the term, then pays 1% onto the deposit. The whole
// wait is one server-side timer, so its compression is the cleanest proof.
func LoyaltyBonus(ctx workflow.Context, depositID int64, d Durations) error {
	ctx = activityOpts(ctx, time.Hour)
	if err := workflow.ExecuteActivity(ctx, "Emit", Event{
		Kind: "bonus.scheduled", DepositID: depositID,
		Message: "Loyalty bonus scheduled: 1% after " + d.BonusTerm.String(),
	}).Get(ctx, nil); err != nil {
		return err
	}
	if err := workflow.Sleep(ctx, d.BonusTerm); err != nil {
		return err
	}
	return workflow.ExecuteActivity(ctx, "PayBonus", depositID).Get(ctx, nil)
}

// StatementCycle emits three statements, one per period. A loop of timers.
func StatementCycle(ctx workflow.Context, depositID int64, d Durations) error {
	ctx = activityOpts(ctx, time.Hour)
	for i := 1; i <= 3; i++ {
		if err := workflow.Sleep(ctx, d.StatementEvery); err != nil {
			return err
		}
		if err := workflow.ExecuteActivity(ctx, "Emit", Event{
			Kind: "temporal.statement", DepositID: depositID,
			Message: "Temporal statement " + strconv.Itoa(i) + "/3 generated",
		}).Get(ctx, nil); err != nil {
			return err
		}
	}
	return nil
}

// FlakyReconciliation runs an activity that fails four times. The waits between
// attempts (1x, 2x, 4x, 8x RetryInitial) are server-side retry timers.
func FlakyReconciliation(ctx workflow.Context, d Durations) error {
	ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: time.Hour,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    d.RetryInitial,
			BackoffCoefficient: 2,
			MaximumInterval:    d.RetryInitial * 16,
			MaximumAttempts:    6,
		},
	})
	return workflow.ExecuteActivity(ctx, "Reconcile", 4).Get(ctx, nil)
}

// SlaEscalation waits for a "resolved" signal; when the SLA timer wins, it
// escalates. Nobody sends the signal in the demo, so the timer always wins.
func SlaEscalation(ctx workflow.Context, caseID string, d Durations) error {
	ctx = activityOpts(ctx, time.Hour)
	resolved := false
	sel := workflow.NewSelector(ctx)
	sel.AddReceive(workflow.GetSignalChannel(ctx, "resolved"), func(c workflow.ReceiveChannel, _ bool) {
		c.Receive(ctx, nil)
		resolved = true
	})
	sel.AddFuture(workflow.NewTimer(ctx, d.SLATimeout), func(workflow.Future) {})
	sel.Select(ctx)
	if resolved {
		return workflow.ExecuteActivity(ctx, "Emit", Event{Kind: "temporal.resolved", Message: "Case " + caseID + " resolved in time"}).Get(ctx, nil)
	}
	return workflow.ExecuteActivity(ctx, "Emit", Event{
		Kind: "temporal.escalated", Message: "Case " + caseID + " breached its " + d.SLATimeout.String() + " SLA, escalated",
	}).Get(ctx, nil)
}

// LongHeartbeat runs one activity that heartbeats 24 times. Heartbeats cross
// from the worker sandbox to the server sandbox, so this is where a clock
// offset between the two would show up as a HeartbeatTimeout.
func LongHeartbeat(ctx workflow.Context, d Durations) error {
	ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: 48 * d.HeartbeatStep,
		HeartbeatTimeout:    3 * d.HeartbeatStep,
		RetryPolicy:         &temporal.RetryPolicy{MaximumAttempts: 1},
	})
	return workflow.ExecuteActivity(ctx, "Heartbeat", 24, d.HeartbeatStep).Get(ctx, nil)
}

// NightlyClose is what the Temporal Schedule (cron) runs.
func NightlyClose(ctx workflow.Context) error {
	ctx = activityOpts(ctx, time.Hour)
	return workflow.ExecuteActivity(ctx, "Emit", Event{Kind: "temporal.close", Message: "Scheduled close run (Temporal Schedule)"}).Get(ctx, nil)
}
