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
(cd stack/worker && go build ./... && go vet ./...)
shellcheck --severity=warning scripts/*.sh stack/*.sh gvisor/*.sh k8s-lab/*.sh

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
CONTAINER=pg TERM_DAYS=2 scripts/e2e-maturity.sh  # e2e against Docker; NS=timewarp DEPLOY=postgres for k8s
CONTAINER=pg scripts/e2e-temporal.sh              # Temporal retry-backoff e2e, same backend switch
scripts/smoke-temporal.sh                         # (in VM) which multipliers the Temporal server survives
scripts/smoke-test.sh                             # (in VM) go/no-go: real images under plain runsc
```

Kubernetes lab (host side, needs `kind`, `kubectl`, Docker; binaries come from the VM):

```bash
kind create cluster --name timewarp                                  # never reuse a cluster you care about
limactl shell gvisor -- bash "$PWD/k8s-lab/build-warp-runtime.sh"    # runsc-warp + containerd shim, to ~/k8s-lab-bin (repo mount is read-only in the VM)
limactl cp -r gvisor:~/k8s-lab-bin/. k8s-lab/bin/                    # k8s-lab/bin is gitignored
KIND_CLUSTER_NAME=timewarp MULTIPLIER=3600 ./k8s-lab/inject-warp-runtime.sh
KIND_CLUSTER_NAME=timewarp ./k8s-lab/deploy-stack.sh                 # seeded Postgres (warped) + UI (normal runtime)
NS=timewarp DEPLOY=postgres TERM_DAYS=2 scripts/e2e-maturity.sh
kind delete cluster --name timewarp
```

The heavy end-to-end CI job (`build-runsc`) is opt-in via workflow_dispatch only. Remote: `origin` is `github.com/GuitarWag/timewarp-gvisor` (public, personal account).

## Architecture

- **`gvisor/clockwarp.patch`** — the one real change. Scales frequency and re-bases `BaseRef` for BOTH sentry clocks (monotonic + realtime) at both publish points: the vDSO param page and `Timekeeper.GetTime`. Touch-points and the transform are documented in `gvisor/PATCH.md` — read it before touching the patch.
- **`gvisor/apply-clockwarp.py`** — the patch's source of truth. It re-applies the same edits by matching source anchors, so when a gVisor bump breaks the static patch, this regenerates it. `build-runsc.sh` tries the static patch first, falls back to the script.
- **`victim/`** — an ordinary, warp-unaware Go program exercising the three reads that must warp together (wall clock, elapsed, timer). The test target.
- **`authority/`** — HTTP control plane holding `(anchorReal, anchorVirtual, multiplier)`; `virtual(t) = anchorVirtual + (t - anchorReal) * multiplier`. Builds and runs, but nothing reads it yet — the sentry gets its multiplier from the runsc flag, not from here.
- **`stack/`** — Docker demo in the VM: unmodified Postgres under the warped runtime (`runsc-warp-hour`, 3600x = 1 sim hour per real second), a normal-runtime UI (`stack/ui/`, Bun, built as `twui:latest` by `stack/up.sh`) reading its warped `now()`.
- **`k8s-lab/`** — the warp on a real workload: installs `runsc-warp` as a containerd RuntimeClass on KinD nodes and runs an unmodified Postgres pod on it (`postgres.yaml`; 90-day deposit matures in ~90s, verified 2026-08-28). `deploy-stack.sh` + `ui.yaml` run the `stack/` demo (seeded Postgres + UI) on the cluster at 3600x. Probes must be `tcpSocket`, not `exec`: exec probes run inside the warped sandbox and time out. Deliberately single-pod-Postgres only: distributed DBs and the gRPC mesh need the shared-anchor work first. Runbook in `k8s-lab/README.md`.

- **`stack/worker/`** — Go Temporal worker (six sample workflows, HTTP `/start`, `/run`, `/healthz`). Runs with the Temporal dev server on `runsc-warp-temporal` (30x, the server's ceiling). Every gRPC edge must stay inside one clock domain (the `grpc-timeout` header is interpreted by the receiver's clock), which is why the UI talks to the worker over plain HTTP and never to Temporal directly. Plan and findings in `docs/temporal-plan.md`.

## Constraints that shape changes

- **The pinned tag lives in three places** and must move together: `gvisor/clockwarp.patch` (regenerate), `gvisor/build-runsc.sh` (`GVISOR_TAG` + `GVISOR_REF`), and `.github/workflows/ci.yml` (`GVISOR_TAG` + `GVISOR_REF`). Refresh procedure is at the bottom of `gvisor/PATCH.md`.
- **The multiplier reaches the sentry only via the runsc flag** (config → ToFlags → boot process). Env vars and host files do NOT reach the sentry — clean env, restricted mount namespace. This was the hard-won lesson; don't try to deliver config another way.
- **The build avoids bazel.** Only the module-proxy snapshots of gVisor's `go` branch are `go build`-able (generated protos included); the release tag tree and the raw git branch are not. `@go` is a moving target and drifted past the patch on 2026-08-27, so `build-runsc.sh` pins `GVISOR_REF` to the first `go`-branch snapshot that contains `GVISOR_TAG`, and uses `go mod download -json` to find the exact cache dir. `SHIM_OUT=` also builds `containerd-shim-runsc-v1` from the same patched tree.
- **`--timewarp-delay` (default 0s, we pass 10s everywhere)** keeps the clocks at 1x after boot so services with start-up deadlines come up. Temporal cannot start without it at any multiplier >= 1000x, and even with it only stays healthy up to ~30x (60-100x flaky, >= 200x fails): its internal persistence/RPC deadlines are a few seconds. Measured by `scripts/smoke-temporal.sh`.
- **gVisor networking quirks.** Netstack cannot reach Docker's embedded DNS (127.0.0.11); `stack/up.sh` gives the warped worker `--add-host` entries. `kubectl port-forward` cannot reach a gVisor pod (dials 127.0.0.1 in the pod netns); use `kubectl exec` or call from another pod. CoreDNS on k8s works.
- **Anything that runs inside the sandbox runs in warped time**, including things you think of as infrastructure: kubelet `exec` probes (`pg_isready` with a 3 s timeout fails after 35 us real at 86400x; use `tcpSocket`/`httpGet`), Postgres' `authentication_timeout` and autovacuum deadlines (connections drop now and then; `scripts/e2e-maturity.sh` retries), the UI's DB pool (short `idleTimeout`/`maxLifetime` in `stack/ui/server.ts`).
- **kind node quirks.** `docker cp` into a node's `/tmp` (tmpfs) is silently lost; pipe over `docker exec -i` instead. The gVisor shim ignored `BinaryName` from containerd options (containerd 2.2, v2 config), so `binary_name` goes in `/etc/containerd/runsc.toml` plus a `runsc -> runsc-warp` symlink. macOS bash 3.2 has no `mapfile`.
- **Warping is per-sandbox and set at boot.** Each warped sandbox drifts from its own start time; two warped pods do not agree on wall clock at high multipliers until the `--timewarp-anchor` roadmap item exists. Don't design anything assuming group-consistent clocks yet.
