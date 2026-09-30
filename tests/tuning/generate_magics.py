#!/usr/bin/env python3
"""Generator magic konstant pre magic bitboardy (E10/F1).

Najde pre kazde policko (0..63, a1=0) magicke konstanty pre strelca
a vezu tak, aby indexovanie ((occ & mask) * magic) >> shift bolo
bezkolizne pre vsetky podmnoziny relevantnej masky. Vystup:
src/magics.inc (NASM, record = dq mask, dq magic, dq shift, dq offset,
32 B/zaznam). Runtime naplnenie magic_attacks robi pos_magics_init
v src/position.asm.

Ocakavane velkosti: bishop=5248, rook=102400, total=107648
(standardne magic bitboard tabulky; shift = 64 - popcount(mask)).
Cisty python (python-chess netreba). Deterministicky seed.

Run: tests/tuning/.venv/bin/python tests/tuning/generate_magics.py
"""

import random
import sys
from pathlib import Path

SQ_COUNT = 64
OUT_PATH = Path(__file__).resolve().parent.parent.parent / "src" / "magics.inc"

BISHOP_DIRS = ((1, 1), (1, -1), (-1, 1), (-1, -1))
ROOK_DIRS = ((1, 0), (-1, 0), (0, 1), (0, -1))


def file_of(sq):
    return sq & 7


def rank_of(sq):
    return sq >> 3


def sq_of(f, r):
    return r * 8 + f


def relevant_mask(sq, dirs):
    """Maska poliok, ktore mozu blokovat luc z sq.

    Do masky patria vsetky policka luca okrem posledneho (za nim uz
    ziadna obsadenost vysledok nezmeni). Hranicne policka v
    nesmerovanej osi sa nevyucuju (napr. z a4 severny luc: a5..a7,
    iba a8 sa vylucuje).
    """
    f, r = file_of(sq), rank_of(sq)
    mask = 0
    for df, dr in dirs:
        nf, nr = f + df, r + dr
        while 0 <= nf < 8 and 0 <= nr < 8:
            nnf, nnr = nf + df, nr + dr
            if 0 <= nnf < 8 and 0 <= nnr < 8:
                mask |= 1 << sq_of(nf, nr)
            nf, nr = nnf, nnr
    return mask


def attacks(sq, occ, dirs):
    """Ray-casting utoky z sq pri obsadeni occ (cele dosahove lucisko)."""
    f, r = file_of(sq), rank_of(sq)
    res = 0
    for df, dr in dirs:
        nf, nr = f + df, r + dr
        while 0 <= nf < 8 and 0 <= nr < 8:
            s = sq_of(nf, nr)
            res |= 1 << s
            if (occ >> s) & 1:
                break
            nf += df
            nr += dr
    return res


def popcount(x):
    return bin(x).count("1")


def subsets(mask):
    """Postupne vsetky podmnoziny masky (carry-ripple enumeracia)."""
    sub = 0
    while True:
        yield sub
        sub = (sub - mask) & mask
        if sub == 0:
            return


def find_magic(sq, mask, dirs, rng):
    """Najde magic pre sq; vrati (magic, shift) alebo None."""
    shift = 64 - popcount(mask)
    occs = list(subsets(mask))
    atts = [attacks(sq, o, dirs) for o in occs]
    while True:
        # sparse magic kandidat (zopar nastavenych bitov): najde sa
        # v malom pocte pokusov, hash indexy su dobre rozostrene
        magic = (
            rng.getrandbits(64) & rng.getrandbits(64) & rng.getrandbits(64)
        )
        if magic == 0:
            continue
        seen = set()
        for occ, att in zip(occs, atts):
            idx = ((occ * magic) & 0xFFFFFFFFFFFFFFFF) >> shift
            if idx in seen:
                break
            seen.add(idx)
        else:
            return magic, shift


def gen_table(dirs, rng, offset_start=0):
    """Pre vsetky policka najde magicky; vrati zoznam (mask, magic, shift, offset).

    offset_start: offset prveho zaznamu v zdielanej magic_attacks
    (rook sekcia zacina za bishop sekcii).
    """
    entries = []
    offset = offset_start
    for sq in range(SQ_COUNT):
        mask = relevant_mask(sq, dirs)
        magic, shift = find_magic(sq, mask, dirs, rng)
        entries.append((mask, magic, shift, offset))
        offset += 1 << popcount(mask)
    return entries, offset


def write_inc(bishop, rook, b_total, r_total, out_path):
    lines = []
    lines.append("; magics.inc - generovane magic konstanty (E10/F1)")
    lines.append("; Generuje: tests/tuning/generate_magics.py (deterministicky seed)")
    lines.append("; Record: dq mask, dq magic, dq shift, dq offset (32 B/zaznam)")
    lines.append("; idx = ((occ & mask) * magic) >> shift; attacks = magic_attacks[offset+idx]")
    lines.append(f"MAGICS_BISHOP_SIZE equ {b_total}")
    lines.append(f"MAGICS_ROOK_OFFSET equ {b_total}")
    lines.append(f"MAGICS_TOTAL equ {b_total + r_total}")
    lines.append("section .rodata")
    lines.append("global magics_bishop, magics_rook")
    lines.append("magics_bishop:")
    for mask, magic, shift, offset in bishop:
        lines.append(f"    dq 0x{mask:016x}, 0x{magic:016x}, {shift}, {offset}")
    lines.append("magics_rook:")
    for mask, magic, shift, offset in rook:
        lines.append(f"    dq 0x{mask:016x}, 0x{magic:016x}, {shift}, {offset}")
    lines.append("")
    out_path.write_text("\n".join(lines), encoding="utf-8")


def main():
    rng = random.Random(20260929)
    bishop, b_total = gen_table(BISHOP_DIRS, rng, 0)
    rook, r_total = gen_table(ROOK_DIRS, rng, b_total)
    if b_total != 5248 or r_total - b_total != 102400 or r_total != 107648:
        print(f"ERROR: bishop={b_total} rook={r_total - b_total} total={r_total}")
        sys.exit(1)
    write_inc(bishop, rook, b_total, r_total, OUT_PATH)
    print(f"bishop={b_total} rook={r_total - b_total} total={r_total} ok -> {OUT_PATH}")


if __name__ == "__main__":
    main()
