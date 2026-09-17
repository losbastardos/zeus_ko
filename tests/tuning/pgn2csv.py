#!/usr/bin/env python3
"""PGN -> Texel CSV converter (robust, python-chess based).

texel_prepare.py chokes on Stockfish PGN comments ({+0.22/12 0.1s});
this parser handles any standard PGN.

Usage:
  python3 tests/tuning/pgn2csv.py in.pgn out.csv [--skip-plies N]
"""

from __future__ import annotations

import argparse
import csv
import sys

import chess.pgn


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("pgn")
    p.add_argument("out")
    p.add_argument("--skip-plies", type=int, default=10)
    args = p.parse_args()

    out = open(args.out, "w", newline="")
    w = csv.writer(out)
    w.writerow(["fen", "result", "ply", "game_index", "source"])
    n = 0
    g = 0
    with open(args.pgn, encoding="utf-8", errors="replace") as f:
        while True:
            game = chess.pgn.read_game(f)
            if game is None:
                break
            g += 1
            res = game.headers.get("Result", "*")
            if res == "1-0":
                r = 1.0
            elif res == "0-1":
                r = 0.0
            elif res == "1/2-1/2":
                r = 0.5
            else:
                continue
            board = game.board()
            for ply, move in enumerate(game.mainline_moves()):
                if ply >= args.skip_plies:
                    w.writerow([board.fen(), f"{r:.1f}", ply, g, "pgn2csv"])
                    n += 1
                board.push(move)
            if g % 1000 == 0:
                print(f"games={g} rows={n}", flush=True)
    out.close()
    print(f"done: {g} games, {n} rows -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
