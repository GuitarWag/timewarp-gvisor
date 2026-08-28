#!/usr/bin/env bash
# Move the local-dev Postgres pod onto the clock-warped runtime.
#
# Postgres in local-dev is a single-pod Deployment (not distributed), so warping
# it is internally consistent — now() simply runs fast. This is the safe target.
#
# Flux would revert a live patch on reconcile, so we suspend the owning
# Kustomization first. Restore later with: flux resume kustomization <name>
# (or the GitOps-proper route: add the patch below to the local-dev overlay).
#
#   ./warp-postgres.sh                         # auto-discover the postgres deployment
#   NS=temporal DEPLOY=postgresql ./warp-postgres.sh
set -euo pipefail

NS="${NS:-}"
DEPLOY="${DEPLOY:-}"

if [[ -z "$NS" || -z "$DEPLOY" ]]; then
  echo "==> Discovering the Postgres deployment"
  line="$(kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | grep -iE 'postgre|^.* pg($| )' | head -1 || true)"
  [[ -n "$line" ]] || { echo "no postgres Deployment found; set NS=... DEPLOY=..." >&2; exit 1; }
  NS="${NS:-${line%% *}}"
  DEPLOY="${DEPLOY:-${line##* }}"
fi
echo "    target: deployment/$DEPLOY in namespace $NS"

# Suspend the Flux Kustomization that manages this namespace, if any, so the
# runtimeClassName patch is not reconciled away.
ks="$(kubectl get kustomization -n flux-system -o name 2>/dev/null \
  | sed 's#kustomization.kustomize.toolkit.fluxcd.io/##' \
  | grep -iE 'postgre|data-platform|infra' | head -1 || true)"
if [[ -n "$ks" ]]; then
  echo "==> Suspending Flux kustomization '$ks' so the patch sticks"
  flux suspend kustomization "$ks" 2>/dev/null || kubectl patch kustomization "$ks" \
    -n flux-system --type=merge -p '{"spec":{"suspend":true}}'
fi

echo "==> Patching runtimeClassName: runsc-warp onto $DEPLOY"
kubectl patch deployment "$DEPLOY" -n "$NS" --type=merge \
  -p '{"spec":{"template":{"spec":{"runtimeClassName":"runsc-warp"}}}}'

echo "==> Waiting for the warped pod to roll out"
kubectl rollout status deployment "$DEPLOY" -n "$NS" --timeout=180s

echo
echo "Postgres is now warped. Verify the pod runs under gVisor (expect 'runsc-warp'"
echo "and a sandboxed 'dmesg' that mentions gVisor):"
echo "  kubectl get pods -n $NS -o jsonpath='{.items[*].spec.runtimeClassName}'; echo"
echo "Then run: NS=$NS DEPLOY=$DEPLOY ./scripts/e2e-maturity.sh"
