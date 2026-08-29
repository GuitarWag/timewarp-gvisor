#!/usr/bin/env bash
# Does the Temporal dev server stay healthy on a warped clock? Run in the VM.
# Starts `temporal server start-dev` under each warp runtime, waits, checks
# cluster health, starts a workflow with no worker, and lists it. All CLI calls
# run inside the same container (same clock domain; see docs/temporal-plan.md).
#
#   scripts/smoke-temporal.sh                         # runsc-warp runsc-warp-hour runsc-warp-fast
#   RUNTIMES="runsc-warp-hour" scripts/smoke-temporal.sh
set -uo pipefail

RUNTIMES="${RUNTIMES:-runsc-warp runsc-warp-hour runsc-warp-fast}"
HOLD="${HOLD:-60}"   # real seconds the server must stay healthy
IMG=temporalio/temporal:latest

for rt in $RUNTIMES; do
  name="tw-temporal-smoke"
  docker rm -f "$name" >/dev/null 2>&1 || true
  echo "== $rt"
  docker run -d --name "$name" --runtime="$rt" "$IMG" \
    server start-dev --ip 0.0.0.0 --log-level warn \
    --dynamic-config-value matching.numTaskqueueReadPartitions=1 --dynamic-config-value matching.numTaskqueueWritePartitions=1 >/dev/null
  sleep 10
  tcli() { docker exec "$name" temporal "$@"; }
  ok=yes
  if ! tcli operator cluster health 2>&1 | grep -q SERVING; then echo "   health: FAIL"; ok=no; fi
  if [[ $ok == yes ]]; then
    tcli workflow start --task-queue smoke --type Noop --workflow-id smoke-1 >/dev/null 2>&1 \
      || { echo "   workflow start: FAIL"; ok=no; }
  fi
  if [[ $ok == yes ]]; then
    tcli workflow list 2>/dev/null | grep -q smoke-1 || { echo "   workflow list: FAIL"; ok=no; }
  fi
  if [[ $ok == yes ]]; then
    sleep "$HOLD"
    tcli operator cluster health 2>&1 | grep -q SERVING || { echo "   health after ${HOLD}s: FAIL"; ok=no; }
  fi
  if [[ $ok == yes ]]; then
    echo "   PASS: healthy for ${HOLD}s, workflow started and listed"
  else
    docker logs "$name" 2>&1 | tail -5 | sed 's/^/   | /'
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
done
