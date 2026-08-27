#!/usr/bin/env bash
# Build a clock-warped runsc.
#
# Default route is the lighter no-bazel build (proven on 2026-06-16): the
# module-proxy @go version is a fully buildable tree, so we copy it, apply the
# clock-warp patch, and `go build ./runsc`. No Docker, no bazel.
#
# clockwarp.patch is pinned to GVISOR_TAG. The @go snapshot can drift from that
# tag; if the patch will not apply, we fall back to apply-clockwarp.py, which
# re-ports the same edits by matching source anchors (and tells you if those
# moved too).
#
# Linux only — runsc builds and runs on Linux.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GVISOR_TAG="${GVISOR_TAG:-release-20260622.0}"   # the tag clockwarp.patch is generated against
# Buildable go-branch snapshot that contains GVISOR_TAG ("Merge release-20260615.0-67", 2026-06-24).
# @go is a moving target and drifted past the patch on 2026-08-27; pin instead.
GVISOR_REF="${GVISOR_REF:-d10071d635665b840936420353a489ca5f9f250d}"
OUT="${OUT:-$HERE/runsc-warp}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "runsc builds and runs on Linux only. Run this inside a Linux VM/container." >&2
  echo "On macOS: use the Lima VM (see lima/gvisor.yaml)." >&2
  exit 1
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> Fetching buildable gVisor tree (@$GVISOR_REF) into the module cache"
# -json gives the exact cache dir; a gvisor@* glob would merge trees if the
# cache holds more than one version.
MOD_DIR="$(go mod download -json "gvisor.dev/gvisor@$GVISOR_REF" | sed -n 's/.*"Dir": "\(.*\)".*/\1/p')"
[[ -d "$MOD_DIR" ]] || { echo "go mod download did not report a Dir" >&2; exit 1; }

echo "==> Copying tree to a writable location"
SRC="$BUILD/gvisor"
cp -r "$MOD_DIR" "$SRC"
chmod -R u+w "$SRC"

echo "==> Applying clock-warp patch (pinned to $GVISOR_TAG)"
if git -C "$SRC" apply "$HERE/clockwarp.patch" 2>/dev/null; then
  echo "    applied clockwarp.patch"
else
  echo "    clockwarp.patch did not apply to @$GVISOR_REF; re-porting via apply-clockwarp.py"
  python3 "$HERE/apply-clockwarp.py" "$SRC"
fi

echo "==> Building runsc"
( cd "$SRC" && go build -o "$OUT" ./runsc )
echo "==> Built: $OUT"
"$OUT" --version
