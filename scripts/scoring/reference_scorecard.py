#!/usr/bin/env python3
"""
Reference implementation of the rally scoring contract (docs/ml-roadmap/SCORING_CONTRACT.md).

    python3 scripts/scoring/reference_scorecard.py BumpSetCutTests/Fixtures/Scoring/*.json            # print scorecards
    python3 scripts/scoring/reference_scorecard.py --write-expected BumpSetCutTests/Fixtures/Scoring/*.json   # pin them

Independent of the Swift code on purpose: the Swift scorers must reproduce
these numbers on the same fixtures (Phase 2 pass rule: "independently
computed interval arithmetic matches the official scorecard"). Pure Python,
no dependencies. All times are integer ticks at 600/s (CMTime's timescale
in the pipeline); seconds in a fixture are rounded to the nearest tick on
load. Intervals are half-open [start, end).

A fixture is one JSON object:
    {"duration": 300.0,
     "truth": [{"start": 10.0, "end": 14.0, "kind": "rally", "contact": 10.0}, ...],   # kind: rally | missedServe | other
     "raw":    [[10.0, 14.0], ...],       # raw decider boundaries (serve-primed start allowed)
     "padded": [[8.0, 14.5], ...],        # exported clips
     "params": {"iou": 0.5, "tolerance": 1.0, "complete": 0.98, "detected": 0.5, "split": 0.25, "merged": 0.5},
     "expected": {...}}                   # written by --write-expected; compared otherwise
"""

from __future__ import annotations

import argparse
import json
import sys
from fractions import Fraction
from pathlib import Path

TICKS = 600
DEFAULTS = {"iou": 0.5, "tolerance": 1.0, "complete": 0.98, "detected": 0.5, "split": 0.25, "merged": 0.5}


def tick(seconds: float) -> int:
    return int(round(Fraction(seconds).limit_denominator(10**6) * TICKS))


def sec(ticks: int | Fraction) -> float:
    return round(float(Fraction(ticks) / TICKS), 6)


# ----- interval arithmetic (half-open, integer ticks) -----------------------------------

