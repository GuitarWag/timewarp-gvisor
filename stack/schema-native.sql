-- Time-warp demo schema.
--
-- The trick: one shared clock (sim_clock + sim_now()). Everything that needs
-- "now" reads sim_now() instead of now(). Background work is driven by a tick()
-- function that the Bun scheduler calls on a real-time interval but which
-- reasons entirely in simulated time -- so when the clock runs fast, tick()
-- catches up and fires every event that became due, stamping each with the
-- simulated moment it should have happened.

-- ---------------------------------------------------------------------------
-- Shared clock
-- ---------------------------------------------------------------------------
CREATE TABLE sim_clock (
  id             int         PRIMARY KEY DEFAULT 1,
  anchor_real    timestamptz NOT NULL DEFAULT now(),
  anchor_virtual timestamptz NOT NULL DEFAULT now(),
  multiplier     numeric     NOT NULL DEFAULT 1,
  CONSTRAINT one_row CHECK (id = 1)
);
INSERT INTO sim_clock (id, multiplier) VALUES (1, 3600);   -- 1 sim hour per real second

CREATE OR REPLACE FUNCTION sim_now() RETURNS timestamptz AS $$
  SELECT now();   -- time is warped by the gVisor runtime, not the DB
$$ LANGUAGE sql STABLE;

-- Re-anchor before changing speed so virtual time stays continuous.
CREATE OR REPLACE FUNCTION set_speed(new_multiplier numeric) RETURNS void AS $$
BEGIN
  -- no-op: clock rate is fixed by the gVisor runtime (runsc-warp-hour = 3600x)
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Event log (the UI feed). sim_at is the simulated time the event happened.
-- ---------------------------------------------------------------------------
CREATE TABLE events (
  id         bigserial   PRIMARY KEY,
  sim_at     timestamptz NOT NULL DEFAULT sim_now(),
  real_at    timestamptz NOT NULL DEFAULT now(),
  kind       text        NOT NULL,
  deposit_id bigint,
  message    text        NOT NULL,
  data       jsonb
);

-- ---------------------------------------------------------------------------
-- Sim-time cron. A real scheduler (pg_cron, k8s CronJob) fires on wall-clock
-- time and would NOT accelerate. These schedules are evaluated against
-- sim_now() by run_due_schedules(), which tick() calls -- so they speed up with
-- the dial. Two kinds: fixed interval, or specific days of the month.
-- ---------------------------------------------------------------------------
CREATE TABLE schedules (
  id            bigserial   PRIMARY KEY,
  name          text        NOT NULL,
  kind          text        NOT NULL,            -- 'interval' | 'monthly_days'
  every         interval,                        -- for kind = 'interval'
  days_of_month int[],                           -- for kind = 'monthly_days' (ascending)
  cadence       text        NOT NULL,            -- human label for the UI
  message       text        NOT NULL,
  next_run_at   timestamptz NOT NULL,
  runs          int         NOT NULL DEFAULT 0,
  enabled       boolean     NOT NULL DEFAULT true
);

-- Next simulated firing time strictly after from_ts.
CREATE OR REPLACE FUNCTION next_occurrence(
  p_kind text, p_every interval, p_days int[], from_ts timestamptz
) RETURNS timestamptz AS $$
DECLARE cand timestamptz; d int; mo int;
BEGIN
  IF p_kind = 'interval' THEN
    RETURN from_ts + p_every;
  ELSIF p_kind = 'monthly_days' THEN
    FOR mo IN 0..1 LOOP                          -- this month, then next
      FOREACH d IN ARRAY p_days LOOP
        cand := date_trunc('month', from_ts)
                + make_interval(months => mo)
                + make_interval(days => d - 1);
        IF cand > from_ts THEN RETURN cand; END IF;
      END LOOP;
    END LOOP;
    RETURN date_trunc('month', from_ts) + interval '2 months';
  END IF;
  RETURN from_ts + interval '1 day';
END;
$$ LANGUAGE plpgsql;

-- Fire every schedule that came due, catching up across all elapsed periods.
CREATE OR REPLACE FUNCTION run_due_schedules() RETURNS void AS $$
DECLARE s schedules%ROWTYPE; guard int;
BEGIN
  FOR s IN SELECT * FROM schedules WHERE enabled LOOP
    guard := 0;
    WHILE s.next_run_at <= sim_now() AND guard < 1000 LOOP
      INSERT INTO events (sim_at, kind, message, data)
      VALUES (s.next_run_at, 'cron.' || s.name, s.message,
              jsonb_build_object('schedule', s.name, 'run', s.runs + 1));
      s.runs := s.runs + 1;
      s.next_run_at := next_occurrence(s.kind, s.every, s.days_of_month, s.next_run_at);
      guard := guard + 1;
    END LOOP;
    UPDATE schedules SET next_run_at = s.next_run_at, runs = s.runs WHERE id = s.id;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- The thing we prove: term deposits that accrue interest every simulated day,
