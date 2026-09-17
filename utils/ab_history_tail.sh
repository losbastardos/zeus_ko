#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

HISTORY_FILE="${1:-tests/reports/ab_history.tsv}"
LIMIT="${2:-10}"

if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "ERROR: history file not found: $HISTORY_FILE"
    exit 2
fi

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: limit must be numeric"
    exit 3
fi

echo "A/B history tail (${LIMIT})"
echo "file: $HISTORY_FILE"

head -n 1 "$HISTORY_FILE"
tail -n +2 "$HISTORY_FILE" | tail -n "$LIMIT"
