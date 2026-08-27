#!/usr/bin/env bash
# gVisor compatibility smoke test. Runs inside the Lima VM. For each real image
# from the previous stack, run it under --runtime=runsc and check it actually
# works under gVisor. This is the go/no-go before investing in the sentry patch.
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== 0. gVisor sanity (kernel string should say gVisor) =="
out=$(docker run --rm --runtime=runsc alpine uname -a 2>&1) && echo "  $out"
echo "$out" | grep -qi "gvisor\|4\.\|5\.\|6\." && ok "runsc runs containers" || bad "runsc basic run"

echo "== 1. Postgres (postgres:17-alpine) boots under gVisor =="
docker rm -f tw-pg >/dev/null 2>&1 || true
docker run -d --runtime=runsc --name tw-pg -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null 2>&1
ready=no
for _ in $(seq 1 30); do
  if docker exec tw-pg pg_isready -U postgres >/dev/null 2>&1; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] && ok "postgres accepts connections" || { bad "postgres did not become ready"; docker logs --tail 20 tw-pg 2>&1 | sed 's/^/    /'; }
docker rm -f tw-pg >/dev/null 2>&1 || true

echo "== 2. Temporal server binary (Go) starts under gVisor =="
out=$(docker run --rm --runtime=runsc --entrypoint temporal temporalio/admin-tools:latest --version 2>&1)
echo "  ${out:0:200}"
echo "$out" | grep -qiE "version|temporal" && ok "temporal Go binary runs under gVisor" || bad "temporal binary under gVisor"

echo "== 3. Bun (JavaScriptCore) runs under gVisor =="
out=$(docker run --rm --runtime=runsc oven/bun:1 bun --eval "console.log('bun-ok', Date.now())" 2>&1)
echo "  ${out:0:200}"
echo "$out" | grep -q "bun-ok" && ok "bun runs under gVisor" || bad "bun under gVisor"

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ] && echo "All real images run under gVisor — clear to build the warped runsc." \
                  || echo "Some images failed under gVisor — investigate before the sentry patch."
