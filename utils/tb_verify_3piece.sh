#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TB_DIR="${1:-$ROOT_DIR/tb}"
VERIFIER="${2:-$TB_DIR/syzygy-tb/src/rtbver_local}"
PAWN_VERIFIER="${3:-$TB_DIR/syzygy-tb/src/rtbverp_local}"
TIMEOUT_SEC="${TB_VERIFY_TIMEOUT:-60}"

if [[ "$TB_DIR" != /* ]]; then
  TB_DIR="$ROOT_DIR/$TB_DIR"
fi
if [[ "$VERIFIER" != /* ]]; then
  VERIFIER="$ROOT_DIR/$VERIFIER"
fi
if [[ "$PAWN_VERIFIER" != /* ]]; then
  PAWN_VERIFIER="$ROOT_DIR/$PAWN_VERIFIER"
fi

if [[ ! -d "$TB_DIR" ]]; then
  echo "tb dir not found: $TB_DIR" >&2
  exit 2
fi
if [[ ! -x "$VERIFIER" ]]; then
  echo "verifier not found or not executable: $VERIFIER" >&2
  exit 2
fi
if [[ ! -x "$PAWN_VERIFIER" ]]; then
  echo "pawn verifier not found or not executable: $PAWN_VERIFIER" >&2
  exit 2
fi

variants=(
  KQvK
  KRvK
  KBvK
  KNvK
  KPvK
  KvQK
  KvRK
  KvBK
  KvNK
  KvPK
)

passes=0
fails=0

pushd "$TB_DIR" >/dev/null
for v in "${variants[@]}"; do
  runner="$VERIFIER"
  if [[ "$v" == *P* ]]; then
    runner="$PAWN_VERIFIER"
  fi
  echo "verify $v"
  if timeout "$TIMEOUT_SEC" "$runner" "$v" >/tmp/tb_verify_3piece.log 2>&1; then
    if rg -q "No errors\." /tmp/tb_verify_3piece.log; then
      echo "PASS $v"
      passes=$((passes + 1))
    else
      echo "FAIL $v (missing 'No errors.')"
      tail -n 20 /tmp/tb_verify_3piece.log || true
      fails=$((fails + 1))
    fi
  else
    echo "FAIL $v (command error/timeout)"
    tail -n 20 /tmp/tb_verify_3piece.log || true
    fails=$((fails + 1))
  fi
  echo
 done
popd >/dev/null

rm -f /tmp/tb_verify_3piece.log

echo "summary: pass=$passes fail=$fails"
[[ $fails -eq 0 ]]
