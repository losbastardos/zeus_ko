#!/usr/bin/env bash
set -euo pipefail

# Stiahne 4-piece pawnful Syzygy tabulky zo sesse.net zrkadla.
# Pouzitie: bash tb/download_4piece_pawnful.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BASE_URL="http://tablebase.sesse.net/syzygy/3-4-5"

VARIANTS=(
  KBPvK KBvPK KNPvK KNvPK KPPvK
  KPvBK KPvNK KPvPK KPvQK KPvRK
  KQPvK KQvPK KRPvK KRvPK
  KvBPK KvNPK KvPPK KvQPK KvRPK
)

mkdir -p "$SCRIPT_DIR"

for variant in "${VARIANTS[@]}"; do
  for ext in rtbw rtbz; do
    url="$BASE_URL/$variant.$ext"
    out="$SCRIPT_DIR/$variant.$ext"
    if [[ -f "$out" ]]; then
      echo "exists: $out"
      continue
    fi
    echo "downloading $variant.$ext ..."
    curl -fsSL "$url" -o "$out"
  done
done

echo "Done. Downloaded files:"
ls -lh "$SCRIPT_DIR"/*.rtbw "$SCRIPT_DIR"/*.rtbz 2>/dev/null | tail -n 40
