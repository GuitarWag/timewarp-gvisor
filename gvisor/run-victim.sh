#!/usr/bin/env bash
# Run the unmodified victim binary under (patched) runsc and watch its clock warp.
# Linux only. `runsc do` runs a single binary in a gVisor sandbox without Docker.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUNSC="${RUNSC:-$HERE/runsc-warp}"
RATE="${RATE:-1000}"
TIMER="${TIMER:-24h}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "runsc runs on Linux only — run this inside the Linux VM/container." >&2
  exit 1
fi
[[ -x "$RUNSC" ]] || { echo "no runsc at $RUNSC — run build-runsc.sh first" >&2; exit 1; }

echo "==> Building victim for this Linux host"
( cd "$ROOT/victim" && go build -o /tmp/victim . )

timer_secs=$(awk -v t="$TIMER" 'BEGIN{ n=t+0; u=t; gsub(/[0-9.]/,"",u);
  m=(u=="h")?3600:(u=="m")?60:(u=="s")?1:3600; print n*m }')
echo "==> Running victim under runsc at ${RATE}x (timer ${TIMER})"
echo "    With the patch, the timer should fire in ~$(awk "BEGIN{print $timer_secs/$RATE}")s instead of ${TIMER}."
# The multiplier MUST travel via the --timewarp-multiplier flag: runsc serializes
# it into the boot (sentry) process. Env vars and host files do NOT reach the
# sentry (clean env + restricted mount namespace).
# Live changes (roadmap): runsc timewarp <id> --rate N against a running sandbox.
# shellcheck disable=SC1010  # 'do' is the runsc subcommand, not a loop keyword
TIMER="$TIMER" \
  "$RUNSC" --timewarp-multiplier="$RATE" --platform=systrap --network=none do /tmp/victim
