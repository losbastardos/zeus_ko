#!/usr/bin/env bash
set -euo pipefail

# Generovanie 4-piece pawnful Syzygy tabuliek.
# Pouzitie:
#   TBGEN='...' bash tb/generate_4piece_pawnful.sh
# alebo:
#   bash tb/generate_4piece_pawnful.sh '...'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

GENERATOR_CMD="${1:-${TBGEN:-}}"
if [[ -z "$GENERATOR_CMD" ]]; then
  # default: pouzi nastroje z syzygy1/tb
  TBGEN_BASE="$ROOT_DIR/tb/syzygy-tb/src/rtbgen"
  TBGEN_P="$ROOT_DIR/tb/syzygy-tb/src/rtbgenp"
  GENERATOR_CMD='case "{canonical}" in *P*) '"$TBGEN_P"' {canonical} ;; *) '"$TBGEN_BASE"' {canonical} ;; esac'
fi

export RTBPATH="$SCRIPT_DIR"

mkdir -p "$SCRIPT_DIR"

python3 "$ROOT_DIR/utils/rtbz_variants.py" \
  --max-pieces 4 \
  --sided all \
  --show both \
  --manifest tb/variants_4piece_pawnful_manifest.json

python3 - <<'PY'
import json
from pathlib import Path

src = Path('tb/variants_4piece_pawnful_manifest.json')
dst = Path('tb/variants_4piece_pawnful_filtered_manifest.json')
data = json.loads(src.read_text(encoding='utf-8'))
# iba 4-piece varianty obsahujuce aspon jedneho pesiaca
only4 = [
    v for v in data
    if int(v.get('total_pieces', 0)) == 4 and 'P' in v.get('canonical', '')
]
dst.write_text(json.dumps(only4, indent=2, ensure_ascii=False), encoding='utf-8')
print(f"Filtered 4-piece pawnful variants: {len(only4)} -> {dst}")
PY

python3 "$ROOT_DIR/utils/rtbz_variants.py" \
  --variants tb/variants_4piece_pawnful_filtered_manifest.json \
  --show both \
  --generator "$GENERATOR_CMD" \
  --output-dir tb \
  --report tb/variants_4piece_pawnful_sizes.json

printf "\nHotovo. Vystupy:\n"
printf -- "- tb/variants_4piece_pawnful_manifest.json\n"
printf -- "- tb/variants_4piece_pawnful_filtered_manifest.json\n"
printf -- "- tb/variants_4piece_pawnful_sizes.json\n"
printf -- "- tb/*.rtbw / tb/*.rtbz (4-piece pawnful)\n"
