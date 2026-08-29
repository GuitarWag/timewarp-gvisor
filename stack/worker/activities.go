package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.temporal.io/sdk/activity"
)

// Event is one row for the UI's feed. sim_at defaults to sim_now() in Postgres,
// so the stamp is the database's warped clock, same as every other event.
type Event struct {
	Kind      string
	DepositID int64
	Message   string
	Data      map[string]any
}

// Activities holds the DB pool. Registered on the worker as a struct so the
// pool is shared.
type Activities struct{ db *pgxpool.Pool }

func (a *Activities) insert(ctx context.Context, e Event) error {
	var dep *int64
	if e.DepositID != 0 {
		dep = &e.DepositID
	}
	data, _ := json.Marshal(e.Data)
	_, err := a.db.Exec(ctx,
		`INSERT INTO events (kind, deposit_id, message, data) VALUES ($1, $2, $3, $4)`,
		e.Kind, dep, e.Message, data)
	return err
}

// Emit writes one event.
func (a *Activities) Emit(ctx context.Context, e Event) error { return a.insert(ctx, e) }

// PayBonus adds 1% to the deposit and records it.
func (a *Activities) PayBonus(ctx context.Context, depositID int64) error {
	var amount string
	err := a.db.QueryRow(ctx,
		`UPDATE deposits SET amount = round(amount * 1.01, 2) WHERE id = $1 RETURNING amount`,
		depositID).Scan(&amount)
	if err != nil {
		return err
	}
	return a.insert(ctx, Event{
		Kind: "bonus.paid", DepositID: depositID,
		Message: fmt.Sprintf("Loyalty bonus paid, deposit now %s", amount),
		Data:    map[string]any{"amount": amount},
	})
}

// Reconcile fails on the first failUntil attempts, then succeeds. Each failure
// is recorded so the feed shows the backoff gaps growing.
func (a *Activities) Reconcile(ctx context.Context, failUntil int32) error {
	attempt := activity.GetInfo(ctx).Attempt
	if attempt <= failUntil {
		_ = a.insert(ctx, Event{
			Kind:    "temporal.retry",
			Message: fmt.Sprintf("Reconciliation attempt %d failed, retrying with backoff", attempt),
			Data:    map[string]any{"attempt": attempt},
		})
		return errors.New("upstream ledger unavailable")
	}
	return a.insert(ctx, Event{
		Kind:    "temporal.reconciled",
		Message: fmt.Sprintf("Reconciliation succeeded on attempt %d", attempt),
		Data:    map[string]any{"attempt": attempt},
	})
}

// Heartbeat sleeps in steps and heartbeats after each one.
func (a *Activities) Heartbeat(ctx context.Context, steps int, step time.Duration) error {
	for i := 1; i <= steps; i++ {
		select {
		case <-time.After(step):
		case <-ctx.Done():
			return ctx.Err()
		}
		activity.RecordHeartbeat(ctx, i)
	}
	return a.insert(ctx, Event{
		Kind:    "temporal.heartbeat",
		Message: fmt.Sprintf("Long activity finished after %d heartbeats", steps),
		Data:    map[string]any{"steps": steps},
	})
}
