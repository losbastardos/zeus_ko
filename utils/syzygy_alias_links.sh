#!/usr/bin/env bash
set -euo pipefail

TB_DIR="${1:-tb}"

if [[ ! -d "$TB_DIR" ]]; then
  echo "tb dir not found: $TB_DIR" >&2
  exit 2
fi

count=0
for ext in rtbw rtbz; do
  shopt -s nullglob
  for src in "$TB_DIR"/K*vK."$ext"; do
    base="$(basename "$src")"
    name="${base%.${ext}}"
    if [[ "${#name}" -lt 3 ]]; then
      continue
    fi
    # KQvK -> QvK, KvQK -> vQK, KPPvKRK -> PPvKRK
    alias_name="${name#K}"
    if [[ -z "$alias_name" ]]; then
      continue
    fi
    dst="$TB_DIR/${alias_name}.${ext}"
    ln -sfn "$base" "$dst"
    count=$((count + 1))

    # Reverzny alias: KRvKB -> KBvKR, KBBvK -> KvKBB.
    if [[ "$name" =~ ^K([^v]*)vK(.*)$ ]]; then
      left="${BASH_REMATCH[1]}"
      right="${BASH_REMATCH[2]}"
      rev_name="K${right}vK${left}"
      if [[ "$rev_name" != "$name" ]]; then
        rev_dst="$TB_DIR/${rev_name}.${ext}"
        ln -sfn "$base" "$rev_dst"
        count=$((count + 1))

        rev_alias_name="${rev_name#K}"
        if [[ -n "$rev_alias_name" ]]; then
          rev_alias_dst="$TB_DIR/${rev_alias_name}.${ext}"
          ln -sfn "$base" "$rev_alias_dst"
          count=$((count + 1))
        fi
      fi
    fi
  done
  shopt -u nullglob
done

echo "syzygy alias links updated in $TB_DIR: $count"
