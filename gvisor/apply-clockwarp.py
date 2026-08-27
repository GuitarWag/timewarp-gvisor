#!/usr/bin/env python3
"""Apply the clock-warp patch to a gVisor checkout.

Scales the sentry's published monotonic + realtime clocks by a multiplier, at
BOTH publish points:
  - the vDSO param page  -> warps userspace vDSO reads (incl. Go)
  - Timekeeper.GetTime    -> warps syscall reads and the sentry timer subsystem

The multiplier is delivered through a real runsc flag, --timewarp-multiplier,
which runsc serializes into the boot (sentry) process. (Env vars and host files
do NOT reach the sentry: it gets a clean env and a restricted mount namespace.)
Default 1 = unchanged.

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

var (
\ttimewarpMonoAnchor int64
\ttimewarpRealAnchor int64
\ttimewarpOnce       sync.Once
)

// warpRef rebases a published BaseRef onto the virtual timeline. The large
// epoch part stays int64; only the (small) delta is scaled in float64.
func warpRef(baseRef, anchor int64) int64 { return anchor + int64(float64(baseRef-anchor)*timewarpMul) }

// warpFreq divides frequency by the multiplier so each cycle maps to more ns.
func warpFreq(freq uint64) uint64 { return uint64(float64(freq) / timewarpMul) }

// warpTime scales a computed time value onto the virtual timeline.
func warpTime(now, anchor int64) int64 { return anchor + int64(float64(now-anchor)*timewarpMul) }

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
     '\tlog.Infof("TIMEWARP: multiplier=%v", timewarpMul)\n'),
    ('p.monotonicBaseRef = int64(monotonicParams.BaseRef) + t.monotonicOffset',
     'p.monotonicBaseRef = warpRef(int64(monotonicParams.BaseRef)+t.monotonicOffset, timewarpMonoAnchor)'),
    ('p.monotonicFrequency = monotonicParams.Frequency',
     'p.monotonicFrequency = warpFreq(monotonicParams.Frequency)'),
    ('p.realtimeBaseRef = int64(realtimeParams.BaseRef)',
     'p.realtimeBaseRef = warpRef(int64(realtimeParams.BaseRef), timewarpRealAnchor)'),
    ('p.realtimeFrequency = realtimeParams.Frequency',
     'p.realtimeFrequency = warpFreq(realtimeParams.Frequency)'),
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
     '\tTimewarpMultiplier string `flag:"timewarp-multiplier"`\n'),
])

# ---- runsc/config/flags.go : register the flag ---------------------------
patch("runsc/config/flags.go", [
    ('func RegisterFlags(flagSet *flag.FlagSet) {\n',
     'func RegisterFlags(flagSet *flag.FlagSet) {\n'
     '\tflagSet.String("timewarp-multiplier", "1", "timewarp prototype: scale sandbox clocks by this factor")\n'),
])

# ---- runsc/boot/loader.go : feed the flag to the timekeeper --------------
patch("runsc/boot/loader.go", [
    ('\t// Create timekeeper.\n\ttk := kernel.NewTimekeeper()',
     '\t// Create timekeeper.\n'
     '\tkernel.SetTimewarpMultiplier(args.Conf.TimewarpMultiplier)\n'
     '\ttk := kernel.NewTimekeeper()'),
])

print("done")
