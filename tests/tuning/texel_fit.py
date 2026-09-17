#!/usr/bin/env python3
"""Fit Texel logistic scale from eval_cp-labeled dataset."""

from __future__ import annotations

import argparse
import csv
import math
import os
from dataclasses import dataclass
from typing import List, Tuple


@dataclass
class Sample:
    eval_cp: float
    target: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Texel logistic fit over eval_cp dataset")
    parser.add_argument("--input", required=True, help="CSV with eval_cp,result")
    parser.add_argument("--report", required=True, help="output report path")
    parser.add_argument("--min-scale", type=float, default=40.0)
    parser.add_argument("--max-scale", type=float, default=1200.0)
    parser.add_argument("--steps", type=int, default=600)
    parser.add_argument("--clip-abs-cp", type=float, default=2000.0, help="clip abs(eval_cp) before fitting (0=off)")
    return parser.parse_args()


def parse_target(raw: str) -> float:
    if raw == "1.0":
        return 1.0
    if raw == "0.5":
        return 0.5
    if raw == "0.0":
        return 0.0
    return 0.5


def load_samples(path: str, clip_abs_cp: float) -> List[Sample]:
    with open(path, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    out: List[Sample] = []
    for r in rows:
        try:
            ev = float(r.get("eval_cp", ""))
        except ValueError:
            continue
        if clip_abs_cp > 0:
            ev = max(-clip_abs_cp, min(clip_abs_cp, ev))
        out.append(Sample(eval_cp=ev, target=parse_target(r.get("result", "0.5"))))
    return out


def predict(eval_cp: float, scale: float) -> float:
    x = max(-40.0, min(40.0, eval_cp / scale))
    return 1.0 / (1.0 + math.exp(-x))


def loss(samples: List[Sample], scale: float) -> Tuple[float, float]:
    eps = 1e-12
    ll = 0.0
    brier = 0.0
    n = len(samples)
    for s in samples:
        p = predict(s.eval_cp, scale)
        t = s.target
        ll += -(t * math.log(max(eps, p)) + (1.0 - t) * math.log(max(eps, 1.0 - p)))
        d = p - t
        brier += d * d
    if n == 0:
        return float("inf"), float("inf")
    return ll / n, brier / n


def grid_search(samples: List[Sample], lo: float, hi: float, steps: int):
    best_scale = lo
    best_ll = float("inf")
    best_brier = float("inf")

    for i in range(steps + 1):
        s = lo + (hi - lo) * (i / max(1, steps))
        ll, br = loss(samples, s)
        if ll < best_ll:
            best_scale = s
            best_ll = ll
            best_brier = br
    return best_scale, best_ll, best_brier


def write_report(path: str, samples: List[Sample], best_scale: float, best_ll: float, best_brier: float, args: argparse.Namespace) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    evals = [s.eval_cp for s in samples]
    t_white = sum(1 for s in samples if s.target == 1.0)
    t_draw = sum(1 for s in samples if s.target == 0.5)
    t_black = sum(1 for s in samples if s.target == 0.0)

    with open(path, "w", encoding="utf-8") as f:
        f.write("texel logistic fit\n")
        f.write(f"input={args.input}\n")
        f.write(f"samples={len(samples)}\n")
        if evals:
            f.write(f"eval_min={min(evals):.2f}\n")
            f.write(f"eval_max={max(evals):.2f}\n")
        f.write(f"target_white_win={t_white}\n")
        f.write(f"target_draw={t_draw}\n")
        f.write(f"target_black_win={t_black}\n")
        f.write(f"search_min_scale={args.min_scale:.3f}\n")
        f.write(f"search_max_scale={args.max_scale:.3f}\n")
        f.write(f"search_steps={args.steps}\n")
        f.write(f"clip_abs_cp={args.clip_abs_cp:.3f}\n")
        f.write("\n")
        f.write(f"best_scale={best_scale:.6f}\n")
        f.write(f"logloss={best_ll:.9f}\n")
        f.write(f"brier={best_brier:.9f}\n")


def main() -> int:
    args = parse_args()
    if not os.path.exists(args.input):
        print(f"error: input not found: {args.input}")
        return 2
    if args.min_scale <= 0 or args.max_scale <= args.min_scale:
        print("error: invalid scale bounds")
        return 3

    samples = load_samples(args.input, args.clip_abs_cp)
    if len(samples) < 10:
        print("error: too few samples (need >=10)")
        return 4

    best_scale, best_ll, best_brier = grid_search(samples, args.min_scale, args.max_scale, max(10, args.steps))
    write_report(args.report, samples, best_scale, best_ll, best_brier, args)

    print("texel fit complete")
    print(f"- samples: {len(samples)}")
    print(f"- best scale: {best_scale:.6f}")
    print(f"- logloss: {best_ll:.9f}")
    print(f"- brier: {best_brier:.9f}")
    print(f"- report: {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
