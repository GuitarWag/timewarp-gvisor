#!/usr/bin/env python3
"""Apply the clock-warp patch to a gVisor checkout.

Scales the sentry's published monotonic + realtime clocks by a multiplier, at
BOTH publish points:
  - the vDSO param page  -> warps userspace vDSO reads (incl. Go)
  - Timekeeper.GetTime    -> warps syscall reads and the sentry timer subsystem

The multiplier is delivered through a real runsc flag, --timewarp-multiplier,
which runsc serializes into the boot (sentry) process. (Env vars and host files
do NOT reach the sentry: it gets a clean env and a restricted mount namespace.)
Default 1 = unchanged. --timewarp-delay (e.g. 10s) keeps the clocks at 1x for
that long after boot so services with start-up deadlines can come up.

Usage: python3 apply-clockwarp.py /path/to/gvisor-tree
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")

def patch(rel, edits):
    f = root / rel
    s = f.read_text()
    for old, new in edits:
        n = s.count(old)
        if n != 1:
            raise SystemExit(f"{rel}: expected 1 match, found {n} for:\n{old[:120]}")
        s = s.replace(old, new)
    f.write_text(s)
    print("patched", rel)

# ---- pkg/sentry/kernel/timekeeper.go -------------------------------------
helpers = '''// timewarp (prototype): scale the sentry's published clocks by a multiplier so
// unmodified sandboxed apps see accelerated time. Set from the runsc
// --timewarp-multiplier flag (propagated to the boot process) before SetClocks.
var timewarpMul float64 = 1

// SetTimewarpMultiplier sets the global clock multiplier. Called by the boot
// loader before the timekeeper's clocks are started.
func SetTimewarpMultiplier(s string) {
\tif v, err := strconv.ParseFloat(s, 64); err == nil && v > 0 {
\t\ttimewarpMul = v
\t}
}

// timewarpDelay is how long (real time, from boot) the clocks run at 1x before
// the multiplier applies. Services with start-up deadlines (Temporal: 15 s fx
// hooks) need real time to come up; at 1000x those 15 s are 15 ms.
var timewarpDelay int64

// SetTimewarpDelay sets the start-up grace period from a Go duration string.
func SetTimewarpDelay(s string) {
\tif d, err := time.ParseDuration(s); err == nil && d > 0 {
\t\ttimewarpDelay = int64(d)
\t}
}

var (
\ttimewarpMonoAnchor int64
\ttimewarpRealAnchor int64
\ttimewarpOnce       sync.Once
)

// warpTime maps a real clock value onto the virtual timeline: identity until
// anchor+timewarpDelay, then scaled from that instant. Continuous at the switch.
// The large epoch part stays int64; only the (small) delta is scaled in float64.
func warpTime(now, anchor int64) int64 {
\tstart := anchor + timewarpDelay
\tif now <= start {
\t\treturn now
\t}
\treturn start + int64(float64(now-start)*timewarpMul)
}

// warpRef rebases a published BaseRef onto the virtual timeline.
func warpRef(baseRef, anchor int64) int64 { return warpTime(baseRef, anchor) }

// warpFreq divides frequency by the multiplier so each cycle maps to more ns,
// once ref (the BaseRef being published) is past the grace period. The vDSO
// picks the new frequency up at the next ~1 s parameter update.
func warpFreq(freq uint64, ref, anchor int64) uint64 {
\tif ref <= anchor+timewarpDelay {
\t\treturn freq
\t}
\treturn uint64(float64(freq) / timewarpMul)
}

'''
patch("pkg/sentry/kernel/timekeeper.go", [
    ('\t"fmt"\n', '\t"fmt"\n\t"strconv"\n'),
    ('func NewTimekeeper() *Timekeeper {', helpers + 'func NewTimekeeper() *Timekeeper {'),
    ('t.monotonicOffset = wantMonotonic - nowMonotonic\n',
     't.monotonicOffset = wantMonotonic - nowMonotonic\n\n'
     '\ttimewarpOnce.Do(func() {\n'
     '\t\ttimewarpRealAnchor = nowRealtime\n'
     '\t\ttimewarpMonoAnchor = nowMonotonic + t.monotonicOffset\n'
     '\t})\n'
     '\tlog.Infof("TIMEWARP: multiplier=%v delay=%v", timewarpMul, time.Duration(timewarpDelay))\n'),
    ('p.monotonicBaseRef = int64(monotonicParams.BaseRef) + t.monotonicOffset',
     'p.monotonicBaseRef = warpRef(int64(monotonicParams.BaseRef)+t.monotonicOffset, timewarpMonoAnchor)'),
    ('p.monotonicFrequency = monotonicParams.Frequency',
     'p.monotonicFrequency = warpFreq(monotonicParams.Frequency, int64(monotonicParams.BaseRef)+t.monotonicOffset, timewarpMonoAnchor)'),
    ('p.realtimeBaseRef = int64(realtimeParams.BaseRef)',
     'p.realtimeBaseRef = warpRef(int64(realtimeParams.BaseRef), timewarpRealAnchor)'),
    ('p.realtimeFrequency = realtimeParams.Frequency',
     'p.realtimeFrequency = warpFreq(realtimeParams.Frequency, int64(realtimeParams.BaseRef), timewarpRealAnchor)'),
    ('\treturn now, err\n}\n\n// BootTime returns the system boot real time.',
     '\tif err == nil {\n'
     '\t\tswitch c {\n'
     '\t\tcase sentrytime.Monotonic:\n'
     '\t\t\tnow = warpTime(now, timewarpMonoAnchor)\n'
     '\t\tcase sentrytime.Realtime:\n'
     '\t\t\tnow = warpTime(now, timewarpRealAnchor)\n'
     '\t\t}\n'
     '\t}\n'
     '\treturn now, err\n}\n\n// BootTime returns the system boot real time.'),
])

# ---- runsc/config/config.go : add the Config field -----------------------
patch("runsc/config/config.go", [
    ('\tRootDir string `flag:"root"`\n',
     '\tRootDir string `flag:"root"`\n\n'
     '\t// TimewarpMultiplier scales the sandbox clocks (timewarp prototype).\n'
     '\tTimewarpMultiplier string `flag:"timewarp-multiplier"`\n'
     '\n'
     '\t// TimewarpDelay is how long the clocks run at 1x after boot before the\n'
     '\t// multiplier applies (Go duration, e.g. "10s").\n'
     '\tTimewarpDelay string `flag:"timewarp-delay"`\n'),
])

# ---- runsc/config/flags.go : register the flag ---------------------------
patch("runsc/config/flags.go", [
    ('func RegisterFlags(flagSet *flag.FlagSet) {\n',
     'func RegisterFlags(flagSet *flag.FlagSet) {\n'
     '\tflagSet.String("timewarp-multiplier", "1", "timewarp prototype: scale sandbox clocks by this factor")\n'
     '\tflagSet.String("timewarp-delay", "0s", "timewarp prototype: run clocks at 1x for this long after boot before the multiplier applies")\n'),
])

# ---- runsc/boot/loader.go : feed the flag to the timekeeper --------------
patch("runsc/boot/loader.go", [
    ('\t// Create timekeeper.\n\ttk := kernel.NewTimekeeper()',
     '\t// Create timekeeper.\n'
     '\tkernel.SetTimewarpMultiplier(args.Conf.TimewarpMultiplier)\n'
     '\tkernel.SetTimewarpDelay(args.Conf.TimewarpDelay)\n'
     '\ttk := kernel.NewTimekeeper()'),
])

print("done")
