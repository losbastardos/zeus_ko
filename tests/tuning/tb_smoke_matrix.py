#!/usr/bin/env python3
"""Run a small Syzygy TB smoke matrix through UCI tbtest output."""

from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict


TBTEST_RE = re.compile(r"\btbtest\b", re.IGNORECASE)
KV_RE = re.compile(r"([a-zA-Z_]+)=([^\s]+)")


@dataclass(frozen=True)
class Case:
    name: str
    position_cmd: str
    expect_pieces: int
    expect_wdl_found: bool
    expect_dtz_found: bool


CASES = [
    Case(
        name="startpos_no_tb",
        position_cmd="position startpos",
        expect_pieces=32,
        expect_wdl_found=False,
        expect_dtz_found=False,
    ),
    Case(
        name="kqvk_white",
        position_cmd="position fen 8/8/8/8/8/8/4K3/k6Q w - - 0 1",
        expect_pieces=3,
        expect_wdl_found=True,
        expect_dtz_found=True,
    ),
    Case(
        name="kvqk_black",
        position_cmd="position fen q6k/4k3/8/8/8/8/8/8 b - - 0 1",
        expect_pieces=3,
        expect_wdl_found=True,
        expect_dtz_found=True,
    ),
    Case(
        name="kbvk_draw",
        position_cmd="position fen 8/8/8/8/8/8/4K3/k6B w - - 0 1",
        expect_pieces=3,
        expect_wdl_found=True,
        expect_dtz_found=True,
    ),
    Case(
        name="knvk_draw",
        position_cmd="position fen 8/8/8/8/8/8/4K3/k6N w - - 0 1",
        expect_pieces=3,
        expect_wdl_found=True,
        expect_dtz_found=True,
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run TB smoke matrix via UCI tbtest")
    parser.add_argument("--engine", default="./chess-static", help="Engine binary path")
    parser.add_argument("--syzygy-path", default="tb", help="SyzygyPath value")
    parser.add_argument("--timeout", type=int, default=30, help="Per-case timeout in seconds")
    parser.add_argument("--report", default="tests/reports/tb_smoke_matrix.txt", help="Text report output")
    return parser.parse_args()


def run_case(engine: str, syzygy_path: str, timeout_sec: int, case: Case) -> Dict[str, str]:
    script = (
        "uci\n"
        f"setoption name SyzygyPath value {syzygy_path}\n"
        f"{case.position_cmd}\n"
        "tbtest\n"
        "quit\n"
    )
    proc = subprocess.run(
        [engine, "--uci"],
        input=script,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
        check=False,
    )

    tb_line = ""
    for line in proc.stdout.splitlines():
        if TBTEST_RE.search(line):
            tb_line = line.strip()

    if not tb_line:
        raise RuntimeError(f"No tbtest output for case {case.name}")

    parsed: Dict[str, str] = {}
    for key, value in KV_RE.findall(tb_line):
        parsed[key] = value
    parsed["_line"] = tb_line
    return parsed


def as_int(values: Dict[str, str], key: str) -> int:
    return int(values.get(key, "-999999"))


def check_case(case: Case, values: Dict[str, str]) -> tuple[bool, str]:
    pieces = as_int(values, "pieces")
    wdl = as_int(values, "wdl")
    dtz = as_int(values, "dtz")
    map_bytes = as_int(values, "map_bytes")
    path = values.get("path", "")

    if pieces != case.expect_pieces:
        return False, f"pieces mismatch: got {pieces}, expected {case.expect_pieces}"

    if case.expect_wdl_found:
        if wdl == 255:
            return False, "wdl expected found but got TB_NOT_FOUND"
    else:
        if wdl != 255:
            return False, f"wdl expected TB_NOT_FOUND but got {wdl}"

    if case.expect_dtz_found:
        if dtz == 255:
            return False, "dtz expected found but got TB_NOT_FOUND"
        if map_bytes <= 0:
            return False, f"dtz expected mapped file but map_bytes={map_bytes}"
        if not path.endswith(".rtbz"):
            return False, f"dtz expected .rtbz path but got '{path}'"
    else:
        if dtz != 255:
            return False, f"dtz expected TB_NOT_FOUND but got {dtz}"

    return True, "ok"


def main() -> int:
    args = parse_args()
    report_lines = []
    report_lines.append("tb smoke matrix")
    report_lines.append(f"engine={args.engine}")
    report_lines.append(f"syzygy_path={args.syzygy_path}")
    report_lines.append("")

    failures = 0
    for case in CASES:
        try:
            values = run_case(args.engine, args.syzygy_path, args.timeout, case)
            ok, msg = check_case(case, values)
            status = "PASS" if ok else "FAIL"
            report_lines.append(f"{status} {case.name}: {msg}")
            report_lines.append(f"  {values.get('_line', '')}")
            if not ok:
                failures += 1
        except Exception as exc:
            failures += 1
            report_lines.append(f"FAIL {case.name}: exception: {exc}")

    report_lines.append("")
    report_lines.append(f"summary: failures={failures} cases={len(CASES)}")

    report_path = Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    print("\n".join(report_lines))
    print(f"report: {report_path}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
