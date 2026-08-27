// Time-warp demo API (Bun).
//
// Serves the UI and a tiny REST API. Every read of "now" goes through the
// shared sim_now() in Postgres, so the API and the database agree on a single
// simulated clock that the UI can speed up, slow down, or reset.

import { SQL } from "bun";

const db = new SQL(
  process.env.DATABASE_URL ??
    "postgres://postgres:postgres@localhost:5432/timewarp",
  // Recycle connections proactively. Under an accelerated (gVisor-warped)
  // Postgres, idle/keepalive timeouts fire in warped time and can silently drop
  // long-lived connections, so keep them short-lived and shallow.
  { max: 4, idleTimeout: 10, maxLifetime: 20, connectionTimeout: 10 },
);

// Run a query but never let a dead/hung connection block forever (the socket to
// a warped Postgres can stop responding without a clean close).
function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`query timed out after ${ms}ms`)), ms),
    ),
  ]);
}

const indexHtml = await Bun.file(
  new URL("./public/index.html", import.meta.url),
).text();

// Wait for Postgres to accept connections and the schema to exist.
async function waitForDb(): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try {
      await db`SELECT sim_now()`;
      return;
    } catch (err) {
      if (attempt >= 60) throw err;
      console.log(`waiting for db (attempt ${attempt})...`);
      await Bun.sleep(1000);
    }
  }
}

async function getClock() {
  const [row] = await db`SELECT sim_now() AS sim_now, multiplier FROM sim_clock WHERE id = 1`;
  return {
    simNow: row.sim_now,
    // This process runs on the normal runtime, so its clock is real time.
    realNow: new Date().toISOString(),
    multiplier: Number(row.multiplier),
  };
}

async function listDeposits() {
  return db`
    SELECT id, label, amount, term_days, created_at, matured_at, rollovers,
           created_at + make_interval(days => term_days) AS matures_at,
           sim_now()                                     AS now,
           matured_at IS NOT NULL                        AS matured
    FROM deposits
    ORDER BY id`;
}

async function listSchedules() {
  return db`
    SELECT name, cadence, message, next_run_at, runs
    FROM schedules WHERE enabled
    ORDER BY next_run_at`;
}

// Time series for the graph: hourly book snapshots plus events per sim-hour.
async function series(hours: number) {
  const since = db`sim_now() - make_interval(hours => ${hours})`;
  const samples = await db`
    SELECT sim_at, total, active, matured FROM samples
    WHERE sim_at > ${since} ORDER BY sim_at`;
  const buckets = await db`
    SELECT date_trunc('hour', sim_at) AS h,
           CASE WHEN kind LIKE 'cron.%' THEN 'cron' ELSE kind END AS kind,
           count(*)::int AS n
    FROM events WHERE sim_at > ${since}
    GROUP BY 1, 2 ORDER BY 1`;
  return { samples, buckets };
}

async function listEvents(afterId: number) {
  return db`
    SELECT id, sim_at, real_at, kind, deposit_id, message, data
    FROM events
    WHERE id > ${afterId}
    ORDER BY id DESC
    LIMIT 200`;
}

// Optional Temporal worker. Unset (or empty) = no workflows, no noise.
const WORKER_URL = process.env.WORKER_URL || "";

// Ask the Temporal worker to start a durable loyalty-bonus workflow for a
// deposit. Fire-and-forget: the demo still works if Temporal isn't deployed.
function startBonusWorkflow(depositId: number) {
  if (!WORKER_URL) return;
  fetch(`${WORKER_URL}/start`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ depositId }),
  }).catch((err) => console.error("start workflow failed:", String(err)));
}

async function addDeposit(label: string, amount: number, termDays: number) {
  const [row] = await db`
    INSERT INTO deposits (label, amount, term_days)
    VALUES (${label}, ${amount}, ${termDays})
    RETURNING id`;
  startBonusWorkflow(Number(row.id));
  return row;
}

// Start workflows for any deposits that don't have one yet (e.g. the seeded
// rows, or after a worker restart). Idempotent thanks to the stable workflowId.
async function ensureBonusWorkflows() {
  const rows = await db`SELECT id FROM deposits WHERE matured_at IS NULL`;
  for (const r of rows) startBonusWorkflow(Number(r.id));
}

async function reset() {
  await db`SELECT reset_demo()`;
  await ensureBonusWorkflows();
}

// The time-driven engine. Polls on a real-time interval but tick() reasons in
// simulated time, so at high multipliers it fires every event that came due.
async function runScheduler() {
  while (true) {
    try {
      await withTimeout(db`SELECT tick()`, 5000);
    } catch (err) {
      console.error("tick failed:", String(err));
    }
    await Bun.sleep(300);
  }
}

await waitForDb();
runScheduler();
// Best-effort: cover seeded deposits once the worker is up (worker may boot late).
for (const delay of [3000, 10000, 25000]) {
  setTimeout(() => ensureBonusWorkflows().catch(() => {}), delay);
}

const json = (data: unknown, status = 200) =>
  Response.json(data, { status });

const server = Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  routes: {
    "/": new Response(indexHtml, {
      headers: { "content-type": "text/html; charset=utf-8" },
    }),
    "/healthz": new Response("ok"),

    "/api/clock": { GET: async () => json(await getClock()) },

    "/api/series": {
      GET: async (req) => {
        const h = Number(new URL(req.url).searchParams.get("hours") ?? 72);
        return json(await series(Number.isFinite(h) && h > 0 ? Math.min(h, 24 * 90) : 72));
      },
    },

    "/api/deposits": {
      GET: async () => json(await listDeposits()),
      POST: async (req) => {
        const body = (await req.json().catch(() => ({}))) as {
          label?: string;
          amount?: number;
          termDays?: number;
        };
        const label = body.label?.trim() || `Deposit #${Date.now() % 10000}`;
        const amount = Number(body.amount ?? 1000);
        const termDays = Number(body.termDays ?? 90);
        await addDeposit(label, amount, termDays);
        return json(await listDeposits(), 201);
      },
    },

    "/api/schedules": {
      GET: async () => json(await listSchedules()),
    },

    "/api/events": {
      GET: async (req) => {
        const after = Number(new URL(req.url).searchParams.get("after") ?? 0);
        return json(await listEvents(Number.isFinite(after) ? after : 0));
      },
    },

    "/api/reset": {
      POST: async () => {
        await reset();
        return json({ ok: true });
      },
    },
  },
  error(err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  },
});

console.log(`timewarp api listening on :${server.port}`);
