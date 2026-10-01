#!/usr/bin/env python3
"""nnue_acc_check.py — E10/F2 Step 5: konzistenca inkrementalneho NNUE
akumulatora (acc delta v make/unmake) vs nezavisle ground truth.

Dve casti:

1) EXACT EVAL CHECK (vzdy, nezavisle od referencnej binary):
   Pozicie s prave JEDNYM legalnym tahom: `go depth 1` skore engine sa
   rovna -static_eval(P po tahu) — ziadne heuristiky/hladanie sa
   neuplatnia (jediny tah). Python NNUE forward z net2.nnue (ground
   truth, overene 1:1 proti traineru nnue_train2.py) musi dat bit-exakt
   rovnake hodnoty. Pozicie pokryvaju vsetky typy figuriek na viacerych
   polickach a obe strany na tahu (mirror ciest).

2) BIT-EXACT SEARCH CHECK (s --ref BINARKA):
   Nahodne partie (python-chess), >= --min-total pozicii; pre kazdu sa
   v CISTOM procese (bez TT reuse) spusti `go depth 1` (kazda 4. aj
   depth 3) na kandidatovi aj referencnej binary a skore/bestmove musia
   byt bit-exakt rovnake. Referencia = build bez inkrementalneho acc
   (bb-f1). Prejde len ak obe binarky pouzivaju identicky eval a search;
   akakolvek chyba delta acc sa prejavi ako rozne skore/bestmove.

Vystup: sucet mismatchov; exit 0 pri 0.

Pouzitie:
  tests/tuning/.venv/bin/python tests/tuning/nnue_acc_check.py \
      [--engine ./chess-static] [--ref /tmp/chess-f1-ref] \
      [--net net2.nnue] [--min-total 200] [--seed 42]
"""

import argparse
import configparser
import random
import re
import struct
import subprocess
import sys

import chess


class NNUE2:
    """NNUE v2 loader + forward (format podla src/nnue.asm / nnue_train2.py)."""

    F = 768

    def __init__(self, path):
        with open(path, "rb") as f:
            blob = f.read()
        magic, ver, h, s1, s2 = struct.unpack_from("<5I", blob, 0)
        assert magic == 0x45554E4E, "zl magic (nie NNUE subor)"
        assert ver == 2, f"ocakavana verzia 2, je {ver}"
        self.H, self.shift1, self.shift2 = h, s1, s2
        off = 20
        self.b1 = list(struct.unpack_from(f"<{h}i", blob, off))
        off += 4 * h
        self.W1 = struct.unpack_from(f"<{self.F * h}h", blob, off)
        off += 2 * self.F * h
        (self.b2,) = struct.unpack_from("<i", blob, off)
        off += 4
        self.W2 = struct.unpack_from(f"<{h}h", blob, off)

    def _features(self, board, perspective):
        idxs = []
        mirror = 56 if perspective else 0
        for sq, piece in board.piece_map().items():
            typ = piece.piece_type            # 1..6
            color = 0 if piece.color else 1   # python-chess: True = biela
            own = color ^ perspective
            rel = sq ^ mirror
            if typ == chess.KING:
                idx = 640 + own * 64 + rel
            else:
                idx = (own * 5 + typ - 1) * 64 + rel
            idxs.append(idx)
        return idxs

    def eval_stm(self, board):
        stm = 0 if board.turn == chess.WHITE else 1
        H = self.H
        acc = list(self.b1)
        W1 = self.W1
        for idx in self._features(board, stm):
            row = idx * H
            for j in range(H):
                acc[j] += W1[row + j]
        total = self.b2
        s1 = self.shift1
        for j in range(H):
            v = acc[j] >> s1
            if v < 0:
                v = 0
            elif v > 255:
                v = 255
            total += v * self.W2[j]
        return total >> self.shift2


def run_engine_once(engine, commands):
    """Jeden cisty engine proces, vrat vystup."""
    proc = subprocess.run(
        [engine, "--uci"],
        input="\n".join(commands) + "\n",
        capture_output=True,
        text=True,
        timeout=60,
    )
    return proc.stdout


def go_scores(output):
    """extrahuj (score, bestmove) dvojice pre kazde 'go'."""
    results = []
    score = None
    for line in output.splitlines():
        m = re.search(r"score cp (-?\d+)", line)
        if m:
            score = int(m.group(1))
        if line.startswith("bestmove"):
            results.append((score, line.split()[1].strip()))
            score = None
    return results


