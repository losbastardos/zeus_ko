#!/usr/bin/env python3
"""Annotate Texel CSV with engine eval_cp using UCI score output."""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional

MATE_CP = 32000


@dataclass
class Engine:
    path: str
    go: str
    proc: subprocess.Popen

    @classmethod
    def start(cls, path: str, go: str) -> "Engine":
        if not os.path.exists(path):
            raise FileNotFoundError(path)

        proc = subprocess.Popen(
            [path, "--uci"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        eng = cls(path=path, go=go, proc=proc)
        eng.send("uci")
        eng.wait_for("uciok")
        eng.send("setoption name OwnBook value false")
        eng.send("isready")
        eng.wait_for("readyok")
        return eng

    def send(self, line: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def readline(self) -> str:
        assert self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("engine stdout closed")
        return line.strip()

    def wait_for(self, token: str, max_lines: int = 4000) -> None:
        for _ in range(max_lines):
            line = self.readline()
            if line == token:
                return
        raise RuntimeError(f"engine did not emit {token}")

    def eval_cp(self, fen: str) -> int:
        self.send(f"position fen {fen}")
        self.send(f"go {self.go}")

        score: Optional[int] = None

        while True:
            line = self.readline()
            if line.startswith("info "):
                parsed = parse_score(line)
                if parsed is not None:
                    score = parsed
            elif line.startswith("bestmove"):
                break

        if score is None:
            raise RuntimeError("missing info score before bestmove")
        return score

    def close(self) -> None:
        try:
            self.send("quit")
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()


def parse_score(info_line: str) -> Optional[int]:
    toks = info_line.split()
    for i in range(len(toks) - 2):
        if toks[i] == "score" and toks[i + 1] == "cp":
            try:
                return int(toks[i + 2])
            except ValueError:
                return None
        if toks[i] == "score" and toks[i + 1] == "mate":
            try:
                mate = int(toks[i + 2])
            except ValueError:
                return None
            if mate > 0:
                return MATE_CP - min(1000, mate)
            if mate < 0:
                return -MATE_CP - max(-1000, mate)
            return 0
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Annotate Texel dataset with engine eval")
    parser.add_argument("--engine", required=True, help="engine binary path")
    parser.add_argument("--input", required=True, help="input CSV with fen/result columns")
    parser.add_argument("--out", required=True, help="output CSV with eval_cp")
    parser.add_argument("--go", default="depth 1", help="UCI go arguments")
    parser.add_argument("--max-rows", type=int, default=0, help="process only first N rows (0=all)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not os.path.exists(args.input):
        print(f"error: input not found: {args.input}", file=sys.stderr)
        return 2

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.input, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fields = reader.fieldnames or []

    needed = {"fen", "result"}
    if not needed.issubset(set(fields)):
        print("error: input CSV missing required columns fen/result", file=sys.stderr)
        return 3

    if args.max_rows > 0:
        rows = rows[: args.max_rows]

    engine = Engine.start(args.engine, args.go)
    done = 0
    try:
        for row in rows:
            fen = row.get("fen", "")
            row["eval_cp"] = str(engine.eval_cp(fen))
            done += 1
            if done % 25 == 0:
                print(f"processed: {done}")
    finally:
        engine.close()

    out_fields = list(fields)
    if "eval_cp" not in out_fields:
        out_fields.append("eval_cp")

    with open(args.out, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=out_fields)
        writer.writeheader()
        writer.writerows(rows)

    print("texel eval labeling done")
    print(f"- rows: {len(rows)}")
    print(f"- output: {args.out}")
    print(f"- go: {args.go}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
