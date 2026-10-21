#!/usr/bin/env python3
"""
Paired comparison of two models scored on the same val windows.

    python paired_compare.py <A>/metrics.json <B>/metrics.json [--group tracked] [--out delta.json]

Each metrics.json comes from train_heatmap_model.py (a run's `best`, or a
checkpoint scored with --score-only, whose `scored` block is used first) and
carries the 4 px tallies per val video (`per_clip`). The two must have been
scored on the same videos; anything else is refused, since a difference
between models is only meaningful on identical data.

ΔF1 = F1(A) − F1(B) on balls in play at 4 px, with a 90% interval from
resampling whole val videos 1000 times — the *same* draw of videos for both
models each time (seed 0), so the interval is of the paired difference, not
of two independent scores. Reported for the chosen group (tracked-rally
windows by default: every frame labeled, the trustworthy score) and per
surface. A is "not distinguishably worse" than B when the interval is not
entirely below zero.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

DRAWS = 1000
SURFACES = {"ind": "indoor", "bch": "beach", "grs": "grass"}


def f1(t: dict[str, int]) -> float:
    p = t["tp"] / max(1, t["tp"] + t["fp"])
    r = t["tp"] / max(1, t["tp"] + t["fn"])
    return 2 * p * r / max(1e-9, p + r)


def tallies(path: Path, group: str) -> tuple[dict[str, dict[str, int]], str]:
    m = json.loads(path.read_text())
    for key in ("scored", "best", "baseline"):
        block = m.get(key)
        if block and block.get("per_clip", {}).get(group):
            return block["per_clip"][group], key
    sys.exit(f"{path}: no per-video tallies for group '{group}' — scored with a trainer older than --score-only, "
             f"or the package has no such windows.")


def compare(a: dict[str, dict[str, int]], b: dict[str, dict[str, int]], clips: list[str]) -> dict:
    rng = np.random.default_rng(0)
    total = lambda t, picks: {k: sum(t[c][k] for c in picks) for k in ("tp", "fp", "fn")}
    deltas = []
    for _ in range(DRAWS):
        picks = [clips[k] for k in rng.integers(0, len(clips), len(clips))]
        deltas.append(f1(total(a, picks)) - f1(total(b, picks)))
    fa, fb = f1(total(a, clips)), f1(total(b, clips))
    low, high = (float(np.percentile(deltas, 5)), float(np.percentile(deltas, 95)))
    return {"videos": len(clips), "f1_a": round(fa, 4), "f1_b": round(fb, 4), "delta": round(fa - fb, 4),
            "delta_range": [round(low, 4), round(high, 4)],
            "verdict": ("A distinguishably better" if low > 0 else
                        "A distinguishably worse" if high < 0 else "not told apart")}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("a", type=Path, help="metrics.json of model A")
    p.add_argument("b", type=Path, help="metrics.json of model B")
    p.add_argument("--group", default="tracked", choices=("tracked", "all", "sampled"))
    p.add_argument("--out", type=Path, default=None, help="Write the result as JSON here too")
    args = p.parse_args()
    a, key_a = tallies(args.a, args.group)
    b, key_b = tallies(args.b, args.group)
    if set(a) != set(b):
        only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))
        sys.exit(f"Not the same val videos: only in A {only_a}; only in B {only_b}. Score both on one package.")
    clips = sorted(a)
    if len(clips) < 2:
        sys.exit("Fewer than two val videos — nothing to resample.")
    result = {"a": {"path": str(args.a), "block": key_a}, "b": {"path": str(args.b), "block": key_b},
              "group": args.group, "draws": DRAWS, "seed": 0, "all": compare(a, b, clips), "by_surface": {}}
    for prefix, surface in SURFACES.items():
        subset = [c for c in clips if c.startswith(prefix)]
        if len(subset) >= 2:
            result["by_surface"][surface] = compare(a, b, subset)
    print(f"ΔF1 = F1(A) − F1(B) on balls in play at 4 px, {args.group} windows, {DRAWS} paired draws of val videos")
    rows = [("all", result["all"])] + list(result["by_surface"].items())
    print(f"   {'':8} {'videos':>6} {'F1 A':>7} {'F1 B':>7} {'ΔF1':>8}  {'90% range':>17}  verdict")
    for name, r in rows:
        print(f"   {name:8} {r['videos']:6} {r['f1_a']:7.3f} {r['f1_b']:7.3f} {r['delta']:+8.3f}  "
              f"[{r['delta_range'][0]:+.3f}, {r['delta_range'][1]:+.3f}]  {r['verdict']}")
    if args.out:
        args.out.write_text(json.dumps(result, indent=2))
        print(f"Written to {args.out}")


if __name__ == "__main__":
    main()
