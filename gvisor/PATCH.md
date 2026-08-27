# gVisor sentry clock-warp integration

This is the design for the one real change that makes everything work: teach the
gVisor **sentry** (its userspace kernel) to scale its clocks by a multiplier and
offset, read from the clock authority. Because the sentry owns both the vDSO and
the timer subsystem for the sandbox, scaling its clocks warps *everything* inside
— wall-clock reads, monotonic/elapsed reads, and sleeps/timers — for any
unmodified image, including statically-linked Go binaries.

> The patch is committed as `clockwarp.patch`, generated against gVisor
> **`release-20260622.0`** (the pinned tag, kept in sync with CI). CI re-checks
> that it still applies to that tag on every push. If you build a different tag
> and the patch will not apply, `apply-clockwarp.py` re-ports the same edits by
> matching source anchors and regenerates the patch — see "Build" below.

## Why the sentry is the right layer

A normal process reads time three ways, and all three must warp together:

| Read | How userspace does it | Who answers under gVisor |
|------|----------------------|--------------------------|
| `clock_gettime(REALTIME)` | vDSO (no syscall) | sentry's vDSO param page |
| `clock_gettime(MONOTONIC)` | vDSO (no syscall) | sentry's vDSO param page |
| `nanosleep` / timers / `epoll` timeout | syscall → runtime timer | sentry timer subsystem |

seccomp/ptrace can't see the vDSO reads, which is why libfaketime fails on Go.
gVisor *provides* the vDSO and *runs* the timer subsystem, so it sees and controls
all three. Scale the sentry's clocks and the timer queue fires early on its own —
no per-syscall sleep interception needed.

## The transform

The authority exposes the triple `(anchorReal, anchorVirtual, multiplier)`.
Virtual time is the linear map:

```
virtual(realNs) = anchorVirtual + (realNs - anchorReal) * multiplier
```

The sentry models a clock as `Parameters{BaseCycles, BaseRef, Frequency}` and
computes `ref = BaseRef + muldiv(tscNow - BaseCycles, 1e9, Frequency)`
(see `pkg/sentry/time/parameters.go`, `ComputeTime`). To run a clock `m`× faster
you divide the frequency (each cycle then maps to `m`× more nanoseconds) and shift
the base reference onto the virtual timeline:

```go
// applied to the freshly-calibrated Parameters for BOTH clocks
func warp(p Parameters, w WarpParams) Parameters {
    p.Frequency = uint64(float64(p.Frequency) / w.Multiplier) // faster time
    // re-base BaseRef onto virtual time at this calibration instant:
    realAtBase := p.BaseRef                                   // ns since boot/epoch
    p.BaseRef   = w.AnchorVirtual + int64(float64(realAtBase-w.AnchorReal)*w.Multiplier)
    return p
}
```

## Touch-points

1. **`pkg/sentry/time/calibrated_clock.go`** — `CalibratedClock.Update()` produces
   the new `Parameters` each calibration cycle (~1s). Apply `warp(...)` to the
   result before it is stored/returned. This is the single highest-leverage hook:
   it feeds both `GetTime()` and the vDSO params.

2. **`pkg/sentry/kernel/timekeeper.go`** — the `Timekeeper` owns two
   `CalibratedClock`s (monotonic + realtime) and pushes their params into the vDSO
   param page (`VDSOParamPage` / `k.vdsoParams`). Warp **both** clocks with the
   same multiplier so wall-clock and monotonic/timers stay consistent and timers
   compress. Confirm the vDSO page is updated from the warped params.

3. **Where the multiplier comes from (`WarpParams`):**
   - *Prototype (static, boot-time):* read `TIMEWARP_MULTIPLIER` (and anchors) from
     the OCI spec / env in `runsc/boot/` when the kernel is created, store on the
     `Timekeeper`. Proves the concept end to end.
   - *Live rate changes (follow-up):* add a `runsc` URPC control method
     (see `runsc/boot/controller.go`) e.g. `Timewarp.SetRate`, callable as
     `runsc timewarp <sandbox-id> --rate N`. The handler updates `WarpParams`; the
     next calibration cycle (~1s) picks it up. The CLI can fetch the triple from
     the authority's `GET /params`.

## Build

Two routes. The official one is **bazel** via the Makefile (`make runsc`), which
generates protobufs/templates as part of the build — heavy (needs Docker + lots
of RAM/disk).

The lighter route, used here, avoids bazel: the **module-proxy `@go` version** is
a post-processed, fully buildable tree (generated `*_go_proto` packages and
expanded `*_template` files included — the raw git `go` branch checkout is NOT
directly `go build`-able because those are missing). So:

```bash
# 1. fetch the buildable go-branch snapshot that contains the pinned tag (GVISOR_REF in build-runsc.sh).
#    @go itself is a moving target and drifted past the patch on 2026-08-27.
DIR=$(go mod download -json gvisor.dev/gvisor@d10071d635665b840936420353a489ca5f9f250d | sed -n 's/.*"Dir": "\(.*\)".*/\1/p')
# 2. copy that tree somewhere writable, apply the patch, build
cp -r "$DIR" ~/gvisor-build && chmod -R u+w ~/gvisor-build
python3 apply-clockwarp.py ~/gvisor-build
cd ~/gvisor-build && go build -o ~/runsc-warp ./runsc
```

`runsc` runs on **Linux only** — see `lima/gvisor.yaml` for the VM, and
`run-victim.sh` to run the victim under the patched binary.

### Patch vs. re-port

`build-runsc.sh` applies the committed `clockwarp.patch` (fast path). If it does
not apply — because the `@go` snapshot or your chosen tag has drifted from
`release-20260622.0` — the script falls back to `apply-clockwarp.py`, which finds
each touch-point by its surrounding source and re-applies the edits. To refresh
the committed patch after a gVisor bump:

```bash
git clone --depth 1 --branch <new-tag> https://github.com/google/gvisor.git src
python3 apply-clockwarp.py src
( cd src && git commit -am "timewarp patch" && git format-patch -1 --stdout ) > clockwarp.patch
```

Then update `GVISOR_TAG` and `GVISOR_REF` in `build-runsc.sh` and `.github/workflows/ci.yml`.
`GVISOR_REF` is the first go-branch commit `Merge release-...(automated)` that contains the new tag
(`git log --grep="Merge release-" origin/go`).
