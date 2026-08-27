#!/usr/bin/env bash
# Run UNMODIFIED Postgres under runsc-warp-fast (86400x) and watch a 90-day
# term deposit mature in ~90 real seconds, using plain now() — no sim_now().
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
docker rm -f twpg >/dev/null 2>&1 || true

docker run -d --runtime=runsc-warp-fast --name twpg \
  -e POSTGRES_PASSWORD=x -e POSTGRES_DB=timewarp \
  -v "$HERE/schema.sql:/docker-entrypoint-initdb.d/schema.sql:ro" \
  postgres:17-alpine >/dev/null

echo "waiting for postgres (unmodified image, under gVisor warp)..."
for _ in $(seq 1 40); do docker exec twpg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2

docker exec twpg psql -U postgres -d timewarp -c \
  "insert into deposits(label) values ('90-day term deposit')" >/dev/null
echo "opened deposit. 90 simulated days = ~90 real seconds at 86400x:"
echo

t0=$(date +%s)
for _ in $(seq 1 11); do
  real=$(( $(date +%s) - t0 ))
  line=$(docker exec twpg psql -U postgres -d timewarp -tA -F' | ' -c \
    "select to_char(now(),'YYYY-MM-DD HH24:MI'), to_char(created_at+make_interval(days=>term_days),'YYYY-MM-DD'), case when now()>=created_at+make_interval(days=>term_days) then 'MATURED' else 'pending' end from deposits;")
  printf "  real+%-3ss  sim_now=%s  matures=%s  ->  %s\n" "$real" "${line%% | *}" "$(echo "$line" | cut -d'|' -f2 | xargs)" "${line##* | }"
  sleep 9
done

docker rm -f twpg >/dev/null 2>&1 || true
