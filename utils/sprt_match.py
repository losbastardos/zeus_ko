#!/usr/bin/env python3
"""Run a cutechess-cli SPRT match between two UCI engines.

Example:
  python3 utils/sprt_match.py \
    --new ./chess-static \
    --base /run/current-system/sw/bin/stockfish \
    --games 200 --concurrency 2 --tc 10+0.1 \
    --sprt "elo0=0 elo1=8 alpha=0.05 beta=0.05" \
    --pgnout /tmp/sprt.pgn
"""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from typing import List


def build_cmd(args: argparse.Namespace) -> List[str]:
    cmd: List[str] = ["cutechess-cli"]

    cmd += [
        "-engine",
        f"name=NEW",
        f"cmd={args.new}",
        "proto=uci",
        f"option.Hash={args.hash_mb}",
    ]
    if args.new_ownbook_option:
        cmd.append("option.OwnBook=false")

    cmd += [
        "-engine",
        f"name=BASE",
        f"cmd={args.base}",
        "proto=uci",
        f"option.Hash={args.hash_mb}",
    ]
    if args.base_ownbook_option:
        cmd.append("option.OwnBook=false")

    cmd += ["-each", "proto=uci", f"tc={args.tc}"]
    cmd += ["-concurrency", str(args.concurrency)]
    cmd += ["-games", str(args.games)]
    cmd += ["-repeat"]
    if args.srand is not None:
        cmd += ["-srand", str(args.srand)]

    if args.openings:
        cmd += [
            "-openings",
            f"file={args.openings}",
            f"format={args.openings_format}",
            f"order={args.openings_order}",
            f"plies={args.openings_plies}",
            "start=1",
        ]

    if args.sprt:
        cmd += ["-sprt"] + shlex.split(args.sprt)

    if args.pgnout:
        cmd += ["-pgnout", args.pgnout]

    return cmd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run cutechess SPRT automation")
    parser.add_argument("--new", required=True, help="path to tested engine")
    parser.add_argument("--base", required=True, help="path to baseline engine")
    parser.add_argument("--games", type=int, default=200, help="max number of games")
    parser.add_argument("--concurrency", type=int, default=2, help="parallel game threads")
    parser.add_argument("--tc", default="10+0.1", help="time control for -each tc=")
    parser.add_argument("--hash-mb", type=int, default=64, help="Hash option for both engines")
    parser.add_argument(
        "--sprt",
        default="elo0=0 elo1=8 alpha=0.05 beta=0.05",
        help="SPRT parameters for cutechess -sprt",
    )
    parser.add_argument(
        "--new-ownbook-option",
        action="store_true",
        default=True,
        help="send option.OwnBook=false to NEW engine (default: on)",
    )
    parser.add_argument(
        "--no-new-ownbook-option",
        action="store_false",
        dest="new_ownbook_option",
        help="do not send OwnBook option to NEW engine",
    )
    parser.add_argument(
        "--base-ownbook-option",
        action="store_true",
        default=False,
        help="send option.OwnBook=false to BASE engine (default: off)",
    )
    parser.add_argument(
        "--openings",
        default="",
        help="optional openings file (PGN/EPD) for better coverage",
    )
    parser.add_argument(
        "--openings-format",
        choices=["pgn", "epd"],
        default="pgn",
        help="openings file format",
    )
    parser.add_argument(
        "--openings-order",
        choices=["random", "sequential"],
        default="random",
        help="openings traversal order (random or sequential)",
    )
    parser.add_argument("--openings-plies", type=int, default=8, help="opening plies")
    parser.add_argument(
        "--srand",
        type=int,
        default=None,
        help="fixed cutechess RNG seed for reproducible runs",
    )
    parser.add_argument("--pgnout", default="", help="optional output PGN path")
    parser.add_argument("--dry-run", action="store_true", help="print command and exit")
    return parser.parse_args()


def validate_inputs(args: argparse.Namespace) -> None:
    if not os.path.exists(args.new):
        raise FileNotFoundError(f"--new engine not found: {args.new}")
    if not os.path.exists(args.base):
        raise FileNotFoundError(f"--base engine not found: {args.base}")
    if args.openings and not os.path.exists(args.openings):
        raise FileNotFoundError(f"--openings file not found: {args.openings}")
    if args.games <= 0:
        raise ValueError("--games must be > 0")
    if args.concurrency <= 0:
        raise ValueError("--concurrency must be > 0")


def main() -> int:
    args = parse_args()
    try:
        validate_inputs(args)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    cmd = build_cmd(args)
    print("command:")
    print(" ".join(shlex.quote(x) for x in cmd))

    if args.dry_run:
        return 0

    proc = subprocess.run(cmd)
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
