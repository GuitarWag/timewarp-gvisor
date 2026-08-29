# Plan: a Temporal worker and sample jobs on the warped clock

Status: implemented 2026-08-29. Findings are at the end; they changed two of the
plan's assumptions (the multiplier and the need for a start-up grace period).
Code: `stack/worker/`, `scripts/e2e-temporal.sh`, `scripts/smoke-temporal.sh`,
`k8s-lab/temporal.yaml`, `k8s-lab/worker.yaml`.

## Goal

Show that durable workflows with long timers run to completion in seconds when
the Temporal server and its worker live in warped sandboxes, with no change to
the workflow code. A `workflow.Sleep(90 * 24 * time.Hour)` should fire in about
36 real seconds at 3600x and 90 real seconds at 86400x.

Temporal is the interesting target because it is the thing libfaketime cannot
touch (a static Go binary reading the vDSO) and the thing a per-process fake
clock gets wrong (timers live in the server, not in the worker).

## The one rule: every gRPC edge must stay inside one clock domain

gRPC carries the caller's deadline as a `grpc-timeout` header in absolute
milliseconds. A caller on the normal runtime sends "10 s"; a server at 3600x
consumes those 10 s in 2.8 ms real and returns `DEADLINE_EXCEEDED`. The reverse
also fails: a warped caller's "10 s" gives a normal-time server 10 hours.

So the topology is fixed by this rule, not by taste:

```
normal runtime            warped runtime (same multiplier, started together)
+---------------+  HTTP   +----------------+  gRPC   +------------------+
| twui (Bun UI) | ------> | worker (Go)    | ------> | temporal server  |
|               |  POST   |  HTTP /start   |  SDK    |  (dev server or  |
|               |  /start |  Temporal SDK  |         |   + Postgres)    |
+---------------+         +----------------+         +------------------+
        |                        |  SQL (no deadline header)
        |  SQL                   v
        +------------------> +----------+
                             | postgres |  warped
                             +----------+
```

- UI to worker is plain HTTP with no deadline header. That is exactly why
  `server.ts` already posts to `WORKER_URL/start` instead of using a Temporal
  client itself. Keep it that way.
- Worker to server is gRPC, both warped, so deadlines agree.
- Everything warped reads the same Postgres, which is already warped.
- The UI never talks to Temporal. It learns about workflow progress from the
  `events` table, which the worker's activities write.

Corollary: `temporal` CLI calls from the host (`temporal workflow list`) will
hit the deadline problem. Run them with `docker exec` inside the worker
container, or accept `--grpc-timeout`-style workarounds. Document, do not fight.

## Clock offset between sandboxes

Each sandbox's virtual clock starts at its own boot. Two containers started
1 s apart at 3600x disagree by 1 simulated hour, forever. Rates match, offsets
do not, until the `--timewarp-anchor` roadmap item exists.

Temporal tolerates this better than most systems because the server is the
single time authority: workflow timers, activity timeouts, and retry backoff are
all computed on the server clock. The worker's clock only affects its own
polling deadlines, sticky cache TTLs, and log timestamps. `compose.yml` starts
all warped services in one `docker compose up`, so the offset is a few seconds,
a few simulated hours. Acceptable for a demo; not acceptable for anything that
compares a worker-side `time.Now()` with a server-side timestamp. The sample
jobs below avoid that.

Postgres and Temporal disagree by the same few hours. Activities write
`events.sim_at` using `now()` from Postgres, not from Go, so the UI feed stays
consistent with everything else it shows.

## Two ways to host the server

**Option A, dev server in one container (recommended first).**
`temporal server start-dev --ip 0.0.0.0 --db-filename /data/temporal.db` in the
`temporalio/temporal` CLI image, under `runsc-warp-hour`. One process, SQLite,
UI on :8233, no persistence dependencies. It is the fastest way to find out
whether the server survives warped time at all.

**Option B, server with Postgres persistence.** `temporalio/auto-setup` pointed
at the already-warped Postgres (`DB=postgres12`, `POSTGRES_SEEDS=pg`). Closer
to production shape, more moving parts (schema setup, the `temporal` and
`temporal_visibility` databases, several services in one binary). Do this only
after A works.

## What to verify before writing any workflow

