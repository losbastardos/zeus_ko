#!/usr/bin/env python3
"""Query exact Syzygy WDL/DTZ for a FEN via python-chess."""

from __future__ import annotations

import argparse
import sys

import chess
import chess.syzygy


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Syzygy oracle query")
    p.add_argument("--syzygy-path", default="tb", help="Path to Syzygy tables")
    p.add_argument("--fen", required=True, help="FEN to probe")
    p.add_argument("--expect-wdl", type=int, default=None, help="Optional expected WDL")
    p.add_argument("--expect-dtz", type=int, default=None, help="Optional expected DTZ")
    p.add_argument(
        "--table-only",
        action="store_true",
        help="Use direct table probes (probe_wdl_table/probe_dtz_table) instead of recursive probes",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    try:
        board = chess.Board(args.fen)
    except ValueError as exc:
        print(f"error: invalid fen: {exc}", file=sys.stderr)
        return 2

    try:
        with chess.syzygy.open_tablebase(args.syzygy_path) as tb:
            if args.table_only:
                wdl = tb.probe_wdl_table(board)
                # probe_dtz_table returns tuple where first item is DTZ.
                dtz, _ = tb.probe_dtz_table(board, wdl)
            else:
                try:
                    wdl = tb.probe_wdl(board)
                    dtz = tb.probe_dtz(board)
                except chess.syzygy.MissingTableError:
                    # Fallback for partial table sets: use direct table probing.
                    wdl = tb.probe_wdl_table(board)
                    dtz, _ = tb.probe_dtz_table(board, wdl)
    except Exception as exc:
        print(f"error: syzygy probe failed: {exc}", file=sys.stderr)
        return 2

    print(f"wdl={wdl} dtz={dtz} fen={args.fen}")

    if args.expect_wdl is not None and wdl != args.expect_wdl:
        print(f"mismatch: expected wdl={args.expect_wdl}, got {wdl}", file=sys.stderr)
        return 1
    if args.expect_dtz is not None and dtz != args.expect_dtz:
        print(f"mismatch: expected dtz={args.expect_dtz}, got {dtz}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
