// Clock authority: the single source of virtual time for a group of sandboxes.
//
// It holds the same three numbers we used in the Postgres demo, promoted to a
// control plane: an anchor in real time, the matching anchor in virtual time,
// and a multiplier. virtual(t) = anchorVirtual + (t - anchorReal) * multiplier.
//
// A patched gVisor sentry polls GET /params and uses the triple to scale its
// realtime and monotonic clocks, so every unmodified process in the sandbox
// inherits the warped clock — including the timer subsystem, which fires early
// because it measures against the same accelerated monotonic time.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

type clock struct {
	mu            sync.RWMutex
	anchorReal    time.Time
	anchorVirtual time.Time
	multiplier    float64
}

func newClock() *clock {
	now := time.Now()
	return &clock{anchorReal: now, anchorVirtual: now, multiplier: 1}
}

func (c *clock) virtual(at time.Time) time.Time {
	elapsed := at.Sub(c.anchorReal)
	scaled := time.Duration(float64(elapsed) * c.multiplier)
	return c.anchorVirtual.Add(scaled)
}

// setRate re-anchors first so virtual time stays continuous; only the slope
// changes from this instant forward.
func (c *clock) setRate(m float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	c.anchorVirtual = c.virtual(now)
	c.anchorReal = now
	c.multiplier = m
}

func (c *clock) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	c.anchorReal, c.anchorVirtual, c.multiplier = now, now, 1
}

// params is exactly what a sentry needs to compute virtual time itself.
type params struct {
	AnchorRealUnixNano    int64   `json:"anchor_real_unix_nano"`
	AnchorVirtualUnixNano int64   `json:"anchor_virtual_unix_nano"`
	Multiplier            float64 `json:"multiplier"`
}

func (c *clock) params() params {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return params{
		AnchorRealUnixNano:    c.anchorReal.UnixNano(),
		AnchorVirtualUnixNano: c.anchorVirtual.UnixNano(),
		Multiplier:            c.multiplier,
	}
}

func main() {
	addr := os.Getenv("ADDR")
	if addr == "" {
		addr = ":8099"
	}
	c := newClock()
	mux := http.NewServeMux()

	// Human-readable current virtual time.
	mux.HandleFunc("/now", func(w http.ResponseWriter, r *http.Request) {
		c.mu.RLock()
		v, m := c.virtual(time.Now()), c.multiplier
		c.mu.RUnlock()
		writeJSON(w, map[string]any{
			"real":       time.Now().Format(time.RFC3339Nano),
			"virtual":    v.Format(time.RFC3339Nano),
			"multiplier": m,
		})
	})

	// Machine-readable triple for the sentry.
	mux.HandleFunc("/params", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, c.params())
	})

	// POST /rate {"multiplier": 1000}
	mux.HandleFunc("/rate", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Multiplier float64 `json:"multiplier"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Multiplier < 0 {
			http.Error(w, "multiplier must be >= 0", http.StatusBadRequest)
			return
		}
		c.setRate(body.Multiplier)
		writeJSON(w, c.params())
	})

	mux.HandleFunc("/reset", func(w http.ResponseWriter, r *http.Request) {
		c.reset()
		writeJSON(w, c.params())
	})

	log.Printf("clock authority on %s (multiplier=1)", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
