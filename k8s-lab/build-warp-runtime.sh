#!/usr/bin/env bash
# Build the clock-warped runsc AND the gVisor containerd shim for a Kubernetes
# RuntimeClass on a KinD cluster. Linux only: run inside the Lima VM. Both
# binaries match the node arch (arm64 on Apple Silicon).
#
#   limactl shell gvisor -- bash "$PWD/k8s-lab/build-warp-runtime.sh"
#
# Output goes to k8s-lab/bin/. If the repo mount is read-only in the VM, it
# goes to ~/k8s-lab-bin instead and the script prints the limactl cp to run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HERE/bin}"
if ! mkdir -p "$OUT" 2>/dev/null || [[ ! -w "$OUT" ]]; then
  OUT="$HOME/k8s-lab-bin"; mkdir -p "$OUT"
  COPY_HINT=1
fi

BIN_DIR="$OUT"
OUT="$BIN_DIR/runsc-warp" SHIM_OUT="$BIN_DIR/containerd-shim-runsc-v1" "$HERE/../gvisor/build-runsc.sh"

ls -la "$OUT"
if [[ -n "${COPY_HINT:-}" ]]; then
  echo
  echo "Repo mount is read-only here. On the host run:"
  echo "  limactl cp -r gvisor:$BIN_DIR/. k8s-lab/bin/"
fi
