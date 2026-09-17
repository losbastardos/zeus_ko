#!/usr/bin/env python3
"""Run native suite command for multiple depths and summarize score trend."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from dataclasses import dataclass
from typing import List

RESULT_RE = re.compile(
    r"suite result cases=(\d+) hits=(\d+) misses=(\d+) hitrate%=(\d+) score=([0-9]+/[0-9]+) nodes=(\d+) time_ms=(\d+)"
)


@dataclass
class Row:
    depth: int
    cases: int
    hits: int
    misses: int
    hitrate: int
    score: str
    nodes: int
    time_ms: int


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Depth trend scan using native suite command")
    p.add_argument("--engine", default="./chess-static", help="engine binary")
    p.add_argument("--suite", default="tests/suites/external/arasan2026.epd", help="suite file")
    p.add_argument("--depths", default="4,5,6,7,8", help="comma-separated depths")
    p.add_argument("--timeout", default="1200s", help="timeout for each run")
    p.add_argument("--report", default="tests/reports/suite_depth_scan.txt", help="output report")
    return p.parse_args()


def run_depth(engine: str, suite: str, depth: int, timeout: str) -> Row:
    cmd = (
        "timeout {timeout} sh -c 'printf "
        "\"uci\\nsuite {suite} {depth}\\nquit\\n\" | {engine} --uci'"
    ).format(timeout=timeout, suite=suite, depth=depth, engine=engine)

    proc = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = proc.stdout

    m = RESULT_RE.search(out)
    if not m:
        raise RuntimeError(f"depth {depth}: suite result line not found")

    return Row(
        depth=depth,
        cases=int(m.group(1)),
        hits=int(m.group(2)),
        misses=int(m.group(3)),
        hitrate=int(m.group(4)),
        score=m.group(5),
        nodes=int(m.group(6)),
        time_ms=int(m.group(7)),
    )


def main() -> int:
    args = parse_args()
    depths = [int(x.strip()) for x in args.depths.split(",") if x.strip()]
    rows: List[Row] = []

    for d in depths:
        row = run_depth(args.engine, args.suite, d, args.timeout)
        rows.append(row)
        print(f"depth={row.depth} score={row.score} hits={row.hits}/{row.cases} time_ms={row.time_ms}")

    os.makedirs(os.path.dirname(args.report) or ".", exist_ok=True)
    with open(args.report, "w", encoding="utf-8") as f:
        f.write("suite depth scan\n")
        f.write(f"engine={args.engine}\n")
        f.write(f"suite={args.suite}\n\n")
        f.write("depth\thits\tcases\tscore\thitrate\tnodes\ttime_ms\n")
        for r in rows:
            f.write(
                f"{r.depth}\t{r.hits}\t{r.cases}\t{r.score}\t{r.hitrate}%\t{r.nodes}\t{r.time_ms}\n"
            )

    print(f"report: {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
