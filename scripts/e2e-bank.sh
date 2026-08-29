#!/usr/bin/env bash
# End-to-end check for the bank demo: daily accrual runs, and the month's interest
# is posted to the ledger as one transaction. At 18000x a month is ~2.5 real minutes.
#
#   CONTAINER=bankpg ./scripts/e2e-bank.sh
set -euo pipefail

CONTAINER="${CONTAINER:-bankpg}"
DEADLINE="${DEADLINE:-360}"
psql() { docker exec -i "$CONTAINER" psql -U postgres -d bank -tA "$@"; }

echo "==> Docker container $CONTAINER, runtime $(docker inspect -f '{{.HostConfig.Runtime}}' "$CONTAINER")"
before="$(psql -c "SELECT count(*) FROM transactions WHERE kind = 'interest'")"
t0=$(date +%s); real=0; ok=no
while (( $(date +%s) - t0 < DEADLINE )); do
  real=$(( $(date +%s) - t0 ))
  if ! row="$(psql -F'|' -c "SELECT to_char(now(),'YYYY-MM-DD'), balance, round(accrued,2),
                        (SELECT count(*) FROM accruals), (SELECT count(*) FROM transactions WHERE kind='interest')
                        FROM accounts WHERE id = 1" 2>/dev/null)"; then
    echo "  (connection dropped)"; sleep 2; continue
  fi
  IFS='|' read -r day balance accrued days posts <<<"$row"
  printf "  real+%-4ss  account date %s  balance %s  accrued %s  days %s  interest postings %s\n" \
    "$real" "$day" "$balance" "$accrued" "$days" "$posts"
  if (( posts > before )); then ok=yes; break; fi
  sleep 5
done
echo
psql -F' | ' -c "SELECT to_char(posted_at,'YYYY-MM-DD'), kind, amount, balance_after, description FROM transactions ORDER BY id" | sed 's/^/  /'
echo
if [[ $ok == yes ]]; then
  echo "PASS: monthly interest posted to the ledger after ${real}s of real time, off plain now()."
else
  echo "FAIL: no interest posting within ${DEADLINE}s."; exit 1
fi
