# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

A research prototype that warps time for **unmodified** container images (including static Go binaries) by patching gVisor's userspace kernel (the sentry). The sentry owns the vDSO and the timer subsystem, so scaling its two clocks warps wall-clock reads, monotonic reads, and timers together — the thing libfaketime cannot do because Go bypasses libc. Not for production. Apache-2.0, matching gVisor.

The core warp is proven and pinned: `--timewarp-multiplier=1000` made a 2h `time.AfterFunc` fire in 8 real seconds with zero code changes. Remaining roadmap work is the control plane around it (live rate changes, shared group anchor, wiring `authority/` to the sentry).

## Commands

There is no Makefile and no test suite; CI (`.github/workflows/ci.yml`) is the check. Reproduce it locally:

```bash
(cd authority && go build ./... && go vet ./...)
(cd victim && go build ./... && go vet ./...)
shellcheck --severity=warning scripts/*.sh stack/*.sh gvisor/*.sh

# The most important CI check — the sentry patch still applies to the pinned tag:
git clone --depth 1 --branch release-20260622.0 https://github.com/google/gvisor.git /tmp/gvisor-src
git -C /tmp/gvisor-src apply --check gvisor/clockwarp.patch
```

Runnable on macOS (control plane only, no actual warp):

```bash
./scripts/demo.sh
```

`runsc` is Linux-only. Everything that builds or runs it happens inside the Lima VM:

```bash
limactl start --name=gvisor ./lima/gvisor.yaml   # Ubuntu VM, Docker + runsc, no nested virt
./gvisor/build-runsc.sh                           # (in VM) fetch gVisor, patch, go build ./runsc
RATE=1000 ./gvisor/run-victim.sh                  # (in VM) run the unmodified victim warped
./gvisor/install-runtimes.sh                      # (in VM) register runsc-warp{,-hour,-fast} Docker runtimes
bash stack/up.sh                                  # (in VM) Postgres at 3600x + UI on host :8080
scripts/smoke-test.sh                             # (in VM) go/no-go: real images under plain runsc
```

The heavy end-to-end CI job (`build-runsc`) is opt-in via workflow_dispatch only.

## Architecture

- **`gvisor/clockwarp.patch`** — the one real change. Scales frequency and re-bases `BaseRef` for BOTH sentry clocks (monotonic + realtime) at both publish points: the vDSO param page and `Timekeeper.GetTime`. Touch-points and the transform are documented in `gvisor/PATCH.md` — read it before touching the patch.
- **`gvisor/apply-clockwarp.py`** — the patch's source of truth. It re-applies the same edits by matching source anchors, so when a gVisor bump breaks the static patch, this regenerates it. `build-runsc.sh` tries the static patch first, falls back to the script.
- **`victim/`** — an ordinary, warp-unaware Go program exercising the three reads that must warp together (wall clock, elapsed, timer). The test target.
- **`authority/`** — HTTP control plane holding `(anchorReal, anchorVirtual, multiplier)`; `virtual(t) = anchorVirtual + (t - anchorReal) * multiplier`. Builds and runs, but nothing reads it yet — the sentry gets its multiplier from the runsc flag, not from here.
- **`stack/`** — Docker demo in the VM: unmodified Postgres under the warped runtime (`runsc-warp-hour`, 3600x = 1 sim hour per real second), a normal-runtime UI (`stack/ui/`, Bun, built as `twui:latest` by `stack/up.sh`) reading its warped `now()`.
- **`k8s-lab/`** — the warp on a real workload: installs `runsc-warp` as a containerd RuntimeClass on KinD nodes and moves the local-dev Postgres pod onto it (90-day deposit matures in ~90s). Deliberately single-pod-Postgres only: distributed DBs and the gRPC mesh need the shared-anchor work first. Runbook in `k8s-lab/README.md`.

## Constraints that shape changes

- **The pinned tag lives in three places** and must move together: `gvisor/clockwarp.patch` (regenerate), `gvisor/build-runsc.sh` (`GVISOR_TAG` + `GVISOR_REF`), and `.github/workflows/ci.yml` (`GVISOR_TAG` + `GVISOR_REF`). Refresh procedure is at the bottom of `gvisor/PATCH.md`.
- **The multiplier reaches the sentry only via the runsc flag** (config → ToFlags → boot process). Env vars and host files do NOT reach the sentry — clean env, restricted mount namespace. This was the hard-won lesson; don't try to deliver config another way.
- **The build avoids bazel.** The module-proxy `@go` version of gVisor is a fully buildable tree (generated protos included); the raw git `go` branch is not. `build-runsc.sh` is just `go build ./runsc` on a patched copy of that tree.
- **Warping is per-sandbox and set at boot.** Each warped sandbox drifts from its own start time; two warped pods do not agree on wall clock at high multipliers until the `--timewarp-anchor` roadmap item exists. Don't design anything assuming group-consistent clocks yet.
