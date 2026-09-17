#!/usr/bin/env python3
"""Estimate pawn-hash cache reuse potential from FEN/EPD/CSV inputs."""

from __future__ import annotations

import argparse
import csv
import os
from collections import Counter
from typing import Iterable, Optional, Tuple

FILES = "abcdefgh"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Pawn-hash feasibility study")
    p.add_argument("--input", required=True, help="input file: .epd/.fenbm/.txt/.csv")
    p.add_argument("--report", default="tests/reports/pawn_hash_feasibility.txt", help="output report")
    p.add_argument("--top", type=int, default=10, help="show top repeated signatures")
    p.add_argument(
        "--signature",
        choices=["exact", "files"],
        default="exact",
        help="signature mode: exact squares or per-file pawn counts",
    )
    return p.parse_args()


def fen_from_line(line: str) -> Optional[str]:
    s = line.strip()
    if not s or s.startswith("#"):
        return None

    parts = s.split()
    if len(parts) < 4:
        return None

    if "/" not in parts[0]:
        return None

    # EPD/FENBM often starts with 4-field FEN and then ops (bm/am ...)
    if len(parts) >= 6 and parts[4].isdigit() and parts[5].isdigit():
        return " ".join(parts[:6])
    return " ".join(parts[:4])


def iter_fens(path: str) -> Iterable[str]:
    lower = path.lower()
    if lower.endswith(".csv"):
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames and "fen" in reader.fieldnames:
                for row in reader:
                    fen = (row.get("fen") or "").strip()
                    if fen:
                        yield fen
                return

        with open(path, newline="", encoding="utf-8") as f:
            reader2 = csv.reader(f)
            for row in reader2:
                if not row:
                    continue
                fen = row[0].strip()
                if "/" in fen:
                    yield fen
        return

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            fen = fen_from_line(line)
            if fen:
                yield fen


def pawn_signature(fen: str) -> Tuple[Tuple[int, ...], Tuple[int, ...]]:
    board = fen.split()[0]
    white = []
    black = []

    rank = 7
    file_idx = 0
    for ch in board:
        if ch == "/":
            rank -= 1
            file_idx = 0
            continue
        if ch.isdigit():
            file_idx += int(ch)
            continue

        sq = rank * 8 + file_idx
        if ch == "P":
            white.append(sq)
        elif ch == "p":
            black.append(sq)
        file_idx += 1

    return (tuple(sorted(white)), tuple(sorted(black)))


def pawn_signature_files(fen: str) -> Tuple[Tuple[int, ...], Tuple[int, ...]]:
    board = fen.split()[0]
    white = [0] * 8
    black = [0] * 8

    file_idx = 0
    for ch in board:
        if ch == "/":
            file_idx = 0
            continue
        if ch.isdigit():
            file_idx += int(ch)
            continue

        if ch == "P":
            white[file_idx] += 1
        elif ch == "p":
            black[file_idx] += 1
        file_idx += 1

    return (tuple(white), tuple(black))


def main() -> int:
    args = parse_args()

    signature_fn = pawn_signature if args.signature == "exact" else pawn_signature_files

    sig_counter: Counter[Tuple[Tuple[int, ...], Tuple[int, ...]]] = Counter()
    total = 0
    for fen in iter_fens(args.input):
        sig_counter[signature_fn(fen)] += 1
        total += 1

    if total == 0:
        print("error: no FEN positions parsed")
        return 2

    unique = len(sig_counter)
    repeated = total - unique
    reuse_ratio = repeated / total

    os.makedirs(os.path.dirname(args.report) or ".", exist_ok=True)
    with open(args.report, "w", encoding="utf-8") as out:
        out.write("pawn hash feasibility\n")
        out.write(f"input={args.input}\n")
        out.write(f"signature={args.signature}\n")
        out.write(f"positions={total}\n")
        out.write(f"unique_signatures={unique}\n")
        out.write(f"repeated_positions={repeated}\n")
        out.write(f"reuse_ratio={reuse_ratio:.4f}\n\n")

        out.write("top_signatures\n")
        for idx, (sig, cnt) in enumerate(sig_counter.most_common(args.top), start=1):
            ww = ",".join(str(x) for x in sig[0])
            bb = ",".join(str(x) for x in sig[1])
            out.write(f"{idx}. count={cnt} white=[{ww}] black=[{bb}]\n")

    print(f"positions={total} unique={unique} reuse_ratio={reuse_ratio:.4f}")
    print(f"report: {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
