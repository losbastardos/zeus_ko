#!/usr/bin/env python3
"""Self-play dataset generator for NNUE training.

Drives one ./chess-static --uci engine that plays both sides:
opening moves come from the engine book (variety), then fixed-depth
search. Records every position (side to move) + game result into a
Texel-style CSV. Draws are claimed by this script (50-move rule,
threefold repetition); mate/stalemate end the game.

Usage:
  python3 tests/tuning/selfplay_dataset.py --engine ./chess-static \
      --games 200 --depth 4 --out tests/reports/selfplay.csv \
      --max-plies 160 --seed 20260917
"""

from __future__ import annotations

import argparse
import csv
import random
import subprocess
import sys
import time

try:
    import chess
except Exception as exc:  # pragma: no cover
    print(f"error: python-chess required ({exc})", file=sys.stderr)
    raise SystemExit(2)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Self-play dataset generator")
    p.add_argument("--engine", default="./chess-static")
    p.add_argument("--games", type=int, default=200)
    p.add_argument("--depth", type=int, default=4)
    p.add_argument("--max-plies", type=int, default=160)
    p.add_argument("--out", default="tests/reports/selfplay.csv")
    p.add_argument("--seed", type=int, default=20260917)
    p.add_argument("--book", type=int, default=1, help="1 = engine book on")
    p.add_argument("--skip-plies", type=int, default=8)
    p.add_argument("--sample-every", type=int, default=1)
    return p.parse_args()


class UciEngine:
    def __init__(self, path: str):
        self.proc = subprocess.Popen(
            [path, "--uci"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        self.send("uci")
        self.wait_for("uciok")
        self.send("isready")
        self.wait_for("readyok")

    def send(self, line: str) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def readline(self) -> str:
        assert self.proc.stdout
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("engine closed stdout")
        return line.strip()

    def wait_for(self, token: str, max_lines: int = 100000) -> None:
        for _ in range(max_lines):
            if self.readline() == token:
                return
        raise RuntimeError(f"timeout waiting for {token}")

    def bestmove(self, position_cmd: str, depth: int) -> str:
        self.send(position_cmd)
        self.send(f"go depth {depth}")
        move = ""
        while True:
            line = self.readline()
            if line.startswith("bestmove"):
                move = line.split()[1]
                break
        return move

    def eval_cp(self, fen: str, depth: int):
        """score cp z pohladu strany na tahu, alebo None pri mate"""
        self.send(f"position fen {fen}")
        self.send(f"go depth {depth}")
        cp = None
        while True:
            line = self.readline()
            if line.startswith("info depth ") and " score cp " in line:
                try:
                    cp = int(line.split(" score cp ")[1].split()[0])
                except Exception:
                    cp = None
            if line.startswith("info depth ") and " score mate " in line:
                cp = 10000 if int(line.split(" score mate ")[1].split()[0]) > 0 else -10000
            if line.startswith("bestmove"):
                break
        return cp

    def close(self) -> None:
        try:
            self.send("quit")
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def main() -> int:
    args = parse_args()
    rng = random.Random(args.seed)
    eng = UciEngine(args.engine)
    eng.send(f"setoption name OwnBook value {'true' if args.book else 'false'}")

    rows = []
    t0 = time.time()
    PV = {chess.PAWN: 100, chess.KNIGHT: 320, chess.BISHOP: 330,
          chess.ROOK: 500, chess.QUEEN: 900, chess.KING: 0}
    for game in range(1, args.games + 1):
        board = chess.Board()
        positions = []          # (fen, ply) per side-to-move
        moves_uci = []
        result = None
        # asymetricke hlbky per strana (varieta, breaknutie cyklov)
        depth_w = rng.choice([args.depth, args.depth + 1])
        depth_b = rng.choice([args.depth, args.depth + 1])
        # adjudikacia cez engine eval: kazdych 8 ply depth-8 probe,
        # |cp| >= 600 dva po sebe -> vyhra podla znamienka (fair, symetricke)
        adjud_hits = 0
        for ply in range(args.max_plies):
            if board.is_game_over(claim_draw=False):
                break
            pos_cmd = "position startpos"
            if moves_uci:
                pos_cmd += " moves " + " ".join(moves_uci)
            depth = depth_w if board.turn == chess.WHITE else depth_b
            mv = eng.bestmove(pos_cmd, depth)
            if mv in ("0000", "(none)"):
                break
            try:
                move = chess.Move.from_uci(mv)
                if move not in board.legal_moves:
                    break
            except Exception:
                break
            positions.append((board.fen(), ply))
            board.push(move)
            moves_uci.append(mv)
            if ply % 8 == 7 and ply >= 24:
                ev = eng.eval_cp(board.fen(), 8)
                if ev is not None and abs(ev) >= 600:
                    adjud_hits += 1
                    if adjud_hits >= 2:
                        # ev z perspektivy strany na tahu = biela po neparne? v tomto
                        # bode tahal prave hrac, ktory urobil move; ev je z pohladu
                        # strany, ktora je teraz na tahu (super tahu)
                        stm_is_white = board.turn == chess.WHITE
                        white_cp = ev if stm_is_white else -ev
                        result = 1.0 if white_cp > 0 else 0.0
                        break
                else:
                    adjud_hits = 0
            if board.is_seventyfive_moves():
                result = 0.5
                break
            if board.is_fivefold_repetition():
                result = 0.5
                break
        if result is None:
            if board.is_checkmate():
                result = 0.0 if board.turn == chess.WHITE else 1.0
            else:
                result = 0.5
        for fen, ply in positions:
            if ply >= args.skip_plies and (ply - args.skip_plies) % args.sample_every == 0:
                rows.append((fen, f"{result:.1f}", ply, game, "selfplay"))
        if game % 25 == 0:
            el = time.time() - t0
            print(f"games={game} rows={len(rows)} elapsed={el:.0f}s", flush=True)

    eng.close()
    with open(args.out, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["fen", "result", "ply", "game_index", "source"])
        w.writerows(rows)
    print(f"done: {args.games} games, {len(rows)} rows -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
