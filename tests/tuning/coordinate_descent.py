#!/usr/bin/env python3
"""Coordinate-descent (SPSA-lite) tuner over eval_tune.inc equ constants.

Greedy per-weight search: for each weight try +/- step, keep first direction
with paired-z improvement over current best labels. Builds and labels with the
engine at each step; reuses the current best labeled CSV for pairing.

Usage:
  python3 tests/tuning/coordinate_descent.py \
      --eval-tune src/eval_tune.inc --dataset tests/reports/texel_dataset.csv \
      --subset 15000 --rounds 1 --z-thresh -3.0 \
      --report tests/reports/coordinate_descent.csv --log tests/reports/coordinate_descent.log
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
import shutil
import subprocess
import sys

EQ_RE = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s+equ\s+)(-?[0-9]+)(.*)$")
MATE_CP = 32000


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Coordinate descent over eval_tune.inc")
    p.add_argument("--eval-tune", default="src/eval_tune.inc")
    p.add_argument("--dataset", default="tests/reports/texel_dataset.csv")
    p.add_argument("--subset", type=int, default=15000, help="positions per labeling")
    p.add_argument("--rounds", type=int, default=1)
    p.add_argument("--z-thresh", type=float, default=-3.0)
    p.add_argument("--build-cmd", default="make chess-static")
    p.add_argument("--engine", default="./chess-static")
    p.add_argument("--go", default="depth 1")
    p.add_argument("--report", default="tests/reports/coordinate_descent.csv")
    p.add_argument("--log", default="tests/reports/coordinate_descent.log")
    p.add_argument("--scale", type=float, default=231.4)
    p.add_argument("--only", default="", help="comma-separated weight names to tune (default: all)")
    return p.parse_args()


def log(msg: str, path: str) -> None:
    line = f"[{subprocess.check_output(['date', '+%H:%M:%S']).decode().strip()}] {msg}"
    print(line, flush=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def run(cmd: str) -> int:
    return subprocess.run(cmd, shell=True).returncode


def load_weights(path: str):
    weights = {}
    order = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = EQ_RE.match(line.rstrip("\n"))
            if m:
                name = m.group(2)
                weights[name] = int(m.group(4))
                order.append(name)
    return weights, order


def write_weights(path: str, weights, order) -> None:
    lines = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = EQ_RE.match(line.rstrip("\n"))
            if m and m.group(2) in weights:
                nl = "\n" if line.endswith("\n") else ""
                lines.append(f"{m.group(1)}{m.group(2)}{m.group(3)}{weights[m.group(2)]}{m.group(5)}{nl}")
            else:
                lines.append(line)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def make_subset(src: str, dst: str, n: int) -> None:
    with open(src, "r", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    head, data = rows[0], rows[1:]
    with open(dst, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(head)
        w.writerows(data[:n])


def label(engine: str, dataset: str, out: str, go: str) -> int:
    if run(f'make texel-label ENGINE={engine} IN={dataset} OUT={out} GO="{go}" >/dev/null 2>&1') != 0:
        return 1
    return 0


def load_labeled(path: str):
    d = {}
    with open(path, "r", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                d[r["fen"]] = (float(r["eval_cp"]), float(r["result"]))
            except Exception:
                continue
    return d


def per_position_loss(ev: float, res: float, scale: float) -> float:
    x = max(-40.0, min(40.0, ev / scale))
    pr = 1.0 / (1.0 + math.exp(-x))
    pr = min(1.0 - 1e-12, max(1e-12, pr))
    return -(res * math.log(pr) + (1.0 - res) * math.log(1.0 - pr))


def paired_z(best: dict, cand: dict, scale: float):
    common = [fen for fen in best if fen in cand]
    if not common:
        return None, 0
    diffs = [per_position_loss(*cand[f], scale) - per_position_loss(*best[f], scale) for f in common]
    n = len(diffs)
    mean = sum(diffs) / n
    var = sum((d - mean) ** 2 for d in diffs) / (n - 1)
    se = math.sqrt(var / n)
    return (mean / se if se > 0 else 0.0), n


def step_for(value: int) -> int:
    a = abs(value)
    if a >= 25:
        return max(2, round(a * 0.2))
    if a >= 8:
        return max(1, round(a * 0.25))
    return 1


def main() -> int:
    args = parse_args()
    weights, order = load_weights(args.eval_tune)
    if args.only:
        wanted = [w.strip() for w in args.only.split(",") if w.strip()]
        order = [w for w in order if w in wanted]
        missing = [w for w in wanted if w not in weights]
        if missing:
            print(f"error: unknown weights: {missing}", file=sys.stderr)
            return 2
    log(f"start: {len(order)} weights, subset={args.subset}, rounds={args.rounds}, z<={args.z_thresh}", args.log)

    backup = args.eval_tune + ".bak.coord"
    shutil.copyfile(args.eval_tune, backup)

    work = "/tmp/coord_descent"
    os.makedirs(work, exist_ok=True)
    subset_csv = f"{work}/subset.csv"
    make_subset(args.dataset, subset_csv, args.subset)

    accepted = []
    success = False
    try:
        # baseline labels
        base_labels = f"{work}/labels_best.csv"
        if run(f'make texel-label ENGINE={args.engine} IN={subset_csv} OUT={base_labels} GO="{args.go}" >/dev/null 2>&1') != 0:
            log("ERROR: baseline labeling failed", args.log)
            return 1
        best_map = load_labeled(base_labels)
        log(f"baseline labels: {len(best_map)}", args.log)

        rows = []
        for rnd in range(1, args.rounds + 1):
            for name in order:
                cur = weights[name]
                step = step_for(cur)
                improved = False
                for sign in (1, -1):
                    new_val = cur + sign * step
                    if new_val == cur:
                        continue
                    if new_val < 0 and cur >= 0:
                        continue
                    weights[name] = new_val
                    write_weights(args.eval_tune, weights, order)
                    if run(args.build_cmd + " >/dev/null 2>&1") != 0:
                        log(f"{name} {cur}->{new_val}: BUILD FAIL", args.log)
                        weights[name] = cur
                        continue
                    cand_labels = f"{work}/labels_cand.csv"
                    if label(args.engine, subset_csv, cand_labels, args.go) != 0:
                        log(f"{name} {cur}->{new_val}: LABEL FAIL", args.log)
                        weights[name] = cur
                        continue
                    z, n = paired_z(best_map, load_labeled(cand_labels), args.scale)
                    log(f"r{rnd} {name} {cur}->{new_val}: z={z:+.2f} (n={n})", args.log)
                    rows.append({"round": rnd, "name": name, "from": cur, "to": new_val, "z": f"{z:+.3f}", "accepted": int(z is not None and z <= args.z_thresh)})
                    if z is not None and z <= args.z_thresh:
                        shutil.copyfile(cand_labels, base_labels)
                        best_map = load_labeled(base_labels)
                        accepted.append((name, cur, new_val, z))
                        improved = True
                        break
                    weights[name] = cur
                if not improved:
                    weights[name] = cur
            log(f"round {rnd} done; accepted so far: {accepted}", args.log)

        write_weights(args.eval_tune, weights, order)
        if run(args.build_cmd + " >/dev/null 2>&1") != 0:
            log("ERROR: final build failed", args.log)
            return 1
        log(f"final weights: {weights}", args.log)
        log(f"accepted changes: {accepted}", args.log)

        os.makedirs(os.path.dirname(args.report) or ".", exist_ok=True)
        with open(args.report, "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["round", "name", "from", "to", "z", "accepted"])
            w.writeheader()
            w.writerows(rows)
        success = True
        return 0
    finally:
        if not success and os.path.exists(backup):
            shutil.copyfile(backup, args.eval_tune)
            log("restored eval_tune.inc from backup (abnormal exit)", args.log)


if __name__ == "__main__":
    sys.exit(main())
