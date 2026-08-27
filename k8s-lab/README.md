# k8s-lab: time-warp on a KinD local-dev env

Run the clock-warp on a real workload inside a KinD cluster. This first experiment warps **only the local-dev Postgres pod** and
shows a 90-day term deposit maturing in real seconds — off plain `now()`, with
no application change.

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
warp-postgres.sh        (host) -> suspend Flux, patch runtimeClassName onto the
                                   postgres Deployment, roll out
e2e-maturity-test.sh    (host) -> open a 90-day deposit, poll now() until matured
```

The multiplier reaches the sentry the same way it does in the Docker `stack/`
demo, but through containerd: the shim turns each `[runsc_config]` key in
`/etc/containerd/runsc.toml` into a `--key=value` runsc flag, so
`timewarp-multiplier = "86400"` becomes `runsc --timewarp-multiplier=86400`.
Node injection uses `docker cp` + `systemctl restart containerd` on each kind
node, so no privileged pod is needed and a `disallow-privileged` admission
policy stays untouched.

## Run it

Prereqs: a running kind cluster with a local-dev Postgres deployed, and the Lima VM from `../lima/gvisor.yaml` for the Linux build.

```bash
# 1. Build the warped runtime for the kind node arch (arm64 on Apple Silicon)
limactl shell gvisor -- bash "$PWD/k8s-lab/build-warp-runtime.sh"
#    (copy k8s-lab/bin/ back to the host if the VM mount is read-only)

# 2. Install it on the kind nodes at 1 simulated day per real second
MULTIPLIER=86400 ./k8s-lab/inject-warp-runtime.sh

# 3. Move Postgres onto the warped runtime (auto-discovers the deployment)
./k8s-lab/warp-postgres.sh                 # or: NS=... DEPLOY=... ./warp-postgres.sh

# 4. Watch a 90-day deposit mature in ~90 real seconds
NS=<ns> DEPLOY=<deploy> ./k8s-lab/e2e-maturity-test.sh
```

## Cleanup

```bash
flux resume kustomization <name>     # un-suspend whatever warp-postgres.sh suspended
kubectl patch deployment <deploy> -n <ns> --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/runtimeClassName"}]'
# or just: kind delete cluster --name "$KIND_CLUSTER_NAME"
```

## Known caveats / what to watch

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
