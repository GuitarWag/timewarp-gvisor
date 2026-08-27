#!/usr/bin/env bash
# Baseline demo, runnable on macOS today: shows the control plane + workload.
# It does NOT warp the victim yet (that needs the patched runsc) — it proves the
# pieces and shows the virtual clock the sentry would serve at a given rate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> build authority + victim"
( cd "$ROOT/authority" && go build -o /tmp/tw-authority . )
( cd "$ROOT/victim"    && go build -o /tmp/tw-victim . )

echo "==> start clock authority"
ADDR=":8099" /tmp/tw-authority & AUTH=$!
trap 'kill $AUTH 2>/dev/null' EXIT
sleep 1

echo
echo "==> victim running NORMALLY (real time) for 5s — the 'before':"
TIMER=24h /tmp/tw-victim & VICTIM=$!
sleep 5; kill "$VICTIM" 2>/dev/null || true

echo
echo "==> set authority to 1000x and read the virtual clock it would serve:"
curl -s -X POST localhost:8099/rate -H 'content-type: application/json' -d '{"multiplier":1000}' >/dev/null
for _ in 1 2 3; do
  curl -s localhost:8099/now | sed 's/^/   /'
  echo
  sleep 1
done

echo
echo "Under a patched runsc, the victim above would inherit THIS clock — wall time"
echo "racing ~1000x and its 24h timer firing in ~86s — with no change to its code."
echo "Next: build the warped runsc (gvisor/build-runsc.sh) on a Linux host."
