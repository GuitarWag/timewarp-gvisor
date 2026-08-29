-- Savings account with daily interest accrual and monthly posting.
-- Every "now" is Postgres now(); under runsc-warp the clock runs fast and the
-- month closes every few real minutes with no change here.

CREATE TABLE accounts (
  id               bigserial      PRIMARY KEY,
  owner            text           NOT NULL,
  name             text           NOT NULL,
  number           text           NOT NULL,
  apy              numeric(6,4)   NOT NULL,           -- 0.0450 = 4.50 %
  balance          numeric(14,2)  NOT NULL DEFAULT 0, -- posted balance
  accrued          numeric(14,6)  NOT NULL DEFAULT 0, -- interest earned, not yet posted
  opened_at        timestamptz    NOT NULL DEFAULT now(),
  last_accrual_day date           NOT NULL DEFAULT current_date
);

CREATE TABLE transactions (
  id            bigserial     PRIMARY KEY,
  account_id    bigint        NOT NULL REFERENCES accounts(id),
  posted_at     timestamptz   NOT NULL DEFAULT now(),
  kind          text          NOT NULL,   -- 'deposit' | 'interest'
  amount        numeric(14,2) NOT NULL,
  balance_after numeric(14,2) NOT NULL,
  description   text          NOT NULL
);
CREATE INDEX ON transactions (account_id, posted_at DESC);

-- One row per account day; feeds the balance chart.
CREATE TABLE accruals (
  account_id bigint        NOT NULL REFERENCES accounts(id),
  day        date          NOT NULL,
  amount     numeric(14,6) NOT NULL,
  PRIMARY KEY (account_id, day)
);

CREATE OR REPLACE FUNCTION deposit(p_account bigint, p_amount numeric, p_description text)
RETURNS void AS $$
DECLARE new_balance numeric(14,2);
BEGIN
  UPDATE accounts SET balance = balance + p_amount WHERE id = p_account
  RETURNING balance INTO new_balance;
  INSERT INTO transactions (account_id, kind, amount, balance_after, description)
  VALUES (p_account, 'deposit', p_amount, new_balance, p_description);
END;
$$ LANGUAGE plpgsql;

-- The interest engine. Walk each account forward one day at a time to today.
-- On the 1st of a month, post last month's accrued interest first, then accrue
-- the new day. Catch-up is the loop, so one call covers however many days passed.
CREATE OR REPLACE FUNCTION bank_tick() RETURNS int AS $$
DECLARE
  a      accounts%ROWTYPE;
  d      date;
  daily  numeric(14,6);
  posted numeric(14,2);
  n      int := 0;
BEGIN
  FOR a IN SELECT * FROM accounts LOOP
    WHILE a.last_accrual_day < current_date LOOP
      d := a.last_accrual_day + 1;

      IF extract(day FROM d) = 1 AND round(a.accrued, 2) > 0 THEN
        posted := round(a.accrued, 2);
        a.balance := a.balance + posted;
        a.accrued := a.accrued - posted;
        INSERT INTO transactions (account_id, posted_at, kind, amount, balance_after, description)
        VALUES (a.id, d::timestamptz, 'interest', posted, a.balance,
                'Interest for ' || to_char(d - 1, 'FMMonth YYYY'));
      END IF;

      daily := round(a.balance * a.apy / 365, 6);
      a.accrued := a.accrued + daily;
      INSERT INTO accruals (account_id, day, amount) VALUES (a.id, d, daily)
      ON CONFLICT DO NOTHING;

      a.last_accrual_day := d;
      n := n + 1;
    END LOOP;
    UPDATE accounts
    SET balance = a.balance, accrued = a.accrued, last_accrual_day = a.last_accrual_day
    WHERE id = a.id;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql;

-- Seed: one customer, one savings account, one opening deposit.
INSERT INTO accounts (owner, name, number, apy) VALUES ('Maya', 'Everyday Savings', '•••• 4821', 0.0450);
SELECT deposit(1, 1000.00, 'Opening deposit');
