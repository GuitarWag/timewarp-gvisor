#!/usr/bin/env bash
# Bring up the persistent warped stack in the VM:
#   - pg       : UNMODIFIED postgres under $RUNTIME (default runsc-warp-hour, 3600x)
#   - temporal : UNMODIFIED Temporal dev server under $TEMPORAL_RUNTIME (runsc-warp-temporal,
#                30x: the highest rate it stays healthy at, see docs/temporal-plan.md)
#   - worker   : stack/worker, same runtime as temporal (gRPC deadlines must share a clock)
#   - twui     : the Bun API + UI on the NORMAL runtime; talks to the worker over plain HTTP
# Set TEMPORAL=0 to skip temporal + worker.
set -e
H="$(cd "$(dirname "$0")/.." && pwd)"

RUNTIME="${RUNTIME:-runsc-warp-hour}"
TEMPORAL="${TEMPORAL:-1}"
TEMPORAL_RUNTIME="${TEMPORAL_RUNTIME:-runsc-warp-temporal}"
runtimes="$(docker info --format '{{json .Runtimes}}')"
for rt in "$RUNTIME" $([[ "$TEMPORAL" == 1 ]] && echo "$TEMPORAL_RUNTIME"); do
  echo "$runtimes" | grep -q "\"$rt\"" || {
    echo "runtime \"$rt\" is not registered with Docker." >&2
    echo "Run ./gvisor/build-runsc.sh then ./gvisor/install-runtimes.sh (inside the VM)." >&2
    exit 1
  }
done
# The UI label must match the runtime's flag; read it from the runtime, not from a second constant.
multiplier="$(echo "$runtimes" | python3 -c "import json,sys; r=json.load(sys.stdin)['$RUNTIME']['runtimeArgs']; print([a.split('=')[1] for a in r if a.startswith('--timewarp-multiplier=')][0])")"

docker rm -f pg twui temporal worker >/dev/null 2>&1 || true
docker network create tw >/dev/null 2>&1 || true

echo "starting warped postgres..."
docker run -d --name pg --network tw --runtime="$RUNTIME" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=timewarp \
  -v "$H/stack/schema-native.sql:/docker-entrypoint-initdb.d/schema.sql:ro" \
  postgres:17-alpine >/dev/null
for _ in $(seq 1 40); do docker exec pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec pg psql -U postgres -d timewarp -qc "UPDATE sim_clock SET multiplier = $multiplier" >/dev/null

WORKER_ENV=()
if [[ "$TEMPORAL" == 1 ]]; then
  echo "starting temporal dev server + worker ($TEMPORAL_RUNTIME)..."
  # One task-queue partition: the default 4 partitions sync over internal RPCs
  # whose deadlines fail under warp, and activities then never dispatch.
  docker run -d --name temporal --network tw --runtime="$TEMPORAL_RUNTIME" -p 8233:8233 \
    temporalio/temporal:latest server start-dev --ip 0.0.0.0 --log-level warn \
    --dynamic-config-value matching.numTaskqueueReadPartitions=1 --dynamic-config-value matching.numTaskqueueWritePartitions=1 >/dev/null
  docker build -q -t twworker:latest "$H/stack/worker" >/dev/null
  # gVisor's netstack cannot reach Docker's embedded DNS (127.0.0.11), so the
  # warped worker gets its peers' IPs in /etc/hosts instead of by lookup.
  ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
  docker run -d --name worker --network tw --runtime="$TEMPORAL_RUNTIME" -p 8088:8088 \
    --add-host "temporal:$(ip temporal)" --add-host "pg:$(ip pg)" \
    -e TEMPORAL_ADDRESS=temporal:7233 \
    -e DATABASE_URL=postgres://postgres:postgres@pg:5432/timewarp \
    twworker:latest >/dev/null
  WORKER_ENV=(-e WORKER_URL=http://worker:8088)
fi

echo "building + starting frontend (Bun API + UI, normal runtime)..."
docker build -q -t twui:latest "$(dirname "$0")/ui" >/dev/null
docker run -d --name twui --network tw \
  -e DATABASE_URL=postgres://postgres:postgres@pg:5432/timewarp \
  "${WORKER_ENV[@]}" \
  -p 8080:3000 \
  twui:latest >/dev/null

for _ in $(seq 1 30); do curl -fsS localhost:8080/healthz >/dev/null 2>&1 && break; sleep 1; done
echo
echo "stack up. quick check:"
echo "  /api/clock : $(curl -s localhost:8080/api/clock)"
echo "  deposits   : $(curl -s localhost:8080/api/deposits | head -c 200)"
if [[ "$TEMPORAL" == 1 ]]; then
  for _ in $(seq 1 60); do curl -fsS localhost:8088/healthz >/dev/null 2>&1 && break; sleep 1; done
  echo "  worker     : $(curl -s localhost:8088/healthz)  (Temporal UI: http://localhost:8233)"
fi
