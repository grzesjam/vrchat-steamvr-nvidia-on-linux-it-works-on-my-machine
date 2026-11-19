#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$1"
CLOCK_SCRIPT="$HERE/nvidia-clock.sh"
# exec preserves this PID, allowing watchdog to stop only this TUI on Ctrl+C.
printf '%s\n' "$$" > "$PID_FILE"
exec bash "$CLOCK_SCRIPT"