def normalise(ivs: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Union as sorted, disjoint, non-empty intervals."""
    out: list[list[int]] = []
    for s, e in sorted((s, e) for s, e in ivs if e > s):
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def length(ivs: list[tuple[int, int]]) -> int:
    return sum(e - s for s, e in ivs)


def intersect(a: list[tuple[int, int]], b: list[tuple[int, int]]) -> list[tuple[int, int]]:
    out = []
    for s1, e1 in a:
        for s2, e2 in b:
            s, e = max(s1, s2), min(e1, e2)
            if e > s:
                out.append((s, e))
    return normalise(out)


def subtract(a: list[tuple[int, int]], b: list[tuple[int, int]]) -> list[tuple[int, int]]:
    out = []
    for s, e in a:
        cur = s
        for bs, be in b:
            if be <= cur or bs >= e:
                continue
            if bs > cur:
                out.append((cur, bs))
            cur = max(cur, be)
        if cur < e:
            out.append((cur, e))
    return normalise(out)


def overlap(a: tuple[int, int], b: tuple[int, int]) -> int:
    return max(0, min(a[1], b[1]) - max(a[0], b[0]))


def iou(a: tuple[int, int], b: tuple[int, int]) -> Fraction:
    inter = overlap(a, b)
    union = (a[1] - a[0]) + (b[1] - b[0]) - inter
    return Fraction(inter, union) if union else Fraction(0)


def contains(ivs: list[tuple[int, int]], t: int) -> bool:
    """A time is inside the union when some interval holds it: start inclusive, end inclusive too
    (the end tick of an export is the last frame the clip shows)."""
    return any(s <= t <= e for s, e in ivs)


# ----- the two scorers --------------------------------------------------------------------

def raw_boundary_score(truth: list[dict], raw: list[tuple[int, int]], p: dict) -> dict:
    """Event truth (serve contact → ball dead, kind rally) against raw decider boundaries."""
    rallies = [t for t in truth if t["kind"] == "rally"]
    excluded = normalise([(t["s"], t["e"]) for t in truth if t["kind"] != "rally"])
    # A prediction touching an excluded span (a missed serve, a marked non-rally) is not scored:
    # the decider fired on something a person marked as not a rally, which is neither a hit nor a false clip.
    scored_preds = [r for r in raw if length(intersect([r], excluded)) == 0]
    unscored = len(raw) - len(scored_preds)
    # Greedy one-to-one matching by descending IoU; ties broken by earlier truth start, then earlier prediction start.
    pairs = [(iou((t["s"], t["e"]), r), ti, ri) for ti, t in enumerate(rallies) for ri, r in enumerate(scored_preds)]
    pairs = [x for x in pairs if x[0] >= Fraction(p["iou"]).limit_denominator(1000)]
    pairs.sort(key=lambda x: (-x[0], rallies[x[1]]["s"], scored_preds[x[2]][0]))
    used_t, used_r, matched = set(), set(), []
    for _, ti, ri in pairs:
        if ti in used_t or ri in used_r:
            continue
        used_t.add(ti); used_r.add(ri); matched.append((ti, ri))
    tp = len(matched); fn = len(rallies) - tp; fp = len(scored_preds) - tp
    tol = tick(p["tolerance"])
    start_err = [scored_preds[ri][0] - rallies[ti]["s"] for ti, ri in matched]
    end_err = [scored_preds[ri][1] - rallies[ti]["e"] for ti, ri in matched]
    # Split / merged, fractional on both sides.
    split = sum(1 for t in rallies if sum(1 for r in scored_preds if overlap((t["s"], t["e"]), r) >= Fraction(p["split"]) * (t["e"] - t["s"])) >= 2)
    merged = sum(1 for r in scored_preds if sum(1 for t in rallies if overlap((t["s"], t["e"]), r) >= Fraction(p["merged"]) * (t["e"] - t["s"])) >= 2)
    prec = Fraction(tp, tp + fp) if tp + fp else Fraction(0)
    rec = Fraction(tp, tp + fn) if tp + fn else Fraction(0)
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else Fraction(0)
    mae = lambda xs: sec(Fraction(sum(abs(x) for x in xs), len(xs))) if xs else None
    def med(xs):
        if not xs:
            return None
        o = sorted(xs); n = len(o)
        return sec(o[n // 2]) if n % 2 else sec(Fraction(o[n // 2 - 1] + o[n // 2], 2))   # conventional median, fractional ticks kept
    within = lambda xs: round(sum(1 for x in xs if abs(x) <= tol) / len(xs), 6) if xs else None
    return {"rallies": len(rallies), "predictions": len(raw), "unscoredPredictions": unscored,
            "tp": tp, "fp": fp, "fn": fn, "precision": round(float(prec), 6), "recall": round(float(rec), 6), "f1": round(float(f1), 6),
            "startMAE": mae(start_err), "endMAE": mae(end_err), "startMedianSigned": med(start_err), "endMedianSigned": med(end_err),
            "startWithinTolerance": within(start_err), "endWithinTolerance": within(end_err),
            "split": split, "merged": merged,
            "matches": [{"truth": ti, "prediction": ri, "startError": sec(se), "endError": sec(ee)} for (ti, ri), se, ee in zip(matched, start_err, end_err)]}


def padded_export_score(truth: list[dict], padded: list[tuple[int, int]], duration: int, p: dict) -> dict:
    """Event truth against exported (padded) clips: what the viewer gets and what dead time remains."""
    rallies = [t for t in truth if t["kind"] == "rally"]
    excluded = normalise([(t["s"], t["e"]) for t in truth if t["kind"] != "rally"])
    G = normalise([(t["s"], t["e"]) for t in rallies])
    P = normalise(padded)
    per = []
    for t in rallies:
        r = (t["s"], t["e"])
        retained = Fraction(length(intersect([r], P)), r[1] - r[0])
        complete = retained >= Fraction(p["complete"]).limit_denominator(1000) and contains(P, t["contact"]) and contains(P, t["e"])
        status = "complete" if complete else ("clipped" if retained >= Fraction(p["detected"]).limit_denominator(1000) else "missed")
        per.append({"retainedFraction": round(float(retained), 6), "contactInExport": contains(P, t["contact"]),
                    "deadBallInExport": contains(P, t["e"]), "status": status})
    complete = sum(1 for x in per if x["status"] == "complete")
    clipped = sum(1 for x in per if x["status"] == "clipped")
    missed = sum(1 for x in per if x["status"] == "missed")
    scorable = subtract([(0, duration)], excluded)          # the dead-time denominator never counts excluded spans
    dead = subtract(scorable, G)
    dead_kept = intersect(P, dead)
    false_clips = sum(1 for c in P if length(intersect([c], G)) == 0 and length(intersect([c], excluded)) == 0)
    return {"rallies": len(rallies), "clips": len(P), "complete": complete, "clipped": clipped, "missed": missed,
            "completeRallyRecall": round(complete / len(rallies), 6) if rallies else None,
            "rallySeconds": sec(length(G)), "exportSeconds": sec(length(P)),
            "deadSeconds": sec(length(dead)), "deadSecondsRetained": sec(length(dead_kept)),
            "deadTimeRetention": round(float(Fraction(length(dead_kept), length(dead))), 6) if length(dead) else None,
            "falseClips": false_clips, "perRally": per,
            # The historical diagnostic (PipelineTuner.Score.value, D-011), on the same inputs, under its own name.
            "legacyCoveredMinusQuarterDead": round(float(Fraction(length(intersect(G, P)), length(G)) - Fraction(1, 4) * Fraction(length(subtract(P, G)), length(G))), 6) if length(G) else None}


def score(fixture: dict) -> dict:
    p = {**DEFAULTS, **fixture.get("params", {})}
    truth = [{"s": tick(t["start"]), "e": tick(t["end"]), "kind": t.get("kind", "rally"), "contact": tick(t.get("contact", t["start"]))}
             for t in fixture["truth"]]
    raw = [(tick(s), tick(e)) for s, e in fixture.get("raw", [])]
    padded = [(tick(s), tick(e)) for s, e in fixture.get("padded", [])]
    return {"contract": "SCORING_CONTRACT v1", "params": p,
            "rawBoundary": raw_boundary_score(truth, raw, p),
            "paddedExport": padded_export_score(truth, padded, tick(fixture["duration"]), p)}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fixtures", nargs="+", type=Path)
    ap.add_argument("--write-expected", action="store_true", help="store the scorecard in each fixture's `expected`")
    args = ap.parse_args()
    bad = 0
    for path in args.fixtures:
        fixture = json.loads(path.read_text())
        result = score(fixture)
        if args.write_expected:
            fixture["expected"] = result
            path.write_text(json.dumps(fixture, indent=1) + "\n")
            print(f"{path.name}: expected written")
        elif "expected" in fixture:
            same = fixture["expected"] == result
            bad += not same
            print(f"{path.name}: {'matches expected' if same else 'DIFFERS from expected'}")
            if not same:
                print(json.dumps(result, indent=1))
        else:
            print(f"{path.name}:\n{json.dumps(result, indent=1)}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
