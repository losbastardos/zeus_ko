#!/usr/bin/env python3
"""eco_validate.py - validacia eco.bin voci zdrojovym TSV a engine Zobrist hashu.

Kontroly:
  1. magic/verzia hlavicky, velkost suboru sedi s headerom
  2. entries su zoradene podla hash (binarne vyhladavanie)
  3. 20 nahodnych entries: hash znovu spocitany z TSV = hash v eco.bin
  4. transpozicna konzistentnost: ta ista pozicia z dvoch roznych poradi tahov
     ma rovnaky hash (nezavisle na tom, ktora liniu ju dosiahla)
  5. pozicia po 1. e4 e5 najde ECO C20 s nazvom "Open Game"
"""
import csv
import io
import random
import struct
import sys
from pathlib import Path

import chess
import chess.pgn

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "utils"))
from eco_build import MAGIC, VERSION, Zobrist, load_zobrist, HASH_ASM  # noqa: E402

ECO_BIN = ROOT / "eco.bin"
SRC = ROOT / "chess-openings"


def load_bin(path):
    data = path.read_bytes()
    magic, ver, count, blob_size = struct.unpack_from("<IIII", data, 0)
    assert magic == MAGIC, f"magic {magic:#x} != {MAGIC:#x}"
    assert ver == VERSION, f"verzia {ver} != {VERSION}"
    blob_off = 16
    ent_off = blob_off + blob_size
    assert len(data) == ent_off + count * 20, (
        f"velkost suboru {len(data)} != header(16)+blob({blob_size})+entries({count * 20})")
    blob = data[blob_off:ent_off]
    entries = []
    for i in range(count):
        h, name_off = struct.unpack_from("<QI", data, ent_off + i * 20)
        eco = data[ent_off + i * 20 + 12:ent_off + i * 20 + 16].rstrip(b"\x00").decode()
        ply = data[ent_off + i * 20 + 16]
        name = blob[name_off:blob.index(b"\x00", name_off)].decode("utf-8")
        entries.append((h, eco, name, ply))
    return entries, blob


def play(z, pgn_text):
    """Spocita hash kazdej pozicie po ply, s enpassant file ako engine."""
    board = chess.Board()
    out = []
    game = chess.pgn.read_game(io.StringIO(pgn_text))
    assert game is not None
    for move in game.mainline_moves():
        is_double = (board.piece_type_at(move.from_square) == chess.PAWN and
                     abs(chess.square_rank(move.to_square) -
                         chess.square_rank(move.from_square)) == 2)
        board.push(move)
        ep = chess.square_file(move.to_square) if is_double else None
        out.append((z.hash(board, ep), board.fullmove_number, board.turn))
    return out


def main():
    entries, _ = load_bin(ECO_BIN)
    hashes = sorted(h for h, _, _, _ in entries)
    assert hashes == [h for h, _, _, _ in entries], "entries nie su zoradene podla hash"
    print(f"OK header+zoradenie: {len(entries)} entries")

    z = Zobrist(load_zobrist(HASH_ASM))

    # 3. 20 nahodnych entries znovu spocitanych z TSV
    lines = []
    for f in ["a.tsv", "b.tsv", "c.tsv", "d.tsv", "e.tsv"]:
        with (SRC / f).open(encoding="utf-8", newline="") as fh:
            r = csv.reader(fh, delimiter="\t")
            next(r, None)
            lines += [row for row in r if len(row) >= 3 and row[0].strip()]
    random.seed(42)
    for eco, name, pgn in random.sample(lines, 20):
        seq = play(z, pgn)
        # konecna pozicia linie musi byt v eco.bin pod zodpovedajucim ECO
        h = seq[-1][0]
        idx = binary_search(entries, h)
        assert idx is not None, f"hash linie {eco} {name} nie je v eco.bin"
        e = entries[idx]
        assert e[1] == eco, f"ECO nezhoda: bin={e[1]} tsv={eco} ({name})"
    print("OK 20 nahodnych linii: hashe z TSV = hashe v eco.bin")

    # 4. transpozicie: rovnaka pozicia cez ine poradie tahov
    t1 = play(z, "1. e4 e5 2. Nf3 Nc6 3. Bb5")[-1][0]   # Ruy Lopez
    t2 = play(z, "1. Nf3 Nc6 2. e4 e5 3. Bb5")[-1][0]
    assert t1 == t2, "transpozicne hashe sa lisia!"
    assert binary_search(entries, t1) is not None
    print("OK transpozicna konzistentnost hashu")

    # 5. 1. e4 e5 -> C20 Open Game
    h = play(z, "1. e4 e5")[-1][0]
    idx = binary_search(entries, h)
    assert idx is not None
    e = entries[idx]
    assert e[1] == "C20" and e[2].split(":"[0])[0] in ("Open Game", "King's Pawn Game"), \
        f"neocekavane: {e}"
    print(f"OK 1.e4 e5 -> {e[1]} {e[2]} (ply={e[3]})")

    # startovacia pozicia: ziadny ECO (spravne, A00 zacina az po tahu)
    start = z.hash(chess.Board(), None)
    assert binary_search(entries, start) is None
    print("OK startovacia pozicia nie je v eco.bin (ocakavane)")

    print("VALIDACIA OK")


def binary_search(entries, h):
    lo, hi = 0, len(entries) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        if entries[mid][0] == h:
            return mid
        if entries[mid][0] < h:
            lo = mid + 1
        else:
            hi = mid - 1
    return None


if __name__ == "__main__":
    main()