-- mature after term_days, and roll into a new term.
-- ---------------------------------------------------------------------------
CREATE TABLE deposits (
  id               bigserial   PRIMARY KEY,
  label            text        NOT NULL,
  amount           numeric     NOT NULL DEFAULT 1000,
  term_days        int         NOT NULL DEFAULT 90,
  created_at       timestamptz NOT NULL DEFAULT sim_now(),
  last_interest_at timestamptz NOT NULL DEFAULT sim_now(),
  matured_at       timestamptz,
  rollovers        int         NOT NULL DEFAULT 0
);

-- Hourly (sim-time) snapshot of the book, for the time-series graph.
CREATE TABLE samples (
  sim_at   timestamptz PRIMARY KEY,
  total    numeric     NOT NULL,
  active   int         NOT NULL,
  matured  int         NOT NULL
);

-- Trigger: log when a deposit is opened (reacts to the INSERT).
CREATE OR REPLACE FUNCTION log_opened() RETURNS trigger AS $$
BEGIN
  INSERT INTO events (sim_at, kind, deposit_id, message, data)
  VALUES (NEW.created_at, 'deposit.opened', NEW.id,
          format('Opened "%s" — %s for %s days', NEW.label, NEW.amount, NEW.term_days),
          jsonb_build_object('amount', NEW.amount, 'term_days', NEW.term_days));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_opened AFTER INSERT ON deposits
  FOR EACH ROW EXECUTE FUNCTION log_opened();

-- Trigger: log the moment a deposit's matured_at flips from NULL (reacts to the
-- UPDATE that tick() performs).
CREATE OR REPLACE FUNCTION log_matured() RETURNS trigger AS $$
BEGIN
  IF NEW.matured_at IS NOT NULL AND OLD.matured_at IS NULL THEN
    INSERT INTO events (sim_at, kind, deposit_id, message, data)
    VALUES (NEW.matured_at, 'deposit.matured', NEW.id,
            format('"%s" matured at %s', NEW.label, NEW.amount),
            jsonb_build_object('final_amount', NEW.amount));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_matured AFTER UPDATE ON deposits
  FOR EACH ROW EXECUTE FUNCTION log_matured();

-- ---------------------------------------------------------------------------
-- tick(): the time-driven engine. Called repeatedly by the Bun scheduler.
-- All comparisons use sim_now(), so high multipliers just mean more work per
-- call (the inner loop catches up across every 30-day period that elapsed).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tick() RETURNS void AS $$
DECLARE
  d      deposits%ROWTYPE;
  due    timestamptz;
  last_s timestamptz;
