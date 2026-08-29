#!/usr/bin/env bash
# End-to-end Temporal test on the warped clock, Docker or Kubernetes.
#
# Starts FlakyReconciliation through the worker's HTTP API and waits for the
# activity's 5th attempt to land in the events table. The four retry waits
# (1m, 2m, 4m, 8m by default) are server-side timers: 15 simulated minutes,
# ~30 real seconds at 30x.
#
#   Docker (stack/up.sh):  CONTAINER=pg ./scripts/e2e-temporal.sh
#   Kubernetes (k8s-lab):  NS=timewarp DEPLOY=postgres ./scripts/e2e-temporal.sh
set -euo pipefail

CONTAINER="${CONTAINER:-}"
NS="${NS:-}"
DEPLOY="${DEPLOY:-}"
WORKER="${WORKER:-http://localhost:8088}"
DEADLINE="${DEADLINE:-120}"

if [[ -n "$CONTAINER" ]]; then
  psql() { docker exec -i "$CONTAINER" psql -U postgres -d timewarp -tA "$@"; }
  post() { curl -fsS -X POST "$WORKER/run" -H 'content-type: application/json' -d "$1"; }
else
  [[ -n "$NS" && -n "$DEPLOY" ]] || { echo "set CONTAINER=<docker name> or NS=<ns> DEPLOY=<deployment>" >&2; exit 1; }
  pod="$(kubectl get pod -n "$NS" -l app="$DEPLOY" --field-selector=status.phase=Running -o name | head -1)"
  pod="${pod#pod/}"
  psql() { kubectl exec -n "$NS" "$pod" -i -- psql -U postgres -d timewarp -tA "$@"; }
  # kubectl port-forward cannot reach a gVisor pod (it dials 127.0.0.1 in the pod's
  # netns; the sandbox listens in its own netstack). Call the worker from the UI
  # pod instead, with bun since that image has no curl.
  WORKER="http://worker:8088"
  post() {
    kubectl exec -n "$NS" deploy/twui -- bun -e \
      "const r = await fetch('$WORKER/run', {method:'POST', headers:{'content-type':'application/json'}, body: process.argv[1]}); if (!r.ok) { console.error(r.status, await r.text()); process.exit(1) }" \
      -- "$1"
  }
fi

before="$(psql -c 'SELECT coalesce(max(id),0) FROM events')"
id="e2e-$(date +%s)"
echo "==> Starting FlakyReconciliation (id $id) via $WORKER"
for attempt in 1 2 3 4 5; do
  post "{\"workflow\":\"FlakyReconciliation\",\"id\":\"$id\"}" && break
  [[ $attempt == 5 ]] && { echo "worker unreachable at $WORKER" >&2; exit 1; }
  sleep 2
done

t0=$(date +%s); real=0; done_=no
while (( $(date +%s) - t0 < DEADLINE )); do
  real=$(( $(date +%s) - t0 ))
  rows="$(psql -c "SELECT kind || ' @ ' || to_char(sim_at,'HH24:MI:SS') FROM events WHERE id > $before AND kind IN ('temporal.retry','temporal.reconciled') ORDER BY id" 2>/dev/null || true)"
  n=$(echo "$rows" | grep -c . || true)
  printf "  real+%-4ss  %s attempts logged\n" "$real" "$n"
  if echo "$rows" | grep -q temporal.reconciled; then done_=yes; break; fi
  sleep 5
done
echo
echo "$rows" | sed 's/^/  /'
echo
if [[ "$done_" == yes ]]; then
  echo "PASS: reconciliation succeeded after exponential backoff in ${real}s of real time."
else
  echo "FAIL: no temporal.reconciled event within ${DEADLINE}s."
  exit 1
fi
