#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

export RTBPATH="$SCRIPT_DIR"
TBGEN="$ROOT_DIR/tb/syzygy-tb/src/rtbgen"

VARIANTS=(
  KRvKB
  KRvKN
  KBBvK
  KBNvK
)

for variant in "${VARIANTS[@]}"; do
  echo "generating $variant"
  "$TBGEN" "$variant"
done
