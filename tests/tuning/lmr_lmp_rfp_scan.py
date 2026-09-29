#!/usr/bin/env python3
"""Faktoriálny scan search heuristik a volitelny LMR parameter sweep pre chess-static."""

from __future__ import annotations

import argparse
import csv
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from itertools import product
from typing import List, Tuple

RESULT_RE = re.compile(r"score=([0-9]+)/([0-9]+)")

HEURISTICS = ["LMR", "LMP", "RFP"]


@dataclass
class RunRow:
    variant: str
    lmr: int
    lmp: int
    rfp: int
    lmr_index_min: int
    lmr_depth_min: int
    lmr_base_reduction: int
    lmr_extra_non_improving: int
    depth: int
    hits: int
    total: int
    rc: int


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="LMR/LMP/RFP factorial scan")
    p.add_argument("--suite", default="tests/suites/external/arasan2026.epd")
    p.add_argument("--depths", default="6,8")
    p.add_argument("--movetime", type=int, default=0,
                   help="ak > 0, pouzi time-based suite s max depth 64 a zadanou movetime ms")
    p.add_argument("--timeout", default="900s")
    p.add_argument("--report", default="tests/reports/lmr_lmp_rfp_scan.txt")
    p.add_argument("--csv", default="tests/reports/lmr_lmp_rfp_scan.csv")
    p.add_argument("--lmr-param-sweep", action="store_true",
                   help="sweep LMR parametrov namiesto 2^3 heuristik")
    p.add_argument("--lmr-index-min", default="4,8",
                   help="zoznam hodnot index threshold (csv)")
    p.add_argument("--lmr-depth-min", default="3,4",
                   help="zoznam hodnot depth threshold (csv)")
    p.add_argument("--lmr-base-reduction", default="1,0",
                   help="zoznam hodnot zakladnej LMR redukcie (csv)")
    p.add_argument("--lmr-extra-non-improving", default="1,0",
                   help="zoznam hodnot extra redukcie pri !improving (csv)")
    p.add_argument("--lmp", type=int, default=1,
                   help="pevna hodnota ENABLE_LMP pre LMR sweep")
    p.add_argument("--rfp", type=int, default=1,
                   help="pevna hodnota ENABLE_RFP pre LMR sweep")
    return p.parse_args()


def variant_name(lmr: int, lmp: int, rfp: int) -> str:
    return f"chess-static-lmr{lmr}_lmp{lmp}_rfp{rfp}"


def defines(lmr: int, lmp: int, rfp: int) -> str:
    return f"-DENABLE_LMR={lmr} -DENABLE_LMP={lmp} -DENABLE_RFP={rfp}"


def parse_int_list(raw: str) -> List[int]:
    vals: List[int] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        vals.append(int(part))
    return vals


def run_cmd(cmd: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def suite_score(engine: str, depth: int, suite: str, timeout_s: str,
                movetime_ms: int = 0) -> Tuple[int, int, int, str]:
    if movetime_ms > 0:
        cmd = (
            f"timeout {timeout_s} sh -c "
            f"'printf \"uci\\nsuite {suite} 64 {movetime_ms}\\nquit\\n\" | ./{engine} --uci'"
        )
    else:
        cmd = (
            f"timeout {timeout_s} sh -c "
            f"'printf \"uci\\nsuite {suite} {depth}\\nquit\\n\" | ./{engine} --uci'"
        )
    p = run_cmd(cmd)
    m = RESULT_RE.search(p.stdout)
    if not m:
        return p.returncode, 0, 0, p.stdout
    return p.returncode, int(m.group(1)), int(m.group(2)), p.stdout


def build_variant(name: str, defs: str) -> int:
    cmd = f"make variant-static OUT={shlex.quote(name)} DEFINES={shlex.quote(defs)}"
    p = run_cmd(cmd)
    if p.returncode != 0:
        print(p.stdout, file=sys.stderr)
    return p.returncode


def write_reports(rows: List[RunRow], report_path: str, csv_path: str, suite: str, depths: str) -> None:
    os.makedirs(os.path.dirname(report_path) or ".", exist_ok=True)
    os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("lmr/lmp/rfp factorial scan\n")
        f.write(f"suite={suite}\n")
        f.write(f"depths={depths}\n\n")
        f.write("variant\tlmr\tlmp\trfp\tlmr_index_min\tlmr_depth_min\tlmr_base_reduction\tlmr_extra_non_improving\tdepth\thits\ttotal\trc\n")
        for r in rows:
            f.write(
                f"{r.variant}\t{r.lmr}\t{r.lmp}\t{r.rfp}\t{r.lmr_index_min}\t{r.lmr_depth_min}\t"
                f"{r.lmr_base_reduction}\t{r.lmr_extra_non_improving}\t{r.depth}\t{r.hits}\t{r.total}\t{r.rc}\n"
            )
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "variant", "lmr", "lmp", "rfp", "lmr_index_min", "lmr_depth_min",
            "lmr_base_reduction", "lmr_extra_non_improving", "depth", "hits", "total", "rc"
        ])
        for r in rows:
            w.writerow([
                r.variant, r.lmr, r.lmp, r.rfp, r.lmr_index_min, r.lmr_depth_min,
                r.lmr_base_reduction, r.lmr_extra_non_improving, r.depth, r.hits, r.total, r.rc
            ])


