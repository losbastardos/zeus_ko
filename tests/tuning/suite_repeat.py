#!/usr/bin/env python3
"""Run native suite command repeatedly and summarize score variance."""

from __future__ import annotations

import argparse
import os
import re
import statistics
import subprocess
from dataclasses import dataclass
from typing import List

RESULT_RE = re.compile(
    r"suite result cases=(\d+) hits=(\d+) misses=(\d+) hitrate%=(\d+) score=([0-9]+/[0-9]+) nodes=(\d+) time_ms=(\d+)"
)


@dataclass
class RunResult:
    idx: int
    hits: int
    cases: int
    score: str
    nodes: int
    time_ms: int


def write_report(path: str, engine: str, suite: str, depth: int, runs: int, rows: List[RunResult]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)

    with open(path, "w", encoding="utf-8") as f:
        f.write("suite repeat\n")
        f.write(f"engine={engine}\n")
        f.write(f"suite={suite}\n")
        f.write(f"depth={depth}\n")
        f.write(f"runs={runs}\n\n")
        f.write("run\thits\tcases\tscore\tnodes\ttime_ms\n")
        for r in rows:
            f.write(f"{r.idx}\t{r.hits}\t{r.cases}\t{r.score}\t{r.nodes}\t{r.time_ms}\n")

        if not rows:
            return

        hits = [r.hits for r in rows]
        avg_hits = statistics.mean(hits)
        med_hits = statistics.median(hits)
        min_hits = min(hits)
        max_hits = max(hits)
        stdev_hits = statistics.pstdev(hits)

        f.write("\n")
        f.write(f"avg_hits={avg_hits:.3f}\n")
        f.write(f"median_hits={med_hits:.3f}\n")
        f.write(f"min_hits={min_hits}\n")
        f.write(f"max_hits={max_hits}\n")
        f.write(f"stdev_hits={stdev_hits:.3f}\n")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Repeat native suite and summarize noise")
    p.add_argument("--engine", default="./chess-static", help="engine binary path")
    p.add_argument("--suite", default="tests/suites/external/arasan2026.epd", help="suite file")
    p.add_argument("--depth", type=int, default=6, help="suite depth")
    p.add_argument("--runs", type=int, default=5, help="number of repeated runs")
    p.add_argument("--timeout", default="900s", help="timeout per run")
    p.add_argument("--report", default="tests/reports/suite_repeat.txt", help="output report path")
    return p.parse_args()


def run_once(engine: str, suite: str, depth: int, timeout: str) -> RunResult:
    cmd = (
        f"timeout {timeout} sh -c 'printf \"uci\\nsuite {suite} {depth}\\nquit\\n\" | {engine} --uci'"
    )
    proc = subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        raise RuntimeError(f"suite command failed with rc={proc.returncode}")

    m = RESULT_RE.search(proc.stdout)
    if not m:
        raise RuntimeError("suite result line not found")

    hits = int(m.group(2))
    cases = int(m.group(1))
    score = m.group(5)
    nodes = int(m.group(6))
    time_ms = int(m.group(7))
    return RunResult(idx=0, hits=hits, cases=cases, score=score, nodes=nodes, time_ms=time_ms)


def main() -> int:
    args = parse_args()
    rows: List[RunResult] = []
    exit_code = 0

    try:
        for i in range(1, args.runs + 1):
            r = run_once(args.engine, args.suite, args.depth, args.timeout)
            r.idx = i
            rows.append(r)
            write_report(args.report, args.engine, args.suite, args.depth, args.runs, rows)
            print(f"run={i} score={r.score} nodes={r.nodes} time_ms={r.time_ms}")
    except KeyboardInterrupt:
        exit_code = 130
        print("interrupted: partial report written")

    write_report(args.report, args.engine, args.suite, args.depth, args.runs, rows)

    if rows:
        hits = [r.hits for r in rows]
        avg_hits = statistics.mean(hits)
        med_hits = statistics.median(hits)
        min_hits = min(hits)
        max_hits = max(hits)
        stdev_hits = statistics.pstdev(hits)
        print(f"summary avg={avg_hits:.3f} median={med_hits:.3f} min={min_hits} max={max_hits} stdev={stdev_hits:.3f}")

    print(f"report: {args.report}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
