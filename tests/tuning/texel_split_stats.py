#!/usr/bin/env python3
"""Split Texel CSV dataset and compute basic statistics.

Input CSV columns expected:
- fen
- result (1.0, 0.5, 0.0)
- ply
- game_index
- source

Outputs:
- train CSV
- validation CSV
- stats text report
"""

from __future__ import annotations

import argparse
import csv
import os
import random
from collections import Counter
from statistics import mean


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Split Texel dataset and write stats")
    parser.add_argument("--input", required=True, help="input CSV from texel_prepare.py")
    parser.add_argument("--train-out", required=True, help="output train CSV")
    parser.add_argument("--valid-out", required=True, help="output validation CSV")
    parser.add_argument("--stats-out", required=True, help="output stats text file")
    parser.add_argument("--train-ratio", type=float, default=0.9, help="train split ratio (0..1)")
    parser.add_argument("--seed", type=int, default=20260916, help="shuffle seed")
    parser.add_argument("--ply-bucket", type=int, default=10, help="bucket size for ply histogram")
    return parser.parse_args()


def ensure_parent(path: str) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)


def read_rows(path: str):
    with open(path, "r", encoding="utf-8", newline="") as f:
        rd = csv.DictReader(f)
        rows = list(rd)
        fields = rd.fieldnames or []
    return rows, fields


def write_rows(path: str, fields, rows) -> None:
    ensure_parent(path)
    with open(path, "w", encoding="utf-8", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=fields)
        wr.writeheader()
        wr.writerows(rows)


def parse_float(value: str, default: float) -> float:
    try:
        return float(value)
    except Exception:
        return default


def parse_int(value: str, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default


def result_key(value: str) -> str:
    if value == "1.0":
        return "white_win"
    if value == "0.5":
        return "draw"
    if value == "0.0":
        return "black_win"
    return "other"


def build_stats(rows, ply_bucket: int):
    result_counts = Counter()
    source_counts = Counter()
    ply_values = []
    ply_hist = Counter()

    for r in rows:
        res = r.get("result", "")
        result_counts[result_key(res)] += 1
        src = r.get("source", "")
        source_counts[src] += 1

        ply = parse_int(r.get("ply", "0"), 0)
        ply_values.append(ply)
        b = (ply // ply_bucket) * ply_bucket
        ply_hist[f"{b:03d}-{b + ply_bucket - 1:03d}"] += 1

    n = len(rows)
    if n == 0:
        return {
            "count": 0,
            "results": result_counts,
            "sources": source_counts,
            "ply_min": 0,
            "ply_max": 0,
            "ply_avg": 0.0,
            "ply_hist": ply_hist,
        }

    return {
        "count": n,
        "results": result_counts,
        "sources": source_counts,
        "ply_min": min(ply_values),
        "ply_max": max(ply_values),
        "ply_avg": mean(ply_values),
        "ply_hist": ply_hist,
    }


def pct(part: int, total: int) -> float:
    if total <= 0:
        return 0.0
    return 100.0 * part / total


def write_stats(path: str, all_stats, train_stats, valid_stats, args: argparse.Namespace) -> None:
    ensure_parent(path)
    with open(path, "w", encoding="utf-8") as f:
        f.write("texel split stats\n")
        f.write(f"input={args.input}\n")
        f.write(f"train_out={args.train_out}\n")
        f.write(f"valid_out={args.valid_out}\n")
        f.write(f"train_ratio={args.train_ratio:.4f}\n")
        f.write(f"seed={args.seed}\n")
        f.write(f"ply_bucket={args.ply_bucket}\n")
        f.write("\n")

        for title, st in (("all", all_stats), ("train", train_stats), ("valid", valid_stats)):
            f.write(f"[{title}]\n")
            f.write(f"count={st['count']}\n")
            ww = st["results"].get("white_win", 0)
            dr = st["results"].get("draw", 0)
            bw = st["results"].get("black_win", 0)
            ot = st["results"].get("other", 0)
            f.write(f"result_white_win={ww} ({pct(ww, st['count']):.2f}%)\n")
            f.write(f"result_draw={dr} ({pct(dr, st['count']):.2f}%)\n")
            f.write(f"result_black_win={bw} ({pct(bw, st['count']):.2f}%)\n")
            f.write(f"result_other={ot} ({pct(ot, st['count']):.2f}%)\n")
            f.write(f"ply_min={st['ply_min']}\n")
            f.write(f"ply_max={st['ply_max']}\n")
            f.write(f"ply_avg={st['ply_avg']:.2f}\n")

            f.write("sources:\n")
            for src, cnt in sorted(st["sources"].items(), key=lambda x: (-x[1], x[0])):
                f.write(f"  {src}: {cnt}\n")

            f.write("ply_hist:\n")
            for bucket, cnt in sorted(st["ply_hist"].items()):
                f.write(f"  {bucket}: {cnt}\n")
            f.write("\n")


def main() -> int:
    args = parse_args()

    if not os.path.exists(args.input):
        print(f"error: input not found: {args.input}")
        return 2

    ratio = parse_float(str(args.train_ratio), 0.9)
    if ratio <= 0.0 or ratio >= 1.0:
        print("error: train-ratio must be between 0 and 1")
        return 3

    rows, fields = read_rows(args.input)
    if not rows:
        print("error: input dataset is empty")
        return 4

    needed = {"fen", "result", "ply", "game_index", "source"}
    if not needed.issubset(set(fields)):
        print("error: input CSV missing required columns")
        return 5

    rng = random.Random(args.seed)
    rng.shuffle(rows)

    split_idx = int(len(rows) * ratio)
    if split_idx <= 0 or split_idx >= len(rows):
        print("error: split produced empty train or valid set")
        return 6

    train_rows = rows[:split_idx]
    valid_rows = rows[split_idx:]

    write_rows(args.train_out, fields, train_rows)
    write_rows(args.valid_out, fields, valid_rows)

    all_stats = build_stats(rows, max(1, args.ply_bucket))
    train_stats = build_stats(train_rows, max(1, args.ply_bucket))
    valid_stats = build_stats(valid_rows, max(1, args.ply_bucket))

    write_stats(args.stats_out, all_stats, train_stats, valid_stats, args)

    print("texel split complete")
    print(f"- input rows: {len(rows)}")
    print(f"- train rows: {len(train_rows)}")
    print(f"- valid rows: {len(valid_rows)}")
    print(f"- train out: {args.train_out}")
    print(f"- valid out: {args.valid_out}")
    print(f"- stats out: {args.stats_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
