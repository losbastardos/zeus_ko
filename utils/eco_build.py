#!/usr/bin/env python3
"""eco_build.py - zostavi opening kniznicu eco.bin z chess-openings/*.tsv.

Format eco.bin (little-endian):
  u32 magic 0x424F4345 ("ECOB")
  u32 verzia = 1
  u32 pocet_entries
  u32 name_blob_size
  name blob: concat null-terminated UTF-8 mien (offsety rel. k zaciatku blobu)
  entries[N] zoradene podla hash, kazdy 20 B (zarovnane na 4):
    u64 hash, u32 name_off, u8 eco[4] (3 znaky + NUL), u8 ply, u8 _pad, u16 _pad

Hash pozicie = Zobrist z src/hash.asm (zobrist_keys, 1037 x dq (16*64+1+4+8)):
  index = (piece_bajt & 0xF) << 6 | sq, piece = typ(1..6) | farba(0/8)
  + side key (offset 16*64) XOR ked je na tahu cierna
  + 4 castle keys (offset 16*64+1), bity 0-3 = W O-O, W O-O-O, B O-O, B O-O-O
  + 8 en-passant keys (offset 16*64+1+4) podla file; engine nastavuje enpassant
    pri kazdom double push (bez ohadu na legalitu), preto nepouzivame
    board.ep_square (python-chess ho setuje len pri legalnom EP capture).

Pouzitie: python3 utils/eco_build.py [--src chess-openings] [--out eco.bin]
"""
import argparse
import csv
import io
import re
import struct
import sys
from pathlib import Path

import chess
import chess.pgn

MAGIC = 0x424F4345
VERSION = 1
TSV_FILES = ["a.tsv", "b.tsv", "c.tsv", "d.tsv", "e.tsv"]

ROOT = Path(__file__).resolve().parent.parent
HASH_ASM = ROOT / "src" / "hash.asm"

DQ_RE = re.compile(r"dq\s+0x([0-9a-fA-F]+)")


def load_zobrist(path):
    """Nacita 1037 x dq (16*64+1+4+8) hodnot zo src/hash.asm."""
    text = path.read_text(encoding="utf-8")
    idx = text.index("zobrist_keys:")
    block = text[idx + len("zobrist_keys:"):]
    vals = [int(h, 16) for h in DQ_RE.findall(block)]
    if len(vals) < 1037:
        raise SystemExit(f"Chyba: najdene len {len(vals)} klucov v {path}")
    return vals[:1037]


class Zobrist:
    def __init__(self, keys):
        self.keys = keys

    def hash(self, board, ep_file):
        h = 0
        for sq, piece in board.piece_map().items():
            # engine konvencia: biela figura = typ (1..6), cierna = typ|8
            bajt = piece.piece_type | (8 if piece.color == chess.BLACK else 0)
            h ^= self.keys[((bajt & 0xF) << 6) | sq]
        if board.turn == chess.BLACK:
            h ^= self.keys[1024]
        # python-chess >= 1.0: castling_rights = bitmask rokovych policok
        # (BB_H1, BB_A1, BB_H8, BB_A8); engine bity: 0=W O-O, 1=W O-O-O,
        # 2=B O-O, 3=B O-O-O
        rights = board.castling_rights
        for rook_sq, bit in ((chess.BB_H1, 0), (chess.BB_A1, 1),
                             (chess.BB_H8, 2), (chess.BB_A8, 3)):
            if rights & rook_sq:
                h ^= self.keys[1025 + bit]
        if ep_file is not None:
            h ^= self.keys[1029 + ep_file]
        return h


def iter_entries(src_dir, z):
    """Pre kazdu liniu: hash kazdej pozicie po kazdom ply."""
    n_lines = n_moves = 0
    for name in TSV_FILES:
        path = src_dir / name
        with path.open(encoding="utf-8", newline="") as f:
            reader = csv.reader(f, delimiter="\t")
            next(reader, None)  # hlavicka
            for row in reader:
                if len(row) < 3 or not row[0].strip():
                    continue
                eco, title, pgn = row[0].strip(), row[1].strip(), row[2].strip()
                if not re.fullmatch(r"[A-E]\d\d", eco):
                    print(f"warning: preskakujem riadok s ECO '{eco}'", file=sys.stderr)
                    continue
                board = chess.Board()
                game = chess.pgn.read_game(io.StringIO(pgn))
                if game is None:
                    print(f"warning: neparsovatelny PGN: {pgn!r}", file=sys.stderr)
                    continue
                moves = list(game.mainline_moves())
                total = len(moves)  # dlzka linie; ply==total = pozicia je koncom linie
                ply = 0
                for move in moves:
                    is_double = board.is_legal(move) and \
                        board.piece_type_at(move.from_square) == chess.PAWN and \
                        abs(chess.square_rank(move.to_square) -
                            chess.square_rank(move.from_square)) == 2
                    board.push(move)
                    ply += 1
                    n_moves += 1
                    ep_file = chess.square_file(move.to_square) if is_double else None
                    yield (eco.encode("ascii"), title.encode("utf-8"),
                           z.hash(board, ep_file), ply, total)
                n_lines += 1
    print(f"info: linii={n_lines} tahov={n_moves}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(ROOT / "chess-openings"))
    ap.add_argument("--out", default=str(ROOT / "eco.bin"))
    args = ap.parse_args()

    z = Zobrist(load_zobrist(HASH_ASM))

    # hash -> (eco, name, ply, exact); pri kolizii rovnakej pozicie z viac
    # liniek preferujeme: (1) pozicia je koncom vlastnej linie (ply==total),
    # (2) vacsi ply, (3) prvy vyskyt
    best = {}
    coll = 0
    for eco, name, h, ply, total in iter_entries(Path(args.src), z):
        exact = ply == total
        old = best.get(h)
        if old is not None:
            coll += 1
            if (old[3], old[2]) >= (exact, ply):
                continue
        best[h] = (eco, name, ply, exact)

    entries = sorted((h, v[0], v[1], v[2]) for h, v in best.items())

    # string blob mien
    blob = bytearray()
    name_off = {}
    for _, _, name, _ in entries:
        if name not in name_off:
            name_off[name] = len(blob)
            blob += name + b"\x00"

    out = Path(args.out)
    with out.open("wb") as f:
        f.write(struct.pack("<IIII", MAGIC, VERSION, len(entries), len(blob)))
        f.write(bytes(blob))
        for h, eco, name, ply in entries:
            eco4 = (eco + b"\x00")[:4].ljust(4, b"\x00")
            f.write(struct.pack("<Q", h))
            f.write(struct.pack("<I", name_off[name]))
            f.write(eco4)
            f.write(struct.pack("<BBBB", ply & 0xFF, 0, 0, 0))

    print(f"entries={len(entries)} uniq_hashes={len(best)} "
          f"duplicitnych_ignorovanych={coll} name_blob={len(blob)}B "
          f"velkost={out.stat().st_size}B")


if __name__ == "__main__":
    main()