BEGIN
  -- Fire any sim-time cron jobs that came due.
  PERFORM run_due_schedules();

  -- Accrue daily interest (1% per 30 days, compounded daily) on active deposits.
  -- Runs before maturity so the final day's interest lands before the term closes.
  FOR d IN SELECT * FROM deposits WHERE matured_at IS NULL LOOP
    LOOP
      due := d.last_interest_at + interval '1 day';
      EXIT WHEN sim_now() < due;
      UPDATE deposits
      SET last_interest_at = due,
          amount = round(amount * (1 + 0.01 / 30), 2)
      WHERE id = d.id
      RETURNING amount INTO d.amount;

      INSERT INTO events (sim_at, kind, deposit_id, message, data)
      VALUES (due, 'interest.accrued', d.id,
              format('Daily interest on "%s" — now %s', d.label, d.amount),
              jsonb_build_object('rate', round(0.01 / 30, 6), 'amount', d.amount));

      d.last_interest_at := due;
    END LOOP;
  END LOOP;

  -- Mature anything whose term has elapsed (trigger logs it).
  UPDATE deposits
  SET matured_at = created_at + make_interval(days => term_days)
  WHERE matured_at IS NULL
    AND sim_now() >= created_at + make_interval(days => term_days);

  -- Roll matured deposits into a fresh term of the same length, so the book
  -- keeps moving for as long as the demo runs.
  FOR d IN SELECT * FROM deposits WHERE matured_at IS NOT NULL
                                    AND matured_at <= sim_now() - interval '6 hours' LOOP
    INSERT INTO events (sim_at, kind, deposit_id, message, data)
    VALUES (d.matured_at + interval '6 hours', 'deposit.rolled', d.id,
            format('"%s" rolled over into a new %s-day term at %s', d.label, d.term_days, d.amount),
            jsonb_build_object('amount', d.amount, 'term_days', d.term_days, 'rollover', d.rollovers + 1));
    UPDATE deposits
    SET created_at = d.matured_at + interval '6 hours',
        last_interest_at = d.matured_at + interval '6 hours',
        matured_at = NULL,
        rollovers = rollovers + 1
    WHERE id = d.id;
  END LOOP;

  -- One snapshot per sim hour for the graph (catch up if several hours passed).
  SELECT max(sim_at) INTO last_s FROM samples;
  IF last_s IS NULL THEN last_s := date_trunc('hour', sim_now()) - interval '1 hour'; END IF;
  WHILE last_s + interval '1 hour' <= sim_now() LOOP
    last_s := last_s + interval '1 hour';
    INSERT INTO samples (sim_at, total, active, matured)
    SELECT last_s, coalesce(sum(amount), 0),
           count(*) FILTER (WHERE matured_at IS NULL),
           count(*) FILTER (WHERE matured_at IS NOT NULL)
    FROM deposits;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Seed + reset
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seed() RETURNS void AS $$
BEGIN
  -- A ladder of terms so something matures every few real minutes at 3600x
  -- (1 day = 24 s). Some are back-dated so the first minutes are not idle.
  INSERT INTO deposits (label, amount, term_days, created_at, last_interest_at) VALUES
    ('Overnight 1d',   1000, 1,  sim_now() - interval '12 hours', sim_now() - interval '12 hours'),
    ('Short 3d',       2000, 3,  sim_now() - interval '1 day',    sim_now() - interval '1 day'),
    ('Weekly 7d',      3000, 7,  sim_now() - interval '2 days',   sim_now() - interval '2 days'),
    ('Fortnight 14d',  4000, 14, sim_now() - interval '10 days',  sim_now() - interval '10 days'),
    ('Monthly 30d',    5000, 30, sim_now() - interval '20 days',  sim_now() - interval '20 days'),
    ('Alice 60d',      7500, 60, sim_now() - interval '45 days',  sim_now() - interval '45 days'),
    ('Bob 90d',       10000, 90, sim_now(),                       sim_now());

  -- A spread of cron-style jobs at different cadences, all in simulated time.
  INSERT INTO schedules (name, kind, every, days_of_month, cadence, message, next_run_at) VALUES
    ('health-check',   'interval',     interval '1 hour',  NULL,             'hourly',         'Hourly health check passed',
       next_occurrence('interval', interval '1 hour', NULL, sim_now())),
    ('fx-rates',       'interval',     interval '4 hours', NULL,             'every 4h',       'FX rates refreshed',
       next_occurrence('interval', interval '4 hours', NULL, sim_now())),
    ('risk-scan',      'interval',     interval '6 hours', NULL,             'every 6h',       'Risk exposure scan completed',
       next_occurrence('interval', interval '6 hours', NULL, sim_now())),
    ('eod-close',      'interval',     interval '1 day',   NULL,             'daily',          'End-of-day close run',
       next_occurrence('interval', interval '1 day', NULL, date_trunc('day', sim_now()) + interval '18 hours')),
    ('statement',      'interval',     interval '1 day',   NULL,             'daily',          'Daily statement generated',
       next_occurrence('interval', interval '1 day', NULL, sim_now())),
    ('reconciliation', 'interval',     interval '7 days',  NULL,             'weekly',         'Weekly ledger reconciliation',
       next_occurrence('interval', interval '7 days', NULL, sim_now())),
    ('billing',        'monthly_days', NULL,               ARRAY[5,10,17,23],'days 5,10,17,23','Billing batch executed',
       next_occurrence('monthly_days', NULL, ARRAY[5,10,17,23], sim_now())),
    ('monthly-fee',    'interval',     interval '30 days', NULL,             'every 30d',      'Monthly maintenance fee charged',
       next_occurrence('interval', interval '30 days', NULL, sim_now())),
    ('rate-review',    'interval',     interval '90 days', NULL,             'quarterly',      'Quarterly rate review',
       next_occurrence('interval', interval '90 days', NULL, sim_now()));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION reset_demo() RETURNS void AS $$
BEGIN
  TRUNCATE events, deposits, schedules, samples RESTART IDENTITY;
  UPDATE sim_clock
  SET anchor_real = now(), anchor_virtual = now(), multiplier = 3600
  WHERE id = 1;
  PERFORM seed();
END;
$$ LANGUAGE plpgsql;

SELECT seed();
