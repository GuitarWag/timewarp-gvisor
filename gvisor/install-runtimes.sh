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
#   runsc-warp-temporal  30   (the highest rate the Temporal dev server stays healthy at;
#                              60-100x is flaky, >=200x fails; see docs/temporal-plan.md)
# Every runtime also gets --timewarp-delay=$TIMEWARP_DELAY (default 10s): the
# clocks run at 1x for that long after boot so services with start-up deadlines
# (Temporal) come up before the warp kicks in.
# `runsc install` writes /etc/docker/daemon.json; the flags travel to the
# sentry only this way.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNSC="${RUNSC:-}"
TIMEWARP_DELAY="${TIMEWARP_DELAY:-10s}"
for cand in "$RUNSC" "$HOME/runsc-warp" "$HERE/runsc-warp"; do
  [[ -n "$cand" && -x "$cand" ]] && { RUNSC="$cand"; break; }
done
[[ -x "$RUNSC" ]] || { echo "no runsc-warp binary found; run build-runsc.sh first" >&2; exit 1; }

sudo install -m755 "$RUNSC" /usr/local/bin/runsc-warp

for spec in runsc-warp:1000 runsc-warp-hour:3600 runsc-warp-fast:86400 runsc-warp-temporal:30; do
  name="${spec%%:*}"; mult="${spec##*:}"
  sudo /usr/local/bin/runsc-warp install --runtime="$name" -- \
    --platform=systrap --timewarp-multiplier="$mult" --timewarp-delay="$TIMEWARP_DELAY"
done
sudo systemctl restart docker

echo "==> registered runtimes:"
docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' | tr ' ' '\n' | grep runsc-warp
