#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

CANDIDATE_PATH="${1:-}"
BASELINE_PATH="${2:-./chess-static}"

if [[ -z "$CANDIDATE_PATH" ]]; then
    echo "Usage: $0 <candidate_engine> [baseline_engine]"
    exit 2
fi

if [[ ! -x "$CANDIDATE_PATH" ]]; then
    echo "ERROR: candidate not executable: $CANDIDATE_PATH"
    exit 3
fi

if [[ ! -x "$BASELINE_PATH" ]]; then
    echo "ERROR: baseline not executable: $BASELINE_PATH"
    exit 4
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_head="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
        default_tag="${git_head}-dirty"
    else
        default_tag="$git_head"
    fi
else
    default_tag="manual"
fi

RUN_TAG="${RUN_TAG:-$default_tag}"
OPENINGS_FILE="${OPENINGS_FILE:-utils/LumbrasGigaBase_OTB_0001-1899.pgn}"
OPENINGS_FORMAT="${OPENINGS_FORMAT:-pgn}"
OPENINGS_ORDER="${OPENINGS_ORDER:-sequential}"
OPENINGS_PLIES="${OPENINGS_PLIES:-8}"
SRAND="${SRAND:-20260916}"
GAMES="${GAMES:-200}"
CONCURRENCY="${CONCURRENCY:-2}"
TC="${TC:-10+0.1}"
HASH_MB="${HASH_MB:-64}"
SPRT="${SPRT:-elo0=0 elo1=8 alpha=0.05 beta=0.05}"
EXECUTE="${EXECUTE:-0}"
PGNOUT="${PGNOUT:-tests/reports/sprt_${RUN_TAG}.pgn}"

if [[ ! -f "$OPENINGS_FILE" ]]; then
    echo "ERROR: openings file not found: $OPENINGS_FILE"
    exit 5
fi

mkdir -p "$(dirname "$PGNOUT")"

# Python interpreter: local venv preferred (relative path), override via SPRT_PYTHON
PYTHON_BIN="${SPRT_PYTHON:-python3}"
if [[ -x "utils/.venv/bin/python" ]]; then
    PYTHON_BIN="utils/.venv/bin/python"
fi

cmd=(
    "$PYTHON_BIN"
    utils/sprt_match.py
    --new "$CANDIDATE_PATH"
    --base "$BASELINE_PATH"
    --openings "$OPENINGS_FILE"
    --openings-format "$OPENINGS_FORMAT"
    --openings-order "$OPENINGS_ORDER"
    --openings-plies "$OPENINGS_PLIES"
    --srand "$SRAND"
    --games "$GAMES"
    --concurrency "$CONCURRENCY"
    --tc "$TC"
    --hash-mb "$HASH_MB"
    --sprt "$SPRT"
    --pgnout "$PGNOUT"
)

echo "SPRT A/B"
echo "- run tag: $RUN_TAG"
echo "- candidate: $CANDIDATE_PATH"
echo "- baseline:  $BASELINE_PATH"
echo "- openings:  $OPENINGS_FILE"
echo "- seed:      $SRAND"
echo "- games/tc:  $GAMES / $TC"
echo "- pgn out:   $PGNOUT"

if (( EXECUTE == 1 )); then
    "${cmd[@]}"
else
    "${cmd[@]}" --dry-run
fi
