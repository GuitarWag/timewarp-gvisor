-- Native-time deposit schema. Note: NO sim_now() — this uses plain now().
-- Under runsc-warp the OS clock itself runs fast, so an unmodified Postgres
-- with ordinary SQL produces an accelerated 90-day maturity for free.
CREATE TABLE deposits (
  id         bigserial   PRIMARY KEY,
  label      text        NOT NULL,
  amount     numeric     NOT NULL DEFAULT 1000,
  term_days  int         NOT NULL DEFAULT 90,
  created_at timestamptz NOT NULL DEFAULT now()
);
