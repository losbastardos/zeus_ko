#!/usr/bin/env python3
"""Exhaustive TB oracle compare for selected 3-piece variants.

Compares engine `tbtest` output against python-chess Syzygy oracle.

Semantics used here:
- WDL expected: table probe mapped to engine class (2/1/0 = win/draw/loss).
- DTZ expected: recursive signed DTZ (`probe_dtz`) on stored side only.
- Non-stored side: DTZ compare is skipped and engine should return
    `DTZ_UNSUPPORTED` sentinel.
"""

from __future__ import annotations

import argparse
import itertools
import re
import subprocess
import sys
from dataclasses import dataclass

import chess
import chess.syzygy

TBTEST_RE = re.compile(r"wdl=(-?\d+)\s+dtz=(-?\d+)")
DTZ_UNSUPPORTED = 32768

SIDE_RE = re.compile(r"^[KQRBN]+$")


@dataclass(frozen=True)
class VariantSpec:
    name: str
    white_extra: str | None
    black_extra: str | None


PIECE_BY_CHAR = {
    "Q": chess.QUEEN,
    "R": chess.ROOK,
    "B": chess.BISHOP,
    "N": chess.KNIGHT,
}


def parse_variants(raw: str) -> list[VariantSpec]:
    out: list[VariantSpec] = []
    seen: set[str] = set()
    for token in raw.split(","):
        name = token.strip()
        if not name:
            continue
        if "v" not in name:
            raise ValueError(f"unsupported variant: {name}")
        if name in seen:
            continue
        seen.add(name)

        left, right = name.split("v", 1)
        if not SIDE_RE.match(left) or not SIDE_RE.match(right):
            raise ValueError(f"unsupported variant: {name}")

        if left.count("K") != 1 or right.count("K") != 1:
            raise ValueError(f"unsupported variant (king count): {name}")

        white_non_king = left.replace("K", "")
        black_non_king = right.replace("K", "")

        if len(white_non_king) > 1 or len(black_non_king) > 1:
            raise ValueError(f"only 3-piece variants are supported: {name}")

        if white_non_king and white_non_king not in PIECE_BY_CHAR:
            raise ValueError(f"unsupported white piece in variant: {name}")
        if black_non_king and black_non_king not in PIECE_BY_CHAR:
            raise ValueError(f"unsupported black piece in variant: {name}")

        white_extra = white_non_king or None
        black_extra = black_non_king or None

        if (white_extra is None) == (black_extra is None):
            raise ValueError(f"only KXvK or KvKX variants are supported: {name}")

        out.append(VariantSpec(name=name, white_extra=white_extra, black_extra=black_extra))
    if not out:
        raise ValueError("no variants provided")
    return out


def kings_not_adjacent(wk: int, bk: int) -> bool:
    wf, wr = wk & 7, wk >> 3
    bf, br = bk & 7, bk >> 3
    return max(abs(wf - bf), abs(wr - br)) > 1


def oracle_wdl_to_engine(wdl: int) -> int:
    if wdl > 0:
        return 2
    if wdl < 0:
        return 0
    return 1