The server's own internals run on the warped clock too. At 3600x a 1 s ringpop
heartbeat becomes 0.28 ms real, and history shard timers, task queue
long-polls, and visibility flushes all compress the same way. The k8s lab
showed Postgres coping with this (autovacuum warnings, occasional dropped
connections). Temporal might not.

Step 0 is therefore a smoke test, extending `scripts/smoke-test.sh`:

1. Start the dev server under `runsc-warp` at 1000x. Wait 10 real s.
2. `docker exec` a `temporal operator cluster health`. Expect `SERVING`.
3. `temporal workflow start` a trivial workflow with no worker; check it appears
   in `temporal workflow list`. This exercises frontend, history, matching, and
   persistence.
4. Repeat at 3600x and 86400x. Record the highest multiplier that stays healthy
   for 60 real s. If 86400x fails and 3600x passes, the demo runs at 3600x and
   the sample job timers are sized for that.

If the server falls over at every multiplier, the fallback is Option C: server
and worker in the same container (one sandbox, one clock), which removes the
offset problem too, at the cost of a less honest topology. Note it, do not
build it unless needed.

## The worker

Go, `go.temporal.io/sdk`. Lives in `stack/worker/`. Small: a `main.go` that
starts a Temporal worker on task queue `timewarp` and an HTTP server on :8088
with two routes. About 150 lines plus the workflows.

```
POST /start   {"depositId": 1}      -> starts LoyaltyBonus(depositId), workflowId "bonus-<id>"
GET  /healthz                        -> 200 once connected to the server
```

`workflowId = "bonus-<id>"` with `WorkflowIDReusePolicy: RejectDuplicate` makes
`/start` idempotent. `server.ts` already calls it several times per deposit
(`ensureBonusWorkflows`) and expects that.

Activities write to Postgres through the same `events` table the UI reads,
using `sim_at = now()` on the DB side. Connection settings copy the ones in
`server.ts` (`max 4`, short idle and lifetime), for the same reason: Postgres
drops idle connections in warped time.

## Sample jobs

Each one exercises a different Temporal timer path. Durations are chosen so
that at 3600x everything visible happens within a few real minutes, and at
86400x within seconds.

| Workflow | What it exercises | Sim duration | Real at 3600x | Real at 86400x |
|---|---|---|---|---|
| `LoyaltyBonus(depositId)` | `workflow.Sleep(90d)`, then an activity that pays 1% and writes `bonus.paid` | 90 d | 36 min | 90 s |
| `StatementCycle(depositId)` | a `for` loop of `Sleep(30d)` + activity, 3 iterations, then done | 90 d | 36 min | 90 s |
| `FlakyReconciliation()` | activity that fails 4 times, `RetryPolicy` with `InitialInterval: 1h`, `BackoffCoefficient: 2` (1h, 2h, 4h, 8h waits) | 15 h | 15 s | 0.6 s |
| `SlaEscalation(caseId)` | `workflow.Selector` on a signal vs a `NewTimer(48h)`; no signal arrives, escalation activity runs | 48 h | 48 s | 2 s |
| `LongHeartbeat()` | one activity that loops 24 times, heartbeating every sim hour, `HeartbeatTimeout: 2h` | 24 h | 24 s | 1 s |
| `NightlyClose` (a Temporal Schedule, not a workflow start) | `temporal schedule create --cron "0 18 * * *"` running a tiny workflow | daily | every 24 s | every 1 s |

Why these six:

- The first two are the deposit story the UI already tells, so they land in
  the feed as `bonus.scheduled` / `bonus.paid` with no UI change. The
  `StatementCycle` also shows Temporal and the Postgres-side `statement` cron
  agreeing on cadence.
- `FlakyReconciliation` is the one people ask about: exponential backoff is
  server-side timer math, so it should compress exactly. If it does not, the
  warp is wrong somewhere.
- `SlaEscalation` covers `Selector` and timers racing signals; the signal never
  comes, so it also shows a timer firing with no activity involved.
- `LongHeartbeat` is the risky one. Heartbeats travel worker to server over
  gRPC; both warped, so they should agree. If the activity gets timed out, the
  two sandboxes' offset is larger than the heartbeat timeout, which is a real
  finding worth writing down.
- `NightlyClose` shows Temporal Schedules (cron on the server clock) as the
  counterpart to the SQL `schedules` table in `schema-native.sql`.

