#!/usr/bin/env python3
"""Per-step walk trace pre Dual-AI DTZ debug (python ground truth).

Pouzitie:
    python3 dtz_trace.py "<fen>" [table.rtbz ...]

Vypise idx, raw_symbol a jednotlive kroky child traversalu
(step | w_off | s1 | s2 | litidx | symlen(s1)) zo scratch syzygy.py.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chess  # noqa: E402
import syzygy  # noqa: E402


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)

    fen = sys.argv[1]
    board = chess.Board(fen)

    syzygy.TRACE_WALK = []

    tb = syzygy.Tablebase(max_fds=4)
    tb.add_directory("tb", load_wdl=True, load_dtz=True)

    # WDL probe pred DTZ je OK - TRACE_WALK zaznamenava len DtzTable walk.
    try:
        res = tb.probe_dtz(board)
        print(f"probe_dtz={res}")
    except Exception as exc:  # noqa: BLE001
        print(f"probe_dtz exception: {exc!r}")

    dbg = syzygy.DEBUG_LAST_DTZ
    if dbg:
        print(f"idx={dbg['idx']} raw_symbol={dbg['raw_symbol']} "
              f"final_res={dbg['final_res']} bside={dbg['bside']} flags={dbg['flags']}")

    steps = syzygy.TRACE_WALK or []
    print(f"steps={len(steps)}")
    for kind, step, w_off, s1, s2, litidx, s1_len in steps:
        print(f"step={step} w_off={w_off} s1={s1} s2={s2} lit={litidx} symlen_s1={s1_len}")


if __name__ == "__main__":
    main()
