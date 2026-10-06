#!/usr/bin/env bash
set -euo pipefail

# Nočný retrain pipeline pre NNUE (cp labels):
# 1) PGN -> CSV (Lumbras OTB)
# 2) sampling na zvoleny pocet pozicii
# 3) eval_cp labeling cez Stockfish (d10-d12)
# 4) trening nnue_train2 v cp-target mode
# 5) build + kratky UCI smoke

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

DATE_TAG="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="tests/reports"
RAW_CSV="$REPORT_DIR/nnue_retrain_raw_${DATE_TAG}.csv"
SAMPLED_CSV="$REPORT_DIR/nnue_retrain_${DATE_TAG}_sampled.csv"
LABELED_CSV="$REPORT_DIR/nnue_retrain_${DATE_TAG}_cp.csv"
TRAIN_REPORT="$REPORT_DIR/nnue_train2_retrain_${DATE_TAG}.txt"
SMOKE_LOG="scratch/nnue_retrain_smoke_${DATE_TAG}.log"
SF_WRAPPER="scratch/stockfish_uci_wrapper_${DATE_TAG}.sh"

LUMBRAS_PGN="${LUMBRAS_PGN:-utils/LumbrasGigaBase_OTB_1990-1999.pgn}"
MAX_POSITIONS="${MAX_POSITIONS:-300000}"
LABEL_DEPTH="${LABEL_DEPTH:-12}"
HIDDEN="${HIDDEN:-128}"
EPOCHS="${EPOCHS:-60}"
BATCH="${BATCH:-4096}"
LR="${LR:-0.005}"
L2="${L2:-1e-5}"
CP_CLIP="${CP_CLIP:-2000}"
SEED="${SEED:-20261006}"
SOURCE_CSV="${SOURCE_CSV:-}"

mkdir -p "$REPORT_DIR" scratch

python_ok() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  "$bin" - <<'PY' >/dev/null 2>&1
import numpy
import chess
print("ok")
PY
}

if [[ -n "${PYTHON_BIN:-}" ]]; then
  if ! python_ok "$PYTHON_BIN"; then
    echo "error: PYTHON_BIN is set but cannot import numpy+python-chess: $PYTHON_BIN" >&2
    exit 2
  fi
else
  if python_ok "tests/tuning/.venv/bin/python3"; then
    PYTHON_BIN="tests/tuning/.venv/bin/python3"
  elif python_ok "$(command -v python3)"; then
    PYTHON_BIN="$(command -v python3)"
  else
    echo "error: no usable Python with numpy+python-chess found" >&2
    echo "hint: set PYTHON_BIN=/abs/path/python3 or install deps into tests/tuning/.venv" >&2
    exit 2
  fi
fi

if [[ ! -f "$LUMBRAS_PGN" ]]; then
  echo "error: Lumbras PGN not found: $LUMBRAS_PGN" >&2
  exit 2
fi

STOCKFISH_BIN="${STOCKFISH_BIN:-$(command -v stockfish || true)}"
if [[ -z "$STOCKFISH_BIN" || ! -x "$STOCKFISH_BIN" ]]; then
  echo "error: stockfish not found in PATH; set STOCKFISH_BIN=/abs/path/to/stockfish" >&2
  exit 2
fi

cat > "$SF_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--uci" ]]; then
  shift
fi
exec "$STOCKFISH_BIN" "\$@"
EOF
chmod +x "$SF_WRAPPER"

if [[ -n "$SOURCE_CSV" ]]; then
  if [[ ! -f "$SOURCE_CSV" ]]; then
    echo "error: SOURCE_CSV does not exist: $SOURCE_CSV" >&2
    exit 2
  fi
  echo "[1/5] Using prebuilt source CSV: $SOURCE_CSV"
  RAW_CSV="$SOURCE_CSV"
else
  echo "[1/5] PGN -> CSV: $LUMBRAS_PGN"
  "$PYTHON_BIN" tests/tuning/pgn2csv.py "$LUMBRAS_PGN" "$RAW_CSV" --skip-plies 10
fi

echo "[2/5] Sampling first $MAX_POSITIONS rows"
{ head -n 1 "$RAW_CSV"; tail -n +2 "$RAW_CSV" | shuf -n "$MAX_POSITIONS"; } > "$SAMPLED_CSV"

echo "[3/5] Labeling eval_cp with Stockfish depth $LABEL_DEPTH"
"$PYTHON_BIN" tests/tuning/texel_label_eval.py \
  --engine "$SF_WRAPPER" \
  --input "$SAMPLED_CSV" \
  --out "$LABELED_CSV" \
  --go "depth $LABEL_DEPTH"

echo "[4/5] Training net2.nnue (cp target)"
"$PYTHON_BIN" tests/tuning/nnue_train2.py \
  --dataset "$LABELED_CSV" \
  --out net2.nnue \
  --hidden "$HIDDEN" \
  --epochs "$EPOCHS" \
  --batch "$BATCH" \
  --lr "$LR" \
  --l2 "$L2" \
  --seed "$SEED" \
  --target cp \
  --cp-clip "$CP_CLIP" \
  --report "$TRAIN_REPORT"

echo "[5/5] Build + short UCI smoke"
make clean && make chess-static
printf "uci\nsetoption name EvalMode value 2\nsetoption name OwnBook value false\nisready\ngo depth 8\nquit\n" \
  | ./chess-static --uci | tee "$SMOKE_LOG" >/dev/null

echo

echo "DONE"
echo "raw_csv=$RAW_CSV"
echo "sampled_csv=$SAMPLED_CSV"
echo "labeled_csv=$LABELED_CSV"
echo "train_report=$TRAIN_REPORT"
echo "smoke_log=$SMOKE_LOG"
echo "net=net2.nnue"
