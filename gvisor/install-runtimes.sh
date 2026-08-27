#!/usr/bin/env bash
# Install the clock-warped runsc and register it as Docker runtimes, one per
# multiplier. Run inside the Linux VM after build-runsc.sh.
#
#   ./gvisor/install-runtimes.sh                 # installs ~/runsc-warp or gvisor/runsc-warp
#   RUNSC=/path/to/runsc-warp ./gvisor/install-runtimes.sh
#
# Registered runtimes (name -> --timewarp-multiplier):
#   runsc-warp        1000    (1000x, the victim demo)
#   runsc-warp-hour   3600    (1 sim hour per real second, the default for stack/)
#   runsc-warp-fast   86400   (1 sim day per real second)
# `runsc install` writes /etc/docker/daemon.json; the multiplier travels to the
# sentry only through this flag.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNSC="${RUNSC:-}"
for cand in "$RUNSC" "$HOME/runsc-warp" "$HERE/runsc-warp"; do
  [[ -n "$cand" && -x "$cand" ]] && { RUNSC="$cand"; break; }
done
[[ -x "$RUNSC" ]] || { echo "no runsc-warp binary found; run build-runsc.sh first" >&2; exit 1; }

sudo install -m755 "$RUNSC" /usr/local/bin/runsc-warp

for spec in runsc-warp:1000 runsc-warp-hour:3600 runsc-warp-fast:86400; do
  name="${spec%%:*}"; mult="${spec##*:}"
  sudo /usr/local/bin/runsc-warp install --runtime="$name" -- \
    --platform=systrap --timewarp-multiplier="$mult"
done
sudo systemctl restart docker

echo "==> registered runtimes:"
docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' | tr ' ' '\n' | grep runsc-warp
