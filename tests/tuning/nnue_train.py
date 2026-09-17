#!/usr/bin/env python3
"""NNUE trainer - phase 1: linear piece-square net (learned PST).

Model: eval = sum(piece-square weights, own+enemy, STM-relative square)
tapered MG/EG, logistic mapping to game result. Gradient descent + L2.
Pure python (no numpy) - sparse features keep it fast enough.

Export binary consumed by src/nnue.asm:
  magic "NNUE" u32, version u32 (=1),
  per phase (MG, EG), per piece (PAWN..KING): own[64] int16, enemy[64] int16.
Engine lookup: color_rel = (piece.color == stm) ? own : enemy block;
rel_sq = stm_white ? sq : sq ^ 56.
"""

from __future__ import annotations

import argparse
import csv
import math
import struct
import sys

try:
    import chess
except Exception as exc:  # pragma: no cover
    print(f"error: python-chess required ({exc})", file=sys.stderr)
    raise SystemExit(2)

PIECES = [chess.PAWN, chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN, chess.KING]
N_PIECE = 6
N_SQ = 64
N_W = N_PIECE * N_SQ * 2          # per phase (own+enemy)
PHASE_W = {chess.PAWN: 0, chess.KNIGHT: 1, chess.BISHOP: 1,
           chess.ROOK: 2, chess.QUEEN: 4, chess.KING: 0}
PHASE_MAX = 24
MAGIC = b"NNUE"
VERSION = 1


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Linear NNUE (learned PST) trainer")
    p.add_argument("--dataset", default="tests/reports/texel_dataset.csv")
    p.add_argument("--out", default="net.nnue")
    p.add_argument("--epochs", type=int, default=8)
    p.add_argument("--lr", type=float, default=0.02)
    p.add_argument("--l2", type=float, default=1e-4)
    p.add_argument("--scale", type=float, default=233.0)
    p.add_argument("--report", default="tests/reports/nnue_train.txt")
    p.add_argument("--max-positions", type=int, default=0)
    p.add_argument("--seed", type=int, default=20260917)
    return p.parse_args()


def main() -> int:
    args = parse_args()

    rows = []
    with open(args.dataset, "r", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                rows.append((r["fen"], float(r["result"])))
            except Exception:
                continue
    if args.max_positions and len(rows) > args.max_positions:
        rows = rows[: args.max_positions]
    n = len(rows)
    print(f"dataset: {n} positions", flush=True)

    # precompute sparse features + phase
    feats = []
    ys = []
    for fen, res in rows:
        b = chess.Board(fen)
        stm_white = b.turn == chess.WHITE
        idx = []
        phase = 0
        for sq in chess.SQUARES:
            pc = b.piece_at(sq)
            if pc is None:
                continue
            pt = PIECES.index(pc.piece_type)
            rsq = sq if stm_white else (sq ^ 56)
            own = 0 if pc.color == b.turn else 1
            idx.append((own * N_PIECE + pt) * N_SQ + rsq)
            phase += PHASE_W[pc.piece_type]
        if phase > PHASE_MAX:
            phase = PHASE_MAX
        feats.append((idx, phase / PHASE_MAX))
        ys.append(res)

    w_mg = [0.0] * N_W
    w_eg = [0.0] * N_W
    scale = args.scale

    # per-sample SGD; gradient v cp-jednotkach (d = p-y bez delenia scale)
    import random
    rng = random.Random(args.seed)
    order = list(range(n))
    for epoch in range(args.epochs):
        rng.shuffle(order)
        lr = args.lr / (1.0 + epoch * 0.25)
        ll = 0.0
        for i in order:
            idx, ph = feats[i]
            y = ys[i]
            ev_mg = 0.0
            ev_eg = 0.0
            for j in idx:
                ev_mg += w_mg[j]
                ev_eg += w_eg[j]
            ev = ev_mg * (1.0 - ph) + ev_eg * ph
            x = ev / scale
            if x > 40.0:
                x = 40.0
            elif x < -40.0:
                x = -40.0
            p = 1.0 / (1.0 + math.exp(-x))
            if p < 1e-12:
                p = 1e-12
            elif p > 1.0 - 1e-12:
                p = 1.0 - 1e-12
            ll += -(y * math.log(p) + (1.0 - y) * math.log(1.0 - p))
            d = p - y
            dm = lr * d * (1.0 - ph)
            de = lr * d * ph
            for j in idx:
                w_mg[j] -= dm
                w_eg[j] -= de
        # L2 decay (per epoch)
        for j in range(N_W):
            w_mg[j] -= args.l2 * w_mg[j]
            w_eg[j] -= args.l2 * w_eg[j]
        ll /= n
        if epoch == 0 or (epoch + 1) % 2 == 0:
            am = sum(abs(v) for v in w_mg) / N_W
            print(f"epoch {epoch+1}: logloss={ll:.5f} lr={lr:.4f} |w_mg|~{am:.2f}", flush=True)

    def clip16(v: float) -> int:
        iv = int(round(v))
        return -32768 if iv < -32768 else (32767 if iv > 32767 else iv)

    out = bytearray()
    out += MAGIC
    out += struct.pack("<I", VERSION)
    for w in (w_mg, w_eg):
        for own in range(2):
            for pt in range(N_PIECE):
                base = (own * N_PIECE + pt) * N_SQ
                for sq in range(N_SQ):
                    out += struct.pack("<h", clip16(w[base + sq]))
    with open(args.out, "wb") as f:
        f.write(bytes(out))
    print(f"written: {args.out} ({len(out)} bytes)")

    with open(args.report, "w", encoding="utf-8") as f:
        f.write(f"nnue_train linear PST\npositions={n}\nepochs={args.epochs}\n")
        f.write(f"final_logloss={ll:.6f}\nlr={args.lr} l2={args.l2} scale={scale}\n")
    print(f"report: {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