Each activity inserts one row into `events` with a `kind` of `temporal.<name>`.
The UI already renders unknown kinds with an uppercase tag, so the feed and the
chart pick them up with zero UI work. Later, give `temporal.*` its own colour
in the chart's `SERIES` list; one line in `index.html`.

## Where the UI and DB meet Temporal

- `server.ts`: no change needed for the first pass. Set `WORKER_URL=http://worker:8088`
  in `up.sh` / `compose.yml` / `ui.yaml`.
- `schema-native.sql`: no change. Activities insert into `events`; deposits
  get their bonus via `UPDATE deposits SET amount = ...` inside the activity.
- `index.html`: optional colour for `temporal.*` kinds.

## Docker (stack/) steps

1. `stack/worker/` with `Dockerfile` (multi-stage `golang:1.26` build, static
   binary, `FROM scratch` or `gcr.io/distroless/static`).
2. `compose.yml`: add `temporal` (Option A image) and `worker`, both
   `runtime: runsc-warp-hour`; add `WORKER_URL` to `twui`. Keep `up.sh` as the
   imperative twin, or retire `up.sh` in favour of `docker compose up` since the
   file now does everything `up.sh` does. Prefer retiring; one launcher.
3. Extend `scripts/e2e-maturity.sh` or add `scripts/e2e-temporal.sh`: start a
   `FlakyReconciliation`, poll `events` for `temporal.reconciled` within a
   real-time deadline (60 s at 3600x). Same backend switch (`CONTAINER=` vs
   `NS=`).

## Kubernetes (k8s-lab/) steps

1. `k8s-lab/temporal.yaml`: Deployment + Service for the dev server,
   `runtimeClassName: runsc-warp`, `tcpSocket` probe on 7233 (an `exec`
   `temporal operator cluster health` probe would time out inside the sandbox,
   same lesson as `pg_isready`).
2. `k8s-lab/worker.yaml`: Deployment + Service, `runtimeClassName: runsc-warp`,
   `httpGet /healthz` on 8088 (kubelet-side, real time, fine).
3. `ui.yaml`: add `WORKER_URL=http://worker:8088`.
4. `deploy-stack.sh`: build and `kind load` the worker image next to `twui`.

## Order of work and rough size

1. Smoke test the dev server under warp at 1000x / 3600x / 86400x. Half a day,
   mostly waiting. Decides everything below.
2. Worker skeleton, `LoyaltyBonus` only, Docker compose. Half a day. First
   `bonus.paid` in the UI feed is the milestone.
3. Remaining five jobs. Half a day. They share one activity helper.
4. `e2e-temporal.sh` and the k8s manifests. Half a day.
5. Write up findings in `k8s-lab/README.md` and here: which multiplier the
   server tolerates, the observed sandbox offset, any timer that did not
   compress as expected.

## Risks, in the order they will probably bite

1. Temporal server unhealthy under warp (ringpop, shard timers). Mitigation:
   lower multiplier, or Option C. Found in step 1.
2. Sandbox offset larger than an activity timeout. Mitigation: start warped
   services in one `compose up`; size `HeartbeatTimeout` and
   `ScheduleToStart` generously (hours, not seconds; they are cheap in warped
   time anyway).
3. gRPC deadlines across clock domains from any tool run on the host.
   Mitigation: the rule above; run `temporal` CLI via `docker exec`.
4. Dev server's SQLite in a gVisor sandbox: `sync` behaviour and file locking
   under the gofer. The smoke test covers it; fall back to `--db-filename`
   unset (in-memory) for the demo.
5. Go SDK worker sticky cache and the 10 s default `StickyScheduleToStartTimeout`:
   at 3600x that is 2.8 ms real. Tasks fall back to the normal queue, which
   works but shows up as noise in the server logs. Raise it to hours in
   `worker.Options`, or accept the noise and note it.

## Findings (2026-08-29)

**The server does not start under warp without a grace period.** Temporal's fx
start hooks have a 15 s deadline; at 1000x that is 15 ms real, and opening
SQLite and binding ports takes about 0.9 s real. Every multiplier from 1000x up
failed with `failed to start service worker: context deadline exceeded`. Fix:
a new sentry flag, `--timewarp-delay` (default `0s`, we use `10s`). The clocks
run at 1x for that long after boot, then switch to the multiplier,
continuously. `install-runtimes.sh` and `inject-warp-runtime.sh` pass it to
every runtime. This is the first change to `clockwarp.patch` since the pin.

