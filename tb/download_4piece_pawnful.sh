#!/usr/bin/env bash
set -euo pipefail

# Stiahne 4-piece pawnful Syzygy tabulky zo sesse.net zrkadla.
# Automaticky vytvara aj reverzne aliasy cez utils/syzygy_alias_links.sh.
# Pouzitie: bash tb/download_4piece_pawnful.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

BASE_URL="http://tablebase.sesse.net/syzygy/3-4-5"

# Kanonicke 4-piece pawnful varianty (silnejsia strana prva).
# Reverzne orientacie (napr. KBvPK) sa vytvoria ako symlinky.
VARIANTS=(
  KBPvK  KBvKP
  KNPvK  KNvKP
  KPPvK  KPvKP
  KQPvK  KQvKP
  KRPvK  KRvKP
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

# vytvor reverzne aliasy
bash "$ROOT_DIR/utils/syzygy_alias_links.sh" "$SCRIPT_DIR"

echo "Done. 4-piece pawnful files:"
ls -lh "$SCRIPT_DIR"/*P*.{rtbw,rtbz} 2>/dev/null | wc -l
echo "files with P in name"
