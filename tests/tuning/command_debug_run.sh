#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: command_debug_run.sh '<command>'" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    cmd="$1"
else
    cmd="$(printf '%q ' "$@")"
fi
enabled="${COMMANDS_DEBUG:-0}"
log_file="${COMMANDS_DEBUG_LOG:-commands_debug.log}"

case "${enabled,,}" in
    1|true|yes|on)
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        printf '[%s] cwd=%s cmd=%s\n' "$ts" "$PWD" "$cmd" >> "$log_file"
        ;;
esac

# Run exactly what make target requested.
if [[ $# -eq 1 ]]; then
    eval "$cmd"
else
    "$@"
fi
