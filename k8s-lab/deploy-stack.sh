#!/usr/bin/env bash
# Deploy the full demo on the kind cluster: the unmodified Postgres on the warped
# RuntimeClass, seeded with stack/schema-native.sql, the Temporal dev server and
# worker on the 30x RuntimeClass, plus the Bun UI on the normal runtime. Run on the host after inject-warp-runtime.sh (use MULTIPLIER=3600 so
# the UI's "1 hr/s" label matches the node).
#
#   KIND_CLUSTER_NAME=timewarp ./k8s-lab/deploy-stack.sh
#   kubectl port-forward -n timewarp svc/twui 8080:3000   # then open http://localhost:8080
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${KIND_CLUSTER_NAME:-kind}"
MULTIPLIER="${MULTIPLIER:-86400}"   # must match what inject-warp-runtime.sh put on the nodes; only feeds the UI label

echo "==> Building the UI and worker images and loading them into the kind nodes"
docker build -q -t twui:latest "$HERE/../stack/ui" >/dev/null
docker build -q -t twworker:latest "$HERE/../stack/worker" >/dev/null
kind load docker-image twui:latest twworker:latest --name "$CLUSTER"

echo "==> Seeding schema + deploying Postgres (warped) and the UI (normal runtime)"
kubectl create namespace timewarp --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create configmap timewarp-schema -n timewarp \
  --from-file=schema.sql="$HERE/../stack/schema-native.sql" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$HERE/postgres.yaml" -f "$HERE/temporal.yaml" -f "$HERE/worker.yaml" -f "$HERE/ui.yaml" >/dev/null
# initdb only runs on an empty data dir; a fresh pod picks up the schema.
kubectl rollout restart deploy/postgres -n timewarp >/dev/null
kubectl rollout status deploy/postgres -n timewarp --timeout=180s
# The UI shows the multiplier from sim_clock; the warp itself comes from the node's runsc.toml.
for _ in $(seq 1 30); do
  kubectl exec -n timewarp deploy/postgres -- psql -U postgres -d timewarp -qc \
    "UPDATE sim_clock SET multiplier = $MULTIPLIER" >/dev/null 2>&1 && break; sleep 2
done
kubectl rollout status deploy/temporal -n timewarp --timeout=180s
kubectl rollout status deploy/worker -n timewarp --timeout=180s
kubectl rollout status deploy/twui -n timewarp --timeout=180s

echo
echo "Up. Open the UI with:"
echo "  kubectl port-forward -n timewarp svc/twui 8080:3000       # http://localhost:8080"
echo "(kubectl port-forward cannot reach gVisor pods, so the Temporal UI on 8233 is not"
echo " reachable that way; use scripts/e2e-temporal.sh or kubectl exec.)"
