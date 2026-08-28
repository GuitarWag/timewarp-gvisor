#!/usr/bin/env bash
# End-to-end time-warp test against a warped Postgres, on Docker or Kubernetes.
#
# Opens a term deposit and polls the server clock (plain now()) until it matures.
# The same unmodified Postgres, the same SQL; only the way psql is reached differs.
#
#   Docker (stack/up.sh):  CONTAINER=pg TERM_DAYS=2 ./scripts/e2e-maturity.sh
#   Kubernetes (k8s-lab):  NS=timewarp DEPLOY=postgres TERM_DAYS=2 ./scripts/e2e-maturity.sh
#
# Pick TERM_DAYS for the multiplier: 90 days is ~90 s at 86400x, 2 days is ~48 s
# at 3600x.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${CONTAINER:-}"
NS="${NS:-}"
DEPLOY="${DEPLOY:-}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
TERM_DAYS="${TERM_DAYS:-90}"
DEADLINE="${DEADLINE:-300}"   # real-seconds budget before we call it a failure

if [[ -n "$CONTAINER" ]]; then
  echo "==> Docker container $CONTAINER (user=$PGUSER db=$PGDATABASE)"
  psql() { docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDATABASE" -tA "$@"; }
  where="runtime $(docker inspect -f '{{.HostConfig.Runtime}}' "$CONTAINER")"
else
  [[ -n "$NS" && -n "$DEPLOY" ]] || { echo "set CONTAINER=<docker name> or NS=<ns> DEPLOY=<deployment>" >&2; exit 1; }
  pod="$(kubectl get pod -n "$NS" -l app="$DEPLOY" --field-selector=status.phase=Running -o name | head -1)"
  [[ -n "$pod" ]] || { echo "no running pod for app=$DEPLOY in $NS" >&2; exit 1; }
  pod="${pod#pod/}"
  echo "==> Pod $NS/$pod (user=$PGUSER db=$PGDATABASE)"
  psql() { kubectl exec -n "$NS" "$pod" -i -- psql -U "$PGUSER" -d "$PGDATABASE" -tA "$@"; }
  where="runtimeClassName $(kubectl get pod -n "$NS" "$pod" -o jsonpath='{.spec.runtimeClassName}')"
fi
echo "==> $where"
[[ "$where" == *runsc-warp* ]] || echo "    WARNING: not on a runsc-warp runtime; the clock will not warp"

echo "==> Loading the maturity probe, opening a ${TERM_DAYS}-day deposit"
psql < "$HERE/maturity-test.sql" >/dev/null
psql -c "INSERT INTO timewarp_lab.deposits (label, term_days) VALUES ('term deposit', $TERM_DAYS)" >/dev/null
echo

t0=$(date +%s); real=0; matured=no
while (( $(date +%s) - t0 < DEADLINE )); do
  # At high multipliers Postgres' own timeouts (authentication_timeout 60 s is
  # 0.7 ms real at 86400x) drop the odd connection; retry instead of aborting.
  if ! row="$(psql -F'|' -c 'SELECT sim_now, matures_on, matured FROM timewarp_lab.status;' 2>/dev/null)"; then
    echo "  (connection dropped, retrying)"; sleep 2; continue
  fi
  real=$(( $(date +%s) - t0 ))
  sim_now="${row%%|*}"; rest="${row#*|}"; matures_on="${rest%%|*}"; is_matured="${rest##*|}"
  printf "  real+%-4ss  sim_now=%s  matures_on=%s  %s\n" \
    "$real" "$sim_now" "$matures_on" "$([[ "$is_matured" == t ]] && echo '** MATURED **' || echo pending)"
  if [[ "$is_matured" == t ]]; then matured=yes; break; fi
  sleep 5
done

echo
if [[ "$matured" == yes ]]; then
  echo "PASS: a ${TERM_DAYS}-day deposit matured in ${real}s of real time, off plain now()."
else
  echo "FAIL: not matured within ${DEADLINE}s. Is Postgres on runsc-warp, and is TERM_DAYS small enough for the multiplier?"
  exit 1
fi
