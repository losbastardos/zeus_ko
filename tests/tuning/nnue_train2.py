#!/usr/bin/env python3
"""NNUE trainer - phase 2: one-hidden-layer net (numpy).

Features (STM-relative, HalfKP-lite):
  non-king: (color_rel 0/1) x (type P,N,B,R,Q -> 5) x (rel_sq 64) = 640
  kings:    (color_rel 0/1) x (rel_sq 64)                      = 128
  total F = 768

Net: eval_cp = W2 . CReLU(W1^T x + b1) + b2
  CReLU(z) = clip(z, 0, 255) - quantization-friendly ReLU
Training: logistic on game result, eval_cp/scale as logit; L2.
Export net.nnue v2:
  magic "NNUE" u32, version u32 = 2
  H u32, shift1 u32 (log2 of W1 output scale), shift2 u32
  b1: H x int32 ; W1: F x H int16 (row-major: feature-major)
  b2: int32 ; W2: H x int16
Inference (asm mirrors this):
  acc[j] = sum_i x[i]*W1[i][j] + b1[j]      (int32)
  h[j]   = clip(acc[j] >> shift1, 0, 255)
  eval   = (sum_j h[j]*W2[j] + b2) >> shift2 (cp)

Usage:
  python3 tests/tuning/nnue_train2.py --dataset tests/reports/texel_dataset.csv \
      [--dataset tests/reports/selfplay.csv ...] --out net2.nnue --epochs 60
"""

from __future__ import annotations

import argparse
import csv
import math
import struct
import sys

import numpy as np

try:
    import chess
except Exception as exc:  # pragma: no cover
    print(f"error: python-chess required ({exc})", file=sys.stderr)
    raise SystemExit(2)

PIECES = [chess.PAWN, chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN]
F_NONKING = 2 * 5 * 64          # 640
F_KING = 2 * 64                 # 128
F = F_NONKING + F_KING          # 768
MAGIC = b"NNUE"
VERSION = 2
PHASE_W = {chess.PAWN: 0, chess.KNIGHT: 1, chess.BISHOP: 1,
           chess.ROOK: 2, chess.QUEEN: 4, chess.KING: 0}
PHASE_MAX = 24


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="NNUE phase-2 trainer (1 hidden layer)")
    p.add_argument("--dataset", action="append", default=[],
                   help="Texel CSV (can repeat); default texel_dataset.csv")
    p.add_argument("--out", default="net2.nnue")
    p.add_argument("--hidden", type=int, default=96)
    p.add_argument("--epochs", type=int, default=60)
    p.add_argument("--lr", type=float, default=0.005)
    p.add_argument("--l2", type=float, default=1e-5)
    p.add_argument("--scale", type=float, default=233.0)
    p.add_argument("--batch", type=int, default=4096)
    p.add_argument("--seed", type=int, default=20260917)
    p.add_argument("--report", default="tests/reports/nnue_train2.txt")
    p.add_argument("--max-positions", type=int, default=0)
    return p.parse_args()


def build_features(board: chess.Board) -> np.ndarray:
    x = np.zeros(F, dtype=np.float32)
    stm_white = board.turn == chess.WHITE
    for sq in chess.SQUARES:
        pc = board.piece_at(sq)
        if pc is None:
            continue
        rsq = sq if stm_white else (sq ^ 56)
        own = 0 if pc.color == board.turn else 1
        if pc.piece_type == chess.KING:
            x[F_NONKING + own * 64 + rsq] = 1.0
        else:
            pt = PIECES.index(pc.piece_type)
            x[(own * 5 + pt) * 64 + rsq] = 1.0
    return x


