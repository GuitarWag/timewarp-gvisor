# Plan: a Temporal worker and sample jobs on the warped clock

Status: plan, nothing built yet. Written 2026-08-29 against the state of the
repo at that date (stack at 3600x, k8s lab passing, `WORKER_URL` hook in the UI).

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

## Success criteria

- `LoyaltyBonus` for a fresh deposit shows `bonus.paid` in the UI within 40
  real s at 3600x, with the deposit amount increased by 1%.
- `FlakyReconciliation` completes with 5 attempts visible in the Temporal
  history and 4 `temporal.retry` events in the feed, within 20 real s at 3600x.
- Both above pass on Docker and on kind through the same e2e script.
- The findings section in this file is filled in with numbers, including the
  highest multiplier the server tolerated.
