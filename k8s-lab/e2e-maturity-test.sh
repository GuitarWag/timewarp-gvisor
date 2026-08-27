#!/usr/bin/env bash
# End-to-end time-warp test against the warped Postgres.
#
# Opens a 90-day term deposit and polls the server clock until it matures. Under
# runsc-warp at 86400x, 90 simulated days elapse in ~90 real seconds, proving the
# warp on a real component with no application change. Run after warp-postgres.sh.
#
#   NS=temporal DEPLOY=postgresql ./e2e-maturity-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:?set NS to the postgres namespace}"
DEPLOY="${DEPLOY:?set DEPLOY to the postgres deployment}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
DEADLINE="${DEADLINE:-300}"   # real-seconds budget before we call it a failure

pod="$(kubectl get pod -n "$NS" -l app="$DEPLOY" -o name 2>/dev/null | head -1)"
[[ -n "$pod" ]] || pod="$(kubectl get pod -n "$NS" -o name | grep -iE 'postgre|pg' | head -1)"
[[ -n "$pod" ]] || { echo "could not find a postgres pod in $NS" >&2; exit 1; }
pod="${pod#pod/}"
echo "==> Using pod $NS/$pod (user=$PGUSER db=$PGDATABASE)"

psql() { kubectl exec -n "$NS" "$pod" -i -- psql -U "$PGUSER" -d "$PGDATABASE" -tA "$@"; }

rtc="$(kubectl get pod -n "$NS" "$pod" -o jsonpath='{.spec.runtimeClassName}')"
echo "==> Pod runtimeClassName: ${rtc:-<none>}"
[[ "$rtc" == "runsc-warp" ]] || echo "    WARNING: pod is not on runsc-warp — run warp-postgres.sh first"

echo "==> Loading the maturity probe"
psql < "$HERE/maturity-test.sql" >/dev/null
echo "==> Opened a 90-day term deposit. Polling the server clock:"
echo

t0=$(date +%s)
matured=no
while (( $(date +%s) - t0 < DEADLINE )); do
  row="$(psql -F'|' -c 'SELECT sim_now, matures_on, matured FROM timewarp_lab.status;')"
  real=$(( $(date +%s) - t0 ))
  sim_now="${row%%|*}"; rest="${row#*|}"; matures_on="${rest%%|*}"; is_matured="${rest##*|}"
  printf "  real+%-4ss  sim_now=%s  matures_on=%s  %s\n" \
    "$real" "$sim_now" "$matures_on" "$([[ "$is_matured" == t ]] && echo '** MATURED **' || echo pending)"
  if [[ "$is_matured" == t ]]; then matured=yes; break; fi
  sleep 5
done

echo
if [[ "$matured" == yes ]]; then
  echo "PASS: a 90-day deposit matured in ${real}s of real time, off plain now()."
else
  echo "FAIL: not matured within ${DEADLINE}s — is the pod really on runsc-warp," \
       "and is the multiplier high enough? (86400x -> ~90s)"
  exit 1
fi
