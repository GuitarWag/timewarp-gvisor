// The "victim": a completely ordinary Go program. It is NOT time-warp aware.
// It reads the wall clock, measures elapsed monotonic time, and arms a timer.
//
// Run it normally and it behaves normally. Run it under a clock-warped runsc
// and — with zero changes to this code — the wall clock should fly, elapsed
// time should race, and the timer (TIMER, default 24h) should fire in seconds.
//
// It exercises the three things that must all warp together:
//   1. wall-clock reads        -> time.Now()           (vDSO-backed)
//   2. monotonic/elapsed reads  -> time.Since(start)    (vDSO-backed)
//   3. sleeps/timers            -> time.AfterFunc(...)  (runtime timer)
package main

import (
	"fmt"
	"os"
	"time"
)

func main() {
	dur := 24 * time.Hour
	if v := os.Getenv("TIMER"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			dur = d
		}
	}

	start := time.Now()
	fmt.Printf("[victim] start wall=%s  timer armed for %s\n",
		start.Format(time.RFC3339), dur)

	fired := make(chan time.Time, 1)
	time.AfterFunc(dur, func() { fired <- time.Now() })

	tick := time.NewTicker(1 * time.Second)
	defer tick.Stop()
	for {
		select {
		case t := <-fired:
			fmt.Printf("[victim] *** TIMER FIRED *** wall=%s  elapsed(monotonic)=%s\n",
				t.Format(time.RFC3339), time.Since(start).Round(time.Second))
			return
		case <-tick.C:
			fmt.Printf("[victim] wall=%s  elapsed(monotonic)=%s\n",
				time.Now().Format(time.RFC3339), time.Since(start).Round(time.Second))
		}
	}
}
