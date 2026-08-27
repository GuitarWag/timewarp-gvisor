#!/usr/bin/env bash
# Bring up the persistent warped stack in the VM:
#   - postgres : UNMODIFIED image under runsc-warp-fast (86400x)  -> warped now()
#   - twui     : the demo's Bun API + UI on the NORMAL runtime    -> real-time pacing
# The UI reads Postgres's warped clock; deposits/interest/cron all run off now().
set -e
H="$(cd "$(dirname "$0")/.." && pwd)"

docker rm -f pg twui >/dev/null 2>&1 || true
docker network create tw >/dev/null 2>&1 || true

echo "starting warped postgres..."
docker run -d --name pg --network tw --runtime=runsc-warp-fast \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=timewarp \
  -v "$H/stack/schema-native.sql:/docker-entrypoint-initdb.d/schema.sql:ro" \
  postgres:17-alpine >/dev/null
for _ in $(seq 1 40); do docker exec pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done

echo "building + starting frontend (Bun API + UI, normal runtime)..."
docker build -q -t twui:latest "$(dirname "$0")/ui" >/dev/null
docker run -d --name twui --network tw \
  -e DATABASE_URL=postgres://postgres:postgres@pg:5432/timewarp \
  -e WORKER_URL=http://disabled:0 \
  -p 8080:3000 \
  twui:latest >/dev/null

for _ in $(seq 1 30); do curl -fsS localhost:8080/healthz >/dev/null 2>&1 && break; sleep 1; done
echo
echo "stack up. quick check:"
echo "  /api/clock : $(curl -s localhost:8080/api/clock)"
echo "  deposits   : $(curl -s localhost:8080/api/deposits | head -c 200)"