def load_rows(paths, max_pos: int):
    rows = []
    for path in paths:
        with open(path, "r", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                try:
                    rows.append((r["fen"], float(r["result"])))
                except Exception:
                    continue
    if max_pos and len(rows) > max_pos:
        rows = rows[:max_pos]
    return rows


def main() -> int:
    args = parse_args()
    if not args.dataset:
        args.dataset = ["tests/reports/texel_dataset.csv"]
    rng = np.random.default_rng(args.seed)
    H = args.hidden

    rows = load_rows(args.dataset, args.max_positions)
    n = len(rows)
    print(f"dataset: {n} positions (H={H})", flush=True)

    X = np.empty((n, F), dtype=np.float32)
    y = np.empty(n, dtype=np.float32)
    for i, (fen, res) in enumerate(rows):
        X[i] = build_features(chess.Board(fen))
        y[i] = res

    # inicializacia: male nahodne vahy
    W1 = rng.normal(0.0, 0.01, size=(F, H)).astype(np.float32)
    b1 = np.zeros(H, dtype=np.float32)
    W2 = rng.normal(0.0, 0.01, size=H).astype(np.float32)
    b2 = np.float32(0.0)
    scale = np.float32(args.scale)

    bs = args.batch
    # Adam state
    mw1 = np.zeros_like(W1); vw1 = np.zeros_like(W1)
    mb1 = np.zeros_like(b1); vb1 = np.zeros_like(b1)
    mw2 = np.zeros_like(W2); vw2 = np.zeros_like(W2)
    mb2 = np.float32(0.0); vb2 = np.float32(0.0)
    b1m, b2m = 0.9, 0.999
    eps = 1e-8
    step = 0
    for epoch in range(args.epochs):
        order = rng.permutation(n)
        ll = 0.0
        for s in range(0, n, bs):
            idx = order[s:s + bs]
            xb = X[idx]
            yb = y[idx]
            m = xb.shape[0]
            step += 1
            # forward
            z1 = xb @ W1 + b1                    # (m,H)
            h = np.clip(z1, 0.0, 255.0)          # inference clip [0,255]
            ev = h @ W2 + b2                     # (m,)
            z = np.clip(ev / scale, -40, 40)
            p = 1.0 / (1.0 + np.exp(-z))
            p = np.clip(p, 1e-12, 1 - 1e-12)
            ll += float(-(yb * np.log(p) + (1 - yb) * np.log(1 - p)).sum())
            # backward
            d = (p - yb) / scale                 # (m,)
            dW2 = h.T @ d / m + args.l2 * W2
            db2 = float(d.sum() / m)
            dh = np.outer(d, W2)                 # (m,H)
            dz1 = dh * (z1 > 0)                  # relu'
            dW1 = xb.T @ dz1 / m + args.l2 * W1
            db1 = dz1.sum(axis=0) / m
            # Adam updates
            mw1 = b1m * mw1 + (1 - b1m) * dW1
            vw1 = b2m * vw1 + (1 - b2m) * dW1 * dW1
            W1 -= args.lr * (mw1 / (1 - b1m ** step)) / (np.sqrt(vw1 / (1 - b2m ** step)) + eps)
            mb1 = b1m * mb1 + (1 - b1m) * db1
            vb1 = b2m * vb1 + (1 - b2m) * db1 * db1
            b1 -= args.lr * (mb1 / (1 - b1m ** step)) / (np.sqrt(vb1 / (1 - b2m ** step)) + eps)
            mw2 = b1m * mw2 + (1 - b1m) * dW2
            vw2 = b2m * vw2 + (1 - b2m) * dW2 * dW2
            W2 -= args.lr * (mw2 / (1 - b1m ** step)) / (np.sqrt(vw2 / (1 - b2m ** step)) + eps)
            mb2 = b1m * mb2 + (1 - b1m) * db2
            vb2 = b2m * vb2 + (1 - b2m) * db2 * db2
            b2 -= args.lr * (mb2 / (1 - b1m ** step)) / (math.sqrt(vb2 / (1 - b2m ** step)) + eps)
        ll /= n
        if epoch == 0 or (epoch + 1) % 5 == 0:
            print(f"epoch {epoch+1}: logloss={ll:.5f}", flush=True)

    # quantization: Q=128 na vahy, biasy x2048, posuvy 11 (symetricke)
    # asm inference: acc = sum x*W1q + b1q ; h = clip(acc>>11, 0, 255)
    #                eval_cp = (sum h*W2q + b2q) >> 11
    W1q = np.clip(np.round(W1 * 128.0), -32768, 32767).astype(np.int16)
    b1q = np.round(b1 * 2048.0).astype(np.int32)
    W2q = np.clip(np.round(W2 * 128.0), -32768, 32767).astype(np.int16)
    b2q = np.round(b2 * 2048.0).astype(np.int32)
    shift1 = 11
    shift2 = 11

    with open(args.out, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<I", VERSION))
        f.write(struct.pack("<I", H))
        f.write(struct.pack("<I", shift1))
        f.write(struct.pack("<I", shift2))
        f.write(b1q.tobytes())
        f.write(W1q.tobytes())
        f.write(b2q.tobytes())
        f.write(W2q.tobytes())
    size = 20 + b1q.nbytes + W1q.nbytes + 4 + W2q.nbytes
    print(f"written: {args.out} ({size} bytes)")

    with open(args.report, "w", encoding="utf-8") as f:
        f.write(f"nnue_train2 H={H}\npositions={n}\nepochs={args.epochs}\n")
        f.write(f"final_logloss={ll:.6f}\n")
    print(f"report: {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
