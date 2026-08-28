#!/usr/bin/env bash
# Deploy the full demo on the kind cluster: the unmodified Postgres on the warped
# RuntimeClass, seeded with stack/schema-native.sql, plus the Bun UI on the normal
# runtime. Run on the host after inject-warp-runtime.sh (use MULTIPLIER=3600 so
# the UI's "1 hr/s" label matches the node).
#
#   KIND_CLUSTER_NAME=timewarp ./k8s-lab/deploy-stack.sh
#   kubectl port-forward -n timewarp svc/twui 8080:3000   # then open http://localhost:8080
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${KIND_CLUSTER_NAME:-kind}"

echo "==> Building the UI image and loading it into the kind nodes"
docker build -q -t twui:latest "$HERE/../stack/ui" >/dev/null
kind load docker-image twui:latest --name "$CLUSTER"

echo "==> Seeding schema + deploying Postgres (warped) and the UI (normal runtime)"
kubectl create namespace timewarp --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create configmap timewarp-schema -n timewarp \
  --from-file=schema.sql="$HERE/../stack/schema-native.sql" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$HERE/postgres.yaml" -f "$HERE/ui.yaml" >/dev/null
# initdb only runs on an empty data dir; a fresh pod picks up the schema.
kubectl rollout restart deploy/postgres -n timewarp >/dev/null
kubectl rollout status deploy/postgres -n timewarp --timeout=180s
kubectl rollout status deploy/twui -n timewarp --timeout=180s

echo
echo "Up. Open the UI with:"
echo "  kubectl port-forward -n timewarp svc/twui 8080:3000   # http://localhost:8080"
