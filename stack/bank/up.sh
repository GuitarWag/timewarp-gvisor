#!/usr/bin/env bash
# The bank demo in the VM:
#   - bankpg : UNMODIFIED postgres under $RUNTIME (default runsc-warp-5h, 18000x = 5 sim hours per real second)
#   - bank   : the Go server (API + customer frontend + interest engine) on the NORMAL runtime
# Open http://localhost:8090 on the host.
set -e
H="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME="${RUNTIME:-runsc-warp-5h}"

docker info --format '{{json .Runtimes}}' | grep -q "\"$RUNTIME\"" || {
  echo "runtime \"$RUNTIME\" is not registered with Docker." >&2
  echo "Run ./gvisor/build-runsc.sh then ./gvisor/install-runtimes.sh (inside the VM)." >&2
  exit 1
}

docker rm -f bank bankpg >/dev/null 2>&1 || true
docker network create bank >/dev/null 2>&1 || true

echo "starting warped postgres ($RUNTIME)..."
docker run -d --name bankpg --network bank --runtime="$RUNTIME" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=bank \
  -v "$H/stack/bank/bank.sql:/docker-entrypoint-initdb.d/bank.sql:ro" \
  postgres:17-alpine >/dev/null
for _ in $(seq 1 40); do docker exec bankpg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done

echo "building + starting the bank (normal runtime)..."
docker build -q -t bank:latest "$H/stack/bank" >/dev/null
docker run -d --name bank --network bank \
  -e DATABASE_URL=postgres://postgres:postgres@bankpg:5432/bank \
  -p 8090:8090 bank:latest >/dev/null
for _ in $(seq 1 30); do curl -fsS localhost:8090/healthz >/dev/null 2>&1 && break; sleep 1; done

echo
echo "bank up: http://localhost:8090"
echo "  /api/account : $(curl -s localhost:8090/api/account | head -c 240)"
