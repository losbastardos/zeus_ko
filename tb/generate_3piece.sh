#!/usr/bin/env bash
set -euo pipefail

# Pouzitie:
#   TBGEN='tbgen --variant {canonical} --out {output}' bash tb/generate_3piece.sh
# alebo:
#   bash tb/generate_3piece.sh 'tbgen --variant {canonical} --out {output}'

GENERATOR_CMD="${1:-${TBGEN:-}}"
if [[ -z "$GENERATOR_CMD" ]]; then
  echo "Chyba: chýba generator command."
  echo "Priklad:"
  echo "  TBGEN='tbgen --variant {canonical} --out {output}' bash tb/generate_3piece.sh"
  exit 2
fi

mkdir -p tb
python3 utils/rtbz_variants.py \
  --max-pieces 3 \
  --sided all \
  --show both \
  --manifest tb/variants_3piece_all_manifest.json

python3 - <<'PY'
import json
from pathlib import Path

src = Path('tb/variants_3piece_all_manifest.json')
dst = Path('tb/variants_3piece_manifest.json')
data = json.loads(src.read_text(encoding='utf-8'))
only3 = [v for v in data if int(v.get('total_pieces', 0)) == 3]
dst.write_text(json.dumps(only3, indent=2, ensure_ascii=False), encoding='utf-8')
print(f"Filtered 3-piece variants: {len(only3)} -> {dst}")
PY

python3 utils/rtbz_variants.py \
  --variants tb/variants_3piece_manifest.json \
  --show both \
  --generator "$GENERATOR_CMD" \
  --output-dir tb \
  --report tb/variants_3piece_sizes.json

printf "\nHotovo. Výstupy:\n"
printf -- "- tb/variants_3piece_all_manifest.json\n"
printf -- "- tb/variants_3piece_manifest.json\n"
printf -- "- tb/variants_3piece_sizes.json\n"
printf -- "- tb/*.rtbz\n"