**The server tolerates about 30x, not 3600x.** With the grace period it starts
at any multiplier, but once warped its internal persistence and RPC deadlines
(single-digit seconds, i.e. single-digit real milliseconds at 1000x) fail
against real SQLite and loopback gRPC latency. `scripts/smoke-temporal.sh`
measured, 60 real seconds of health checks plus a workflow start and list, two
rounds each:

| multiplier | result |
|---|---|
| 10x, 30x | pass, every run |
| 60x | 1 of 3 |
| 100x | 2 of 3 |
| 200x | fail, both runs |
| 1000x, 3600x, 86400x | fail |

So Temporal runs on its own runtime, `runsc-warp-temporal`, at 30x. The plan's
job durations were resized from days to minutes: `FlakyReconciliation` backs
off 1m, 2m, 4m, 8m (15 sim minutes, ~30 real seconds), `LoyaltyBonus` waits 90
sim minutes (3 real minutes), the cron schedule runs every 5 sim minutes (every
10 real seconds). All durations are env vars on the worker.

**Task-queue partitions stop dispatching after a few minutes.** With the
default four partitions per task queue, the server passed a 60 s smoke and the
first e2e right after boot, then nine real minutes later activities stopped
being dispatched while scheduled workflows kept completing. The matching
engine logged `error fetching user data from parent ... context deadline
exceeded` for the `/_sys/timewarp/1` child partition: partition sync is an
internal RPC with a short deadline. Fix: run the dev server with
`--dynamic-config-value matching.numTaskqueueReadPartitions=1` and
`...WritePartitions=1`, so there is no parent to fetch from. Applied in
`up.sh`, `temporal.yaml`, and `smoke-temporal.sh`. Sustained results below.

**Two multipliers in one stack.** Postgres stays at 3600x for the deposit demo;
Temporal and the worker run at 30x. Activities stamp events with the database's
`now()`, so in the UI feed a 15-minute Temporal backoff chain shows up spread
over hours of Postgres time. Consistent within each clock, odd across them. A
single anchor and rate for the whole stack is the `--timewarp-anchor` roadmap
item.

**gVisor's netstack cannot reach Docker's embedded DNS.** `nslookup` to
127.0.0.11 times out under plain `runsc` too, so it is not the warp. `up.sh`
gives the warped worker `--add-host` entries with the real container IPs. On
Kubernetes CoreDNS is a normal service IP and works.

**`kubectl port-forward` cannot reach a gVisor pod.** It dials 127.0.0.1 inside
the pod's network namespace; the sandbox listens in its own netstack. Postgres
only ever worked through `kubectl exec`. In k8s mode `e2e-temporal.sh` calls
the worker from the UI pod (`kubectl exec deploy/twui -- bun -e 'fetch(...)'`).
The Temporal web UI on 8233 is therefore not reachable from the host on kind.

**Results.** `scripts/e2e-temporal.sh`, `FlakyReconciliation`, 5 attempts with
exponential backoff: Docker 31 s real, kind 33 s real, right after boot. With
single-partition task queues, the same test 8 real minutes after boot (4 sim
hours at 30x): Docker 33 s, kind 32 s. `LoyaltyBonus`,
`StatementCycle`, `NightlyClose` (Temporal Schedule) all appear in the feed.
`SlaEscalation` and `LongHeartbeat` are wired to `POST /run` but not exercised
by the e2e; no `HeartbeatTimeout` observed in the runs done by hand.

**Not done from the plan.** Option B (Postgres persistence for the server) was
not attempted. The raised `StickyScheduleToStartTimeout` (1h) is in place; the
worker still logs `Failed to poll for task ... context deadline exceeded`
warnings at 30x, from the 60 s long-poll (2 real seconds). Harmless so far.

## Success criteria

- [x] `FlakyReconciliation` completes with 5 attempts and 4 `temporal.retry`
  events in the feed (31 s Docker, 33 s kind, at 30x).
- [x] Passes on Docker and on kind through the same e2e script.
- [x] Findings filled in with numbers, including the multiplier ceiling (30x).
- [ ] `LoyaltyBonus` asserted by a script (it runs; checked by eye in the feed).