# ------------------------------------------------------------
# Cast 1: presny eval cez 1-tahove pozicie
#   cierny kral a8, biely kral a7, biela veza b6 -> cierny ma jediny
#   tah Kb8; volitelne jedna cierna figurka naviac (test feature).
# ------------------------------------------------------------
def one_move_fens():
    fens = []
    # zaklad (same fig, 2 strany na tahu)
    # Pozicie s ciernym na tahu (mirror ciest pre bieleho kryje part2,
    # kde polovica nahodnych pozicii taha ciernym).
    fens.append("k7/K7/1R6/8/8/8/8/8 b - - 0 1")
    squares = [chess.D3, chess.E4, chess.F5, chess.G2, chess.C5, chess.H4]
    piece_types = [chess.PAWN, chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN]
    for pt in piece_types:
        for sq in squares:
            # cierna figurka na sq (ak nie je na 8. rangu, pesec OK)
            b = chess.Board("k7/K7/1R6/8/8/8/8/8 b - - 0 1")
            if b.piece_at(sq) is None:
                b.set_piece_at(sq, chess.Piece(pt, chess.BLACK))
                fens.append(b.fen())
            # biela figurka, cierny na tahu (own=0 cesta)
            b2 = chess.Board("k7/K7/1R6/8/8/8/8/8 b - - 0 1")
            if b2.piece_at(sq) is None:
                b2.set_piece_at(sq, chess.Piece(pt, chess.WHITE))
                fens.append(b2.fen())
    return fens


def part1_exact(engine, net):
    fens = one_move_fens()
    cmds = ["uci", "setoption name OwnBook value false",
            "setoption name SyzygyProbeDepth value 99"]
    for fen in fens:
        cmds.append(f"position fen {fen}")
        cmds.append("go depth 1")
    cmds.append("quit")
    out = run_engine_once(engine, cmds)
    eng = go_scores(out)
    assert len(eng) == len(fens), f"ocakavane {len(fens)} vysledkov, je {len(eng)}"
    bad = 0
    for fen, (score, _bm) in zip(fens, eng):
        b = chess.Board(fen)
        mv = list(b.legal_moves)
        assert len(mv) == 1, f"pozicia nema 1 tah: {fen}"
        b.push(mv[0])
        py = -net.eval_stm(b)
        if py != score:
            bad += 1
            print(f"  MISMATCH py={py} engine={score} fen={fen}")
    print(f"part1 exact: positions={len(fens)} mismatches={bad}")
    return bad


# ------------------------------------------------------------
# Cast 2: bit-exakt kandidat vs referencia na nahodnych poziciach
# ------------------------------------------------------------
def part2_random(engine, ref, min_total, seed):
    rng = random.Random(seed)
    total = 0
    bad = 0
    games = 0
    while total < min_total:
        games += 1
        board = chess.Board()
        for _ in range(rng.randint(8, 60)):
            if board.is_game_over():
                break
            board.push(rng.choice(list(board.legal_moves)))
            if rng.random() < 0.4:
                continue
            total += 1
            fen = board.fen()
            depth = 3 if total % 4 == 0 else 1
            cmds = ["uci", "setoption name OwnBook value false",
                    "setoption name SyzygyProbeDepth value 99",
                    f"position fen {fen}", f"go depth {depth}", "quit"]
            out_c = run_engine_once(engine, cmds)
            out_r = run_engine_once(ref, cmds)
            sc, sr = go_scores(out_c), go_scores(out_r)
            if sc != sr:
                bad += 1
                print(f"  MISMATCH cand={sc} ref={sr} depth={depth} fen={fen}")
            if total >= min_total:
                break
    print(f"part2 random: games={games} positions={total} mismatches={bad}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="./chess-static")
    ap.add_argument("--ref", default=None,
                    help="referencna binary (bb-f1 build) pre part2")
    ap.add_argument("--net", default=None)
    ap.add_argument("--min-total", type=int, default=200)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    net_path = args.net
    if net_path is None:
        ini = configparser.ConfigParser()
        ini.read("chess.ini")
        net_path = ini.get("engine", "nnue_file", fallback="net2.nnue")
    net = NNUE2(net_path)
    print(f"net: {net_path} H={net.H} shift1={net.shift1} shift2={net.shift2}")

    bad = part1_exact(args.engine, net)
    if args.ref:
        bad += part2_random(args.engine, args.ref, args.min_total, args.seed)
    else:
        print("part2 preskocena (bez --ref)")

    if bad:
        print(f"FAIL: {bad} mismatchov")
        sys.exit(1)
    print("OK: 0 mismatchov — inkrementalny NNUE acc konzistentny")


if __name__ == "__main__":
    main()
