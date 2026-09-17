#!/usr/bin/env python3
"""Run temporary eval_tune overrides for fast tuning trials.

Workflow:
1) backup src/eval_tune.inc
2) apply NAME=VALUE overrides to `equ` constants
3) run build and optional gate command
4) always restore original file (unless --keep-changes)
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from typing import Dict, List, Tuple


EQ_RE = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s+equ\s+)([^;\n]+)(.*)$")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Temporary eval_tune override runner")
    p.add_argument("--overrides", required=True, help="text file with NAME=VALUE lines")
    p.add_argument("--eval-tune", default="src/eval_tune.inc", help="path to eval_tune include")
    p.add_argument("--build-cmd", default="make chess-static", help="build command")
    p.add_argument(
        "--gate-cmd",
        default="make roadmap-p0 CANDIDATE=./chess-static BASELINE=./chess-static",
        help="optional gate/A-B command",
    )
    p.add_argument("--run-gate", type=int, default=0, help="1=run gate-cmd after build")
    p.add_argument("--keep-changes", type=int, default=0, help="1=do not restore eval_tune file")
    return p.parse_args()


def load_overrides(path: str) -> Dict[str, str]:
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    out: Dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ValueError(f"invalid override line (expected NAME=VALUE): {line}")
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip()
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
                raise ValueError(f"invalid override name: {k}")
            if not re.match(r"^-?[0-9]+$", v):
                raise ValueError(f"invalid override integer value for {k}: {v}")
            out[k] = v
    if not out:
        raise ValueError("no overrides loaded")
    return out


def apply_overrides(text: str, overrides: Dict[str, str]) -> Tuple[str, List[Tuple[str, str, str]]]:
    found = set()
    changes: List[Tuple[str, str, str]] = []
    out_lines = []

    for raw in text.splitlines(keepends=True):
        has_nl = raw.endswith("\n")
        line = raw[:-1] if has_nl else raw

        m = EQ_RE.match(line)
        if not m:
            out_lines.append(raw)
            continue

        indent, name, mid, value, tail = m.groups()
        if name not in overrides:
            out_lines.append(raw)
            continue

        old_val = value.strip()
        new_val = overrides[name]
        found.add(name)

        if old_val != new_val:
            changes.append((name, old_val, new_val))

        new_line = f"{indent}{name}{mid}{new_val}{tail}"
        if has_nl:
            new_line += "\n"
        out_lines.append(new_line)

    missing = sorted(set(overrides.keys()) - found)
    if missing:
        raise KeyError(f"override constants not found in eval_tune: {', '.join(missing)}")

    return "".join(out_lines), changes


def run_cmd(cmd: str) -> int:
    proc = subprocess.run(cmd, shell=True)
    return proc.returncode


def main() -> int:
    args = parse_args()

    overrides = load_overrides(args.overrides)
    if not os.path.exists(args.eval_tune):
        print(f"error: eval_tune not found: {args.eval_tune}", file=sys.stderr)
        return 2

    with open(args.eval_tune, "r", encoding="utf-8") as f:
        original = f.read()

    backup = args.eval_tune + ".bak.texel_trial"
    shutil.copyfile(args.eval_tune, backup)

    applied = False
    try:
        patched, changes = apply_overrides(original, overrides)
        with open(args.eval_tune, "w", encoding="utf-8") as f:
            f.write(patched)
        applied = True

        print("texel trial overrides applied")
        for name, old, new in changes:
            print(f"- {name}: {old} -> {new}")
        if not changes:
            print("- no value changes (all equal)")

        rc = run_cmd(args.build_cmd)
        if rc != 0:
            print(f"error: build command failed ({rc})", file=sys.stderr)
            return rc

        if args.run_gate == 1:
            rc = run_cmd(args.gate_cmd)
            if rc != 0:
                print(f"error: gate command failed ({rc})", file=sys.stderr)
                return rc

        print("texel trial done")
        return 0
    finally:
        if args.keep_changes != 1 and applied:
            shutil.copyfile(backup, args.eval_tune)
            print("eval_tune restored")
        if os.path.exists(backup):
            os.remove(backup)


if __name__ == "__main__":
    raise SystemExit(main())
