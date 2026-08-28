# k8s-lab: time-warp on a KinD cluster

Run the clock-warp on a real workload inside a KinD cluster. This experiment
warps **only a single Postgres pod** and shows a 90-day term deposit maturing in
~90 real seconds — off plain `now()`, with no application change.

Verified 2026-08-28 on a fresh `kind` cluster (containerd 2.2, OrbStack,
Apple Silicon): `PASS: a 90-day deposit matured in 91s of real time`.

## Why Postgres-only first

Warping a clock uniformly also speeds up every timeout, gRPC deadline, Raft
lease, and heartbeat, while the actual network/disk/CPU work still takes real
seconds. A single-pod Postgres has no inter-node clock agreement to break, so
it warps cleanly. Distributed targets (YugabyteDB) and the gRPC mesh will
cascade into timeout failures and need the shared-anchor + live-rate work on the
main roadmap — they are deliberately out of scope here.

## How it works

```
build-warp-runtime.sh   (Lima) -> runsc-warp + containerd-shim-runsc-v1
inject-warp-runtime.sh  (host) -> docker cp into kind nodes, add containerd
                                   runtime handler + runsc.toml (multiplier),
                                   restart containerd, apply RuntimeClass
postgres.yaml           (host) -> self-contained Postgres already on the RuntimeClass
deploy-stack.sh + ui.yaml (host) -> the stack/ demo on k8s: seeded Postgres (warped)
                                   + Bun UI (normal runtime), port-forward :8080
warp-postgres.sh        (host) -> OR move an existing Postgres Deployment onto it
                                   (suspends Flux if present)
../scripts/e2e-maturity.sh (host) -> open a deposit, poll now() until matured
                                   (same script works against the Docker stack)
```

The multiplier reaches the sentry the same way it does in the Docker `stack/`
demo, but through containerd: the shim turns each `[runsc_config]` key in
`/etc/containerd/runsc.toml` into a `--key=value` runsc flag, so
`timewarp-multiplier = "86400"` becomes `runsc --timewarp-multiplier=86400`.
Node injection uses `docker cp` + `systemctl restart containerd` on each kind
node, so no privileged pod is needed and a `disallow-privileged` admission
policy stays untouched.

## Run it

Prereqs: `kind`, `kubectl`, Docker on the host, and the Lima VM from
`../lima/gvisor.yaml` for the Linux build.

```bash
# 0. A cluster of your own (do not reuse a cluster you care about)
kind create cluster --name timewarp
kubectl config use-context kind-timewarp

# 1. Build runsc-warp + containerd-shim-runsc-v1 for the node arch (arm64 on Apple Silicon)
limactl shell gvisor -- bash "$PWD/k8s-lab/build-warp-runtime.sh"
limactl cp -r gvisor:~/k8s-lab-bin/. k8s-lab/bin/     # the repo mount is read-only in the VM

# 2. Install it on the kind nodes at 1 simulated day per real second
KIND_CLUSTER_NAME=timewarp MULTIPLIER=86400 ./k8s-lab/inject-warp-runtime.sh

# 3. Run an unmodified Postgres on the warped RuntimeClass
kubectl apply -f k8s-lab/postgres.yaml
kubectl rollout status deploy/postgres -n timewarp
#    (or move an existing one: NS=... DEPLOY=... ./k8s-lab/warp-postgres.sh)

# 4. Watch a 90-day deposit mature in ~90 real seconds
NS=timewarp DEPLOY=postgres ./scripts/e2e-maturity.sh
```

### The full demo (UI) on k8s

Same as the Docker `stack/`, at 1 simulated hour per real second:

```bash
KIND_CLUSTER_NAME=timewarp MULTIPLIER=3600 ./k8s-lab/inject-warp-runtime.sh   # match the UI's 1 hr/s
KIND_CLUSTER_NAME=timewarp ./k8s-lab/deploy-stack.sh    # builds stack/ui, kind-loads it, seeds Postgres
kubectl port-forward -n timewarp svc/twui 8080:3000     # http://localhost:8080
```

`deploy-stack.sh` puts `stack/schema-native.sql` in a ConfigMap mounted at
`/docker-entrypoint-initdb.d`, so the warped Postgres seeds the deposit ladder and
cron jobs on first boot. The UI pod has no `runtimeClassName`, so it runs in real
time and shows both clocks.

Check the sandbox is gVisor: `kubectl exec -n timewarp deploy/postgres -- dmesg`
prints `Starting gVisor...`, and on the node `ps -eo args | grep runsc-warp`
shows `--timewarp-multiplier=86400`.

## Cleanup

```bash
kubectl delete -f k8s-lab/postgres.yaml -f k8s-lab/ui.yaml
# if you used warp-postgres.sh on an existing deployment:
flux resume kustomization <name>
kubectl patch deployment <deploy> -n <ns> --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/runtimeClassName"}]'
# or just: kind delete cluster --name timewarp
```

## Known caveats / what to watch

- **Probes must run outside the sandbox.** An `exec` readiness probe such as
  `pg_isready` runs inside the warped sandbox, where its 3 s timeout is 35 us
  real, so the pod never turns Ready. Use `tcpSocket`/`httpGet` probes: the
  kubelet runs those from the node in real time.
- **Connections drop now and then.** Postgres' own timers (`authentication_timeout`
  60 s = 0.7 ms real at 86400x, autovacuum deadlines, checkpoints) fire in warped
  time. `scripts/e2e-maturity.sh` retries a dropped `psql`. Autovacuum warnings in
  the log are expected.
- **`binary_name` lives in `runsc.toml`.** The shim did not honour `BinaryName`
  from the containerd runtime options here (containerd 2.2, v2 config); it looked
  for `runsc` in `$PATH`. `inject-warp-runtime.sh` sets `binary_name` in
  `/etc/containerd/runsc.toml` and adds a `runsc -> runsc-warp` symlink.
- **`docker cp` into a kind node's `/tmp` is lost** (tmpfs mount; the copy lands
  in the rootfs layer underneath). The inject script pipes over `docker exec -i`.
- **macOS bash 3.2** has no `mapfile`; the scripts use plain `read` loops.
- **Docker engine hangs.** Streaming the 92 MB binary into a node froze the
  OrbStack Docker engine once; `orbctl restart docker` recovered it and the kind
  cluster survived.

- **gVisor inside KinD on Apple Silicon.** Kind nodes are privileged containers,
  so the systrap platform should run, but this is the least-tested link — if pods
  fail to start under `runsc-warp`, check `runsc` logs in the node and confirm
  systrap works in your Docker Desktop VM.
- **containerd config version.** `inject-warp-runtime.sh` appends a CRI v2
  runtime block (`io.containerd.grpc.v1.cri`). If the kind node ships containerd
  2.x, the plugin key differs (`io.containerd.cri.v1.runtime`) — adjust the
  handler block accordingly.
- **DB credentials.** The test defaults to `postgres/postgres`; set `PGUSER` /
  `PGDATABASE` to match the DB secret if different.
- **Don't point apps at the warped DB mid-test.** A service with normal-speed
  clocks talking to a DB whose `now()` jumped days will see its own deadlines and
  the DB clock disagree. Keep this experiment to the DB and a direct SQL probe.

## Next steps (toward the Temporal demo)

Temporal + its Postgres warped together (modest multiplier) is the compelling
follow-up: a `workflow.Sleep(90d)` firing in seconds. It needs the
`--timewarp-anchor` shared-epoch flag (roadmap item) so the two pods' virtual
clocks agree, plus timeout tuning. This lab is the stepping stone.
