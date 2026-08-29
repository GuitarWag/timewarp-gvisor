# Plan: a customer-facing savings account on the warped clock

Status: implemented 2026-08-29. Code in `stack/bank/`. Runs at 5 simulated hours
per real second (18000x): a day is 4.8 s, a month about 2.5 minutes.

## What it shows

One savings account opened with a 1,000.00 deposit. An interest engine accrues
daily and posts the month's interest to the ledger as one transaction on the
1st. The customer sees what a banking app would show: balance, interest earned
so far this month (pending), the next payment date, the ledger, and a balance
line. Every date on the page is the account's date, read from Postgres `now()`.

Nothing in the bank knows about the warp. The database container runs on the
`runsc-warp-5h` runtime; the Go server runs on the normal runtime and takes
every "now" from SQL.

## Shape

One Go binary, `stack/bank`, standard library `net/http` plus `pgx`.

```
GET  /                  the frontend (embedded, one HTML file)
GET  /api/account       balance, APY, accrued this month, next posting date, account time
GET  /api/transactions  the ledger, newest first
GET  /api/series        one point per account day: posted balance + accrued to date
POST /api/deposit       {"amount": N} adds money (the one customer action)
```

A goroutine calls `SELECT bank_tick()` every 300 ms real. The function reasons
in database time: it walks `last_accrual_day` forward one day at a time to
`current_date`, accruing `balance * apy / 365` per day, and when a day is the
first of a new month it first posts the accrued amount as an `interest`
transaction. Catch-up is a loop, so a slow tick just does several days at once.
Same pattern as `schema-native.sql`'s `tick()`.

Schema (`bank.sql`): `accounts` (balance, apy, accrued, last_accrual_day),
`transactions` (posted_at, kind, amount, balance_after, description),
`accruals` (one row per day, for the chart). Money is `numeric(14,2)` in the
ledger and `numeric(14,6)` for the running accrual, rounded at posting.

## Frontend

Customer's point of view, phone-width column, no admin controls. Design plan
from the `artifact-design` and `dataviz` skills:

- Palette: cool-green-biased neutrals (`#F5F8F6` ground, `#14201A` ink,
  `#5C6E65` muted), one accent `#1E6B4B` (deep green; `#5FBF95` on dark), credit
  amounts in the same family, pending interest in amber `#A8721A`. Dark theme is
  its own set, not an inversion.
- Type: Manrope for text, DM Mono for every figure and date (tabular numerals).
- Layout: balance as the hero number, then a pending-interest row with a
  progress bar to the next posting date, the balance line chart (single series,
  2 px line, soft area, hover crosshair, no legend), then the ledger grouped by
  month with interest postings marked.
- The chart's single series and the semantic colors are validated with the
  dataviz palette script.

## Run

```bash
./gvisor/install-runtimes.sh          # adds runsc-warp-5h (18000x)
bash stack/bank/up.sh                 # bankpg (warped) + bank (normal), http://localhost:8090
CONTAINER=bankpg scripts/e2e-bank.sh  # waits for the first monthly interest posting
docker rm -f bank bankpg
```

## Result

`scripts/e2e-bank.sh` on Docker at 18000x: two accrual days (0.12 + 0.12),
then on 1 September one ledger row `Interest for August 2026 | 0.25 | 1000.25`,
and the new month's accrual started at 0.12. Screenshot in `docs/bank-ui.png`.
The `dataviz` palette validator passes the light pair; the dark amber for
pending interest sits a step above the validator's lightness band, accepted
because it is a labelled status colour, not a chart series.

## Out of scope

Multiple accounts, auth, transfers, statements as documents, and anything
that needs the bank to share a clock with another warped service.
