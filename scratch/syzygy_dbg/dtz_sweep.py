#!/usr/bin/env python3
"""Stored-side DTZ sweep: engine_sym == py_sym (Dual-AI gate).

Python ground truth: pre kazdy idx v [0, tb_size) priamo vola
DtzTable.decompress_pairs (encode path je overeny osobitne).
Engine: tbtest nad vsetkymi legalnymi poziciami stored side.

Pouzitie:
    python3 dtz_sweep.py KQvK [--engine ./chess-static] [--tb tb]
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chess  # noqa: E402
import syzygy  # noqa: E402

TABLE_PIECES = {
    # table: (extra piece type, strong color)
    "KQvK": (chess.QUEEN, chess.WHITE),
    "KRvK": (chess.ROOK, chess.WHITE),
    "KBvK": (chess.BISHOP, chess.WHITE),
    "KNvK": (chess.KNIGHT, chess.WHITE),
    "KvQK": (chess.QUEEN, chess.BLACK),
    "KvRK": (chess.ROOK, chess.BLACK),
    "KvBK": (chess.BISHOP, chess.BLACK),
    "KvNK": (chess.KNIGHT, chess.BLACK),
}

TBTEST_RE = re.compile(
    r"dtz_idx=(\d+).*?dtz_raw_symbol=(-?\d+).*?dtz_helper_ok=(\d+)")


def gen_positions(piece_type, strong):
    weak = not strong
    for k1 in chess.SQUARES:
        for k2 in chess.SQUARES:
            if chess.square_distance(k1, k2) <= 1:
                continue
            for e in chess.SQUARES:
                if e == k1 or e == k2:
                    continue
                board = chess.Board(None)
                board.set_piece_at(k1, chess.Piece(chess.KING, strong))
                board.set_piece_at(k2, chess.Piece(chess.KING, weak))
                board.set_piece_at(e, chess.Piece(piece_type, strong))
                board.turn = strong
                yield board


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("table", choices=sorted(TABLE_PIECES))
    ap.add_argument("--engine", default="./chess-static")
    ap.add_argument("--tb", default="tb")
    args = ap.parse_args()

    piece_type, strong = TABLE_PIECES[args.table]

    # --- python ground truth: vsetky idx priamo z tabulky ---
    tb = syzygy.Tablebase(max_fds=4)
    tb.add_directory(args.tb)

    first = next(gen_positions(piece_type, strong))
    # staci lubovolne platne wdl - porovnavany raw_symbol je pre-map,
    # wdl ovplyvnuje len final_res (map), nie walk ani idx
    _, success = tb.probe_dtz_table(first, 2)
    assert success >= 0, f"prva pozicia nie je stored side? success={success}"
    dbg = syzygy.DEBUG_LAST_DTZ
    print(f"py probe: idx={dbg['idx']} raw={dbg['raw_symbol']} "
          f"bside={dbg['bside']}")

    key = syzygy.calc_key(first)
    dtab = tb.dtz[key]
    assert not dtab.has_pawns
    d = dtab.precomp
    tb_size = dtab.tb_size[0]
    print(f"py idx-space: tb_size={tb_size}")

    py_sym = {}
    for idx in range(tb_size):
        py_sym[idx] = dtab.decompress_pairs(d, idx)

    # --- engine: tbtest nad vsetkymi legalnymi poziciami stored side ---
    with tempfile.NamedTemporaryFile("w", suffix=".uci", delete=False) as f:
        script_path = f.name
        f.write("uci\n")
        f.write(f"setoption name SyzygyPath value {args.tb}\n")
        n_pos = 0
        for board in gen_positions(piece_type, strong):
            f.write(f"position fen {board.fen()}\n")
            f.write("tbtest\n")
            n_pos += 1
        f.write("quit\n")
    print(f"engine: {n_pos} pozicii -> {script_path}")

    eng_sym = {}
    eng_dup_bad = 0
    with open(script_path) as fin, \
            subprocess.Popen([args.engine, "--uci"], stdin=fin,
                             stdout=subprocess.PIPE, text=True) as proc:
        assert proc.stdout is not None
        for line in proc.stdout:
            if "tbtest" not in line:
                continue
            m = TBTEST_RE.search(line)
            if not m:
                continue
            idx, raw, ok = int(m.group(1)), int(m.group(2)), int(m.group(3))
            if not ok:
                continue
            if idx in eng_sym and eng_sym[idx] != raw:
                eng_dup_bad += 1
            eng_sym[idx] = raw
    rc = proc.returncode
    print(f"engine: rc={rc} decoded={len(eng_sym)} pozicii, dup_conflicts={eng_dup_bad}")

    # --- porovnanie ---
    mismatch = [(idx, py_sym[idx], eng_sym[idx])
                for idx in eng_sym if py_sym.get(idx) != eng_sym[idx]]
    missing = [idx for idx in py_sym if idx not in eng_sym]
    print(f"RESULT {args.table}: engine={len(eng_sym)} py={len(py_sym)} "
          f"mismatch={len(mismatch)} missing={len(missing)}")
    for idx, pyv, engv in mismatch[:20]:
        print(f"  MISMATCH idx={idx} py={pyv} engine={engv}")
    for idx in missing[:20]:
        print(f"  MISSING idx={idx} py={py_sym[idx]}")
    return 1 if (mismatch or missing or eng_dup_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
