#!/usr/bin/env bash
# Build the clock-warped runsc AND the gVisor containerd shim, for use as a
# Kubernetes RuntimeClass on a KinD cluster. Linux only — run inside the
# Lima VM (lima/gvisor.yaml). Outputs both binaries to k8s-lab/bin/, matching the
# node arch (arm64 on Apple Silicon).
#
#   limactl shell gvisor -- bash /path/to/k8s-lab/build-warp-runtime.sh
#
# Then copy k8s-lab/bin/ to the host and run inject-warp-runtime.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GVISOR_TAG="${GVISOR_TAG:-release-20260622.0}"   # tag clockwarp.patch is pinned to
GVISOR_REF="${GVISOR_REF:-go}"                   # buildable module snapshot
OUT="$HERE/bin"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Build on Linux (the kind node arch). Use the Lima VM: lima/gvisor.yaml" >&2
  exit 1
fi

mkdir -p "$OUT"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> Fetching buildable gVisor tree (@$GVISOR_REF)"
GOBIN="$BUILD/gobin" go install "gvisor.dev/gvisor/runsc@$GVISOR_REF"
SRC="$BUILD/gvisor"
cp -r "$(go env GOMODCACHE)"/gvisor.dev/gvisor@*/. "$SRC"
chmod -R u+w "$SRC"

echo "==> Applying clock-warp patch (pinned to $GVISOR_TAG)"
if ! git -C "$SRC" apply "$HERE/../gvisor/clockwarp.patch" 2>/dev/null; then
  echo "    static patch did not apply to @$GVISOR_REF; re-porting via apply-clockwarp.py"
  python3 "$HERE/../gvisor/apply-clockwarp.py" "$SRC"
fi

echo "==> Building runsc-warp and containerd-shim-runsc-v1"
( cd "$SRC" && go build -o "$OUT/runsc-warp" ./runsc )
( cd "$SRC" && go build -o "$OUT/containerd-shim-runsc-v1" ./shim )

echo "==> Built:"
ls -la "$OUT"
"$OUT/runsc-warp" --version
