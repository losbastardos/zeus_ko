#!/usr/bin/env python3
"""Bit-exaktna kontrola evaluate() pred/po F4 bitboard adaptacii.

Spusti engine v UCI rezime, pre kazdy FEN spravi `go depth 1` (OwnBook off)
a ulozi `score cp` z info riadku (deterministicke pri fixnej hlbke).
Pouzitie:
  eval_bb_exact_check.py capture <binary> <out.txt>   # zber referencie
  eval_bb_exact_check.py compare <binary> <ref.txt>   # porovnanie, ocakava 0 rozdielov
FENy: prvych 50 z arasan2026.epd + 150 nahodnych z dalsich suite (fixny seed).
"""
import random
import re
import subprocess
import sys

ROOT = "/var/www/html/chess"


def collect_fens():
    fens = []
    with open(f"{ROOT}/tests/suites/external/arasan2026.epd") as f:
        for line in f:
            line = line.strip()
            if line:
                fens.append(line)
                if len(fens) >= 50:
                    break
    pool = []
    for path in ("tests/suites/external/STS1.epd",
                 "tests/suites/external/silent-but-deadly.epd"):
        try:
            with open(f"{ROOT}/{path}") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        pool.append(line)
        except FileNotFoundError:
            pass
    rnd = random.Random(20261001)
    rnd.shuffle(pool)
    fens.extend(pool[:150])
    out = []
    for line in fens:
        parts = line.split()
        # EPD: vezmem 4 polia board/side/castling/ep, doplnime halfmove/fullmove
        fen = " ".join(parts[:4])
        hm = parts[4] if len(parts) > 4 and re.fullmatch(r"\d+", parts[4]) else "0"
        fm = parts[5] if len(parts) > 5 and re.fullmatch(r"\d+", parts[5]) else "1"
        out.append(f"{fen} {hm} {fm}")
    return out


def run_engine(binary, fens):
    cmds = ["setoption name OwnBook value false"]
    for mode in ("0", "2"):
        cmds.append(f"setoption name EvalMode {mode}")
        for fen in fens:
            cmds.append(f"position fen {fen}")
            cmds.append("go depth 1")
    cmds.append("quit")
    proc = subprocess.run(
        [binary, "--uci"], input="uci\n" + "\n".join(cmds) + "\n",
        capture_output=True, text=True, timeout=1800, cwd=ROOT,
    )
    # Sekvencia: mode0 -> vsetky feny, mode2 -> vsetky feny.
    # Niektore pozicie (mat/pat) nemaju info riadok: berieme "bestmove 0000"
    # ako marker "nomove".
    events = []
    for l in proc.stdout.splitlines():
        m = re.match(r"info depth 1 .*score (cp|mate) (-?\d+)", l)
        if m:
            events.append(f"{m.group(1)} {m.group(2)}")
        elif re.match(r"bestmove (0000|none)", l):
            events.append("nomove")
    n = len(fens)
    if len(events) != 2 * n:
        print(f"CHYBA: ocakavane {2*n} udalosti, dostal {len(events)}")
        sys.exit(2)
    scores = {}
    for i, fen in enumerate(fens):
        scores[("0", fen)] = events[i]
    for i, fen in enumerate(fens):
        scores[("2", fen)] = events[n + i]
    return scores


def capture(binary, out_path):
    fens = collect_fens()
    scores = run_engine(binary, fens)
    with open(out_path, "w") as f:
        for mode in ("0", "2"):
            for fen in fens:
                f.write(f"{mode} {fen} {scores[(mode, fen)]}\n")

    print(f"captured {len(scores)} scores -> {out_path}")


def compare(binary, ref_path):
    ref = {}
    with open(ref_path) as f:
        for line in f:
            parts = line.strip().split(" ")
            mode, score = parts[0], " ".join(parts[-2:])
            fen = " ".join(parts[1:-2])
            ref[(mode, fen)] = score
    fens = []
    seen = set()
    for (mode, fen) in ref:
        if fen not in seen:
            seen.add(fen)
            fens.append(fen)
    got = run_engine(binary, fens)
    diffs = 0
    for key, want in ref.items():
        if got.get(key) != want:
            diffs += 1
            if diffs <= 20:
                print(f"DIFF {key[0]} {key[1]} ref={want} got={got.get(key)}")
    print(f"compared {len(ref)} scores, diffs={diffs}")
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    if sys.argv[1] == "capture":
        capture(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3])
    else:
        print("pouzitie: capture|compare ...")
        sys.exit(2)
