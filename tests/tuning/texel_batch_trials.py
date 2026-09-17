#!/usr/bin/env python3
"""Run multiple texel-trial override files and summarize outcomes.

Each override file should contain NAME=VALUE lines.
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import re
import subprocess
import shlex
from dataclasses import dataclass
from typing import List

SCORE_RE = re.compile(r"score=([0-9]+/[0-9]+)")
ARASAN_RE = re.compile(r"Arasan depth\s+[0-9]+:\s+([0-9]+/[0-9]+)\s+\(min\s+[0-9]+\)")


@dataclass
class TrialResult:
    profile: str
    rc: int
    score: str
    gate_pass: bool


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Batch runner for texel-trial")
    p.add_argument("--profiles", default="tests/tuning/overrides/*.env", help="glob for override profiles")
    p.add_argument("--report", default="tests/reports/texel_batch_trials.txt", help="output report path")
    p.add_argument("--run-gate", type=int, default=1, help="1 = run roadmap gate in each trial")
    p.add_argument("--gate-cmd", default="make roadmap-p0 CANDIDATE=./chess-static BASELINE=./chess-static", help="gate command")
    p.add_argument("--build-cmd", default="make chess-static", help="build command")
    p.add_argument("--keep-changes", type=int, default=0, help="forwarded to texel-trial")
    p.add_argument("--strict", type=int, default=0, help="1 = nonzero exit when any profile fails")
    p.add_argument("--csv", default="", help="optional csv output path")
    return p.parse_args()


def expand_profiles(spec: str) -> List[str]:
    tokens: List[str] = []
    for t in shlex.split(spec):
        for part in t.split(","):
            part = part.strip()
            if part:
                tokens.append(part)

    out: List[str] = []
    for t in tokens:
        matches = sorted(glob.glob(t))
        if matches:
            out.extend(matches)
        elif os.path.exists(t):
            out.append(t)

    # unikaty pri zachovani poradia
    seen = set()
    uniq: List[str] = []
    for p in out:
        if p in seen:
            continue
        seen.add(p)
        uniq.append(p)
    return uniq


def run_trial(profile: str, args: argparse.Namespace) -> TrialResult:
    cmd = [
        "make",
        "texel-trial",
        f"OVERRIDES={profile}",
        f"RUN_GATE={args.run_gate}",
        f"GATE_CMD={args.gate_cmd}",
        f"BUILD_CMD={args.build_cmd}",
        f"KEEP_CHANGES={args.keep_changes}",
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = proc.stdout

    scores = SCORE_RE.findall(out)
    if scores:
        score = scores[-1]
    else:
        arasan = ARASAN_RE.findall(out)
        score = arasan[-1] if arasan else "-"
    gate_pass = "PASS: strength gate passed" in out

    return TrialResult(profile=profile, rc=proc.returncode, score=score, gate_pass=gate_pass)


def write_report(path: str, results: List[TrialResult]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("texel batch trials\n")
        f.write(f"cases={len(results)}\n\n")
        for r in results:
            status = "PASS" if r.gate_pass and r.rc == 0 else "FAIL"
            f.write(f"{status}\tprofile={r.profile}\trc={r.rc}\tscore={r.score}\n")


def write_csv(path: str, results: List[TrialResult]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["status", "profile", "rc", "score", "gate_pass"])
        for r in results:
            status = "PASS" if r.gate_pass and r.rc == 0 else "FAIL"
            w.writerow([status, r.profile, r.rc, r.score, int(r.gate_pass)])


def main() -> int:
    args = parse_args()
    profiles = expand_profiles(args.profiles)
    if not profiles:
        print(f"error: no profiles found for glob: {args.profiles}")
        return 2

    results: List[TrialResult] = []
    for p in profiles:
        r = run_trial(p, args)
        results.append(r)
        status = "PASS" if r.gate_pass and r.rc == 0 else "FAIL"
        print(f"[{status}] {p} rc={r.rc} score={r.score}")

    write_report(args.report, results)
    print(f"report: {args.report}")
    if args.csv:
        write_csv(args.csv, results)
        print(f"csv: {args.csv}")

    passes = sum(1 for r in results if r.gate_pass and r.rc == 0)
    print(f"summary: {passes}/{len(results)} pass")
    if args.strict == 1:
        return 0 if passes == len(results) else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