def main() -> int:
    args = parse_args()
    depths = [int(x.strip()) for x in args.depths.split(",") if x.strip()]
    use_time = args.movetime > 0
    run_label = f"movetime={args.movetime}ms" if use_time else args.depths
    rows: List[RunRow] = []

    if args.lmr_param_sweep:
        combos = [
            (1, args.lmp, args.rfp, idx_min, dep_min, base_red, extra_non_imp)
            for idx_min, dep_min, base_red, extra_non_imp in product(
                parse_int_list(args.lmr_index_min),
                parse_int_list(args.lmr_depth_min),
                parse_int_list(args.lmr_base_reduction),
                parse_int_list(args.lmr_extra_non_improving),
            )
        ]
    else:
        combos = [
            (lmr, lmp, rfp, 4, 3, 1, 1)
            for lmr in (0, 1)
            for lmp in (0, 1)
            for rfp in (0, 1)
        ]

    try:
        for lmr, lmp, rfp, idx_min, dep_min, base_red, extra_non_imp in combos:
            name = variant_name(lmr, lmp, rfp)
            if args.lmr_param_sweep:
                name = (
                    f"{name}_idx{idx_min}_dep{dep_min}_base{base_red}_nimp{extra_non_imp}"
                )
            defs = defines(lmr, lmp, rfp)
            defs += (
                f" -DLMR_INDEX_MIN={idx_min} -DLMR_DEPTH_MIN={dep_min}"
                f" -DLMR_BASE_REDUCTION={base_red} -DLMR_EXTRA_NON_IMPROVING={extra_non_imp}"
            )
            print(f"building {name} ...")
            if build_variant(name, defs) != 0:
                fill_depth = args.movetime if use_time else (depths[0] if depths else 0)
                rows.append(RunRow(name, lmr, lmp, rfp, idx_min, dep_min, base_red, extra_non_imp,
                                   fill_depth, 0, 0, 2))
                write_reports(rows, args.report, args.csv, args.suite, run_label)
                continue
            if use_time:
                print(f"running {name} movetime={args.movetime}ms ...")
                rc, hits, total, _ = suite_score(name, 0, args.suite, args.timeout,
                                                 movetime_ms=args.movetime)
                rows.append(RunRow(name, lmr, lmp, rfp, idx_min, dep_min, base_red, extra_non_imp,
                                   args.movetime, hits, total, rc))
                print(f"  score={hits}/{total} rc={rc}")
                write_reports(rows, args.report, args.csv, args.suite, run_label)
            else:
                for d in depths:
                    print(f"running {name} depth={d} ...")
                    rc, hits, total, _ = suite_score(name, d, args.suite, args.timeout)
                    rows.append(RunRow(name, lmr, lmp, rfp, idx_min, dep_min, base_red, extra_non_imp,
                                       d, hits, total, rc))
                    print(f"  score={hits}/{total} rc={rc}")
                    write_reports(rows, args.report, args.csv, args.suite, run_label)
    except KeyboardInterrupt:
        print("interrupted: partial report written")
        return 130
    finally:
        write_reports(rows, args.report, args.csv, args.suite, run_label)
        print(f"report: {args.report}")
        print(f"csv:    {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