def start_engine(engine_path: str, syzygy_path: str) -> subprocess.Popen[str]:
    proc = subprocess.Popen(
        [engine_path, "--uci"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdin is not None
    assert proc.stdout is not None

    proc.stdin.write("uci\n")
    proc.stdin.flush()
    for line in proc.stdout:
        if line.strip() == "uciok":
            break

    proc.stdin.write(f"setoption name SyzygyPath value {syzygy_path}\n")
    proc.stdin.write("isready\n")
    proc.stdin.flush()
    for line in proc.stdout:
        if line.strip() == "readyok":
            break

    return proc


def stop_engine(proc: subprocess.Popen[str]) -> None:
    try:
        if proc.stdin:
            proc.stdin.write("quit\n")
            proc.stdin.flush()
    except Exception:
        pass
    proc.wait(timeout=5)


def probe_engine_tbtest(proc: subprocess.Popen[str], fen: str) -> tuple[int, int]:
    assert proc.stdin is not None
    assert proc.stdout is not None

    proc.stdin.write(f"position fen {fen}\n")
    proc.stdin.write("tbtest\n")
    proc.stdin.flush()

    for line in proc.stdout:
        if "tbtest" not in line:
            continue
        m = TBTEST_RE.search(line)
        if m:
            return int(m.group(1)), int(m.group(2))

    raise RuntimeError("engine output ended without tbtest line")


def iter_variant_positions(spec: VariantSpec):
    white_extra_piece = PIECE_BY_CHAR.get(spec.white_extra) if spec.white_extra else None
    black_extra_piece = PIECE_BY_CHAR.get(spec.black_extra) if spec.black_extra else None

    squares = range(64)
    for wk in squares:
        for bk in squares:
            if bk == wk:
                continue
            if not kings_not_adjacent(wk, bk):
                continue

            for extra_sq in squares:
                if extra_sq in (wk, bk):
                    continue

                board = chess.Board.empty()
                board.set_piece_at(wk, chess.Piece(chess.KING, chess.WHITE))
                board.set_piece_at(bk, chess.Piece(chess.KING, chess.BLACK))

                if white_extra_piece is not None:
                    board.set_piece_at(extra_sq, chess.Piece(white_extra_piece, chess.WHITE))
                elif black_extra_piece is not None:
                    board.set_piece_at(extra_sq, chess.Piece(black_extra_piece, chess.BLACK))
                else:
                    continue

                # Test both sides to move.
                for turn in (chess.WHITE, chess.BLACK):
                    board.turn = turn
                    board.castling_rights = chess.BB_EMPTY
                    board.ep_square = None
                    board.halfmove_clock = 0
                    board.fullmove_number = 1

                    # Keep only legal positions.
                    if not board.is_valid():
                        continue

                    yield board


def main() -> int:
    p = argparse.ArgumentParser(description="Exhaustive engine tbtest vs Syzygy oracle compare")
    p.add_argument("--engine", default="./chess-static", help="Engine binary")
    p.add_argument("--tb-dir", default="tb", help="Syzygy directory")
    p.add_argument("--all-positions", action="store_true", help="Exhaustive legal position sweep")
    p.add_argument("--variants", required=True, help="Comma-separated variants (e.g. KQvK,KvQK)")
    p.add_argument("--max-mismatches", type=int, default=200, help="Stop after this many mismatches")
    p.add_argument(
        "--dtz-unsupported",
        type=int,
        default=DTZ_UNSUPPORTED,
        help="Engine sentinel for DTZ on non-stored side",
    )
    args = p.parse_args()

    if not args.all_positions:
        print("error: only --all-positions mode is supported", file=sys.stderr)
        return 2

    try:
        variants = parse_variants(args.variants)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    mismatches = 0
    wdl_only_total = 0
    dtz_only_total = 0
    both_total = 0
    total = 0

    print("oracle_mode=wdl_table+dtz_recursive")

    proc = start_engine(args.engine, args.tb_dir)
    try:
        with chess.syzygy.open_tablebase(args.tb_dir) as tb:
            for spec in variants:
                variant_total = 0
                variant_mismatch = 0
                variant_wdl_only = 0
                variant_dtz_only = 0
                variant_both = 0
                print(f"variant={spec.name} start")

                for board in iter_variant_positions(spec):
                    fen = board.fen()
                    ew, ed = probe_engine_tbtest(proc, fen)

                    ow_raw = tb.probe_wdl_table(board)
                    od_table_raw, od_table_status = tb.probe_dtz_table(board, ow_raw)
                    stored_side = od_table_status == 1

                    ow = oracle_wdl_to_engine(ow_raw)

                    od_recursive = None
                    if stored_side:
                        try:
                            od_recursive = tb.probe_dtz(board)
                        except chess.syzygy.MissingTableError:
                            od_recursive = od_table_raw

                    total += 1
                    variant_total += 1

                    wdl_mismatch = ew != ow
                    if stored_side:
                        assert od_recursive is not None
                        dtz_mismatch = ed != od_recursive
                    else:
                        dtz_mismatch = False

                    unsupported_mismatch = (not stored_side) and (ed != args.dtz_unsupported)

                    if wdl_mismatch or dtz_mismatch or unsupported_mismatch:
                        mismatches += 1
                        variant_mismatch += 1
                        if unsupported_mismatch:
                            both_total += 1
                            variant_both += 1
                            mismatch_kind = "unsupported_sentinel"
                        elif wdl_mismatch and dtz_mismatch:
                            both_total += 1
                            variant_both += 1
                            mismatch_kind = "both"
                        elif wdl_mismatch:
                            wdl_only_total += 1
                            variant_wdl_only += 1
                            mismatch_kind = "wdl_only"
                        else:
                            dtz_only_total += 1
                            variant_dtz_only += 1
                            mismatch_kind = "dtz_only"

                        print(
                            "MISMATCH"
                            f" variant={spec.name}"
                            f" kind={mismatch_kind}"
                            f" engine={ew}/{ed}"
                            f" oracle_raw={ow_raw}/{od_table_raw}"
                            f" oracle_recursive_dtz={od_recursive}"
                            f" stored_side={int(stored_side)}"
                            f" expected={ow}/{od_recursive if stored_side else args.dtz_unsupported}"
                            f" fen={fen}"
                        )
                        if mismatches >= args.max_mismatches:
                            print("stop: max mismatches reached")
                            print(
                                "summary"
                                f" total={total}"
                                f" mismatches={mismatches}"
                                f" wdl_only={wdl_only_total}"
                                f" dtz_only={dtz_only_total}"
                                f" both={both_total}"
                            )
                            return 1

                    if variant_total % 25000 == 0:
                        print(
                            f"variant={spec.name} progress={variant_total}"
                            f" mismatches={variant_mismatch}"
                        )

                print(
                    f"variant={spec.name} done positions={variant_total}"
                    f" mismatches={variant_mismatch}"
                    f" wdl_only={variant_wdl_only}"
                    f" dtz_only={variant_dtz_only}"
                    f" both={variant_both}"
                )

    finally:
        stop_engine(proc)

    print(
        "summary"
        f" total={total}"
        f" mismatches={mismatches}"
        f" wdl_only={wdl_only_total}"
        f" dtz_only={dtz_only_total}"
        f" both={both_total}"
    )
    return 1 if mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
