#!/usr/bin/env python3
"""Compile-time search heuristic ablation scan for chess-static.

Builds engine with selected -D toggles and runs native suite at chosen depths.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from typing import Dict, List

RESULT_RE = re.compile(r"score=([0-9]+/[0-9]+)")

HEUR_DEFS: Dict[str, str] = {
    "PROBCUT": "-DENABLE_PROBCUT=0",
    "RFP": "-DENABLE_RFP=0",
    "RAZOR": "-DENABLE_RAZOR=0",
    "NULL": "-DENABLE_NULL_PRUNE=0",
    "LMP": "-DENABLE_LMP=0",
    "FUTILITY": "-DENABLE_FUTILITY=0",
    "LMR": "-DENABLE_LMR=0",
    "SINGULAR": "-DENABLE_SINGULAR=0",
}


@dataclass
class RunRow:
    variant: str
    depth: int
    score: str
    rc: int


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Search heuristic ablation scan")
    p.add_argument("--suite", default="tests/suites/external/arasan2026.epd")
    p.add_argument("--depths", default="6,8")
    p.add_argument("--heuristics", default="LMR,NULL,LMP,RFP")
    p.add_argument("--report", default="tests/reports/search_ablation_scan.txt")
    p.add_argument("--timeout", default="900s")
    return p.parse_args()


def write_report(path: str, suite: str, depths: str, heuristics: List[str], rows: List[RunRow]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("search ablation scan\n")
        f.write(f"suite={suite}\n")
        f.write(f"depths={depths}\n")
        f.write(f"heuristics={','.join(heuristics)}\n\n")
        f.write("variant\tdepth\tscore\trc\n")
        for r in rows:
            f.write(f"{r.variant}\t{r.depth}\t{r.score}\t{r.rc}\n")


def run_cmd(cmd: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def suite_score(depth: int, suite: str, timeout_s: str) -> tuple[int, str]:
    cmd = (
        f"timeout {timeout_s} sh -c 'printf \"uci\\nsuite {suite} {depth}\\nquit\\n\" | ./chess-static --uci'"
    )
    p = run_cmd(cmd)
    m = RESULT_RE.search(p.stdout)
    score = m.group(1) if m else "-"
    return p.returncode, score


def build_with(defines: str) -> int:
    # clean guarantees object rebuild with new preprocessor defines
    p = run_cmd(f"make clean && make chess-static EXTRA_DEFINES={shlex.quote(defines)}")
    if p.returncode != 0:
        print(p.stdout)
    return p.returncode


def main() -> int:
    args = parse_args()
    depths = [int(x.strip()) for x in args.depths.split(",") if x.strip()]
    heuristics = [h.strip().upper() for h in args.heuristics.split(",") if h.strip()]

    rows: List[RunRow] = []

    exit_code = 0
    try:
        # baseline
        if build_with("") != 0:
            return 2
        for d in depths:
            rc, score = suite_score(d, args.suite, args.timeout)
            rows.append(RunRow("BASELINE", d, score, rc))
            print(f"BASELINE depth={d} score={score} rc={rc}")
            write_report(args.report, args.suite, args.depths, heuristics, rows)

        for h in heuristics:
            define = HEUR_DEFS.get(h)
            if not define:
                print(f"skip unknown heuristic: {h}")
                continue
            if build_with(define) != 0:
                rows.append(RunRow(h, -1, "BUILD_FAIL", 2))
                write_report(args.report, args.suite, args.depths, heuristics, rows)
                continue
            for d in depths:
                rc, score = suite_score(d, args.suite, args.timeout)
                rows.append(RunRow(h, d, score, rc))
                print(f"{h} depth={d} score={score} rc={rc}")
                write_report(args.report, args.suite, args.depths, heuristics, rows)
    except KeyboardInterrupt:
        print("interrupted: partial report written")
        exit_code = 130
    finally:
        write_report(args.report, args.suite, args.depths, heuristics, rows)
        print(f"report: {args.report}")
        # restore baseline build
        _ = build_with("")

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
