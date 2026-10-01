#!/usr/bin/env python3
"""Legality 1:1 test: engine `list` (UCI helper) vs python-chess legal_moves.

Sada: Kiwipete, EP FEN, promo FEN, castle-do-sachu FEN, 50 nahodnych hier
po 30 tahoch. Pre kazdu poziciu presna zhoda mnozin tahov.
Engine tlaci tahy ako riadky 'e2e4' (bez promo pismena) — preto porovnavame
multimnoziny (from,to) parov: 4 promocne tahy davaju 4x rovnaky par.
"""
import random
import subprocess
import sys

import chess

ENGINE = "./chess-static"
N_RANDOM = 50
MOVES_PER_GAME = 30

FIXED_FENS = [
    # Kiwipete (klasicky legality/perft tester)
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    # en passant: biely moze brat e.p.
    "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3",
    # en passant: cierny moze brat e.p. (d4 c5 b2b4 cxd4 e.p. nie, ale cxb4 nie je ep)
    "rnbqkbnr/pp1ppppp/8/8/2pPP3/8/PPP2PPP/RNBQKBNR b KQkq d3 0 3",
    # promo biely + branie do prazdneho aj obsadeneho
    "8/2P5/8/8/8/8/6p1/K6k w - - 0 1",
    # promo cierny
    "K6k/8/8/8/8/8/2p5/8 b - - 0 1",
    # rosada do/p cez sach nesmie byt legalna
    "r3k2r/8/8/8/8/8/5q2/R3K2R w KQkq - 0 1",
    # pinned figury
    "4k3/8/8/8/8/8/4r3/4K2R w K - 0 1",
]


def engine_legal_moves(fen):
    out = subprocess.run(
        [ENGINE, "--uci"],
        input=f"uci\nposition fen {fen}\nlist\nquit\n",
        capture_output=True, text=True, timeout=30,
    ).stdout
    moves = []
    for line in out.splitlines():
        line = line.strip()
        if len(line) == 4 and line[0] in "abcdefgh" and line[2] in "abcdefgh":
            if line[1].isdigit() and line[3].isdigit():
                moves.append((line[:2], line[2:]))
    return moves


def python_legal_moves(fen):
    board = chess.Board(fen)
    return [(chess.square_name(m.from_square), chess.square_name(m.to_square))
            for m in board.legal_moves]


def compare(fen, label):
    eng = engine_legal_moves(fen)
    py = python_legal_moves(fen)
    if sorted(eng) != sorted(py):
        es, ps = sorted(eng), sorted(py)
        only_eng = [m for m in es if m not in ps or es.count(m) > ps.count(m)]
        only_py = [m for m in ps if m not in es or ps.count(m) > es.count(m)]
        print(f"FAIL [{label}] {fen}")
        print(f"  engine: {len(eng)} python: {len(py)}")
        print(f"  engine-only: {sorted(set(only_eng))}")
        print(f"  python-only: {sorted(set(only_py))}")
        return False
    return True


def main():
    ok = True
    for i, fen in enumerate(FIXED_FENS):
        if not compare(fen, f"fixed-{i}"):
            ok = False
    random.seed(20261001)
    for g in range(N_RANDOM):
        board = chess.Board()
        for _ in range(MOVES_PER_GAME):
            if board.is_game_over():
                break
            board.push(random.choice(list(board.legal_moves)))
        if not compare(board.fen(), f"random-{g}"):
            ok = False
    if ok:
        print(f"ALL OK ({len(FIXED_FENS)} fixed + {N_RANDOM} random positions)")
        return 0
    print("MISMATCHES FOUND")
    return 1


if __name__ == "__main__":
    sys.exit(main())
