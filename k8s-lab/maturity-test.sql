-- Time-warp maturity probe. Runs entirely off the server clock (now()), so when
-- the Postgres pod is on the runsc-warp runtime, a 90-day term "matures" in real
-- seconds with zero application changes.
CREATE SCHEMA IF NOT EXISTS timewarp_lab;

DROP TABLE IF EXISTS timewarp_lab.deposits;
CREATE TABLE timewarp_lab.deposits (
  id         bigserial PRIMARY KEY,
  label      text        NOT NULL,
  term_days  int         NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO timewarp_lab.deposits (label, term_days)
VALUES ('90-day term deposit', 90);

-- Status view: server clock, maturity date, and whether it has matured yet.
CREATE OR REPLACE VIEW timewarp_lab.status AS
SELECT
  to_char(now(), 'YYYY-MM-DD HH24:MI:SS')                                  AS sim_now,
  to_char(created_at + make_interval(days => term_days), 'YYYY-MM-DD')     AS matures_on,
  (now() >= created_at + make_interval(days => term_days))                 AS matured
FROM timewarp_lab.deposits
ORDER BY id
LIMIT 1;
