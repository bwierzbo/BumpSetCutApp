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

Every fixture carries `decided`, the decider's ranges before finalization;
its pinned `raw` and `padded` must be exactly what production's finalization
(SegmentBuilder rules) builds from them. --write-expected and the check refuse
a fixture where they are not.

A fixture is one JSON object:
    {"duration": 300.0,
     "truth": [{"start": 10.0, "end": 14.0, "kind": "rally", "contact": 10.0}, ...],   # kind: rally | missedServe | other
     "decided": [[10.0, 14.0], ...],      # the decider's ranges before finalization (serve-primed start allowed)
     "raw":    [[10.0, 14.0], ...],       # finalized raw boundaries (merge, min length) — derived from decided
     "padded": [[8.0, 14.5], ...],        # exported clips — derived from decided
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


def ratio(x) -> Fraction:
    """A threshold as the exact decimal it was written as (0.4 is 2/5, not the float nearest 0.4)."""
    return Fraction(str(x))


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


def covers(ivs: list[tuple[int, int]], t: int, duration: int) -> bool:
    """An event instant is the first frame at which the event is true (tick t). A half-open clip
    [s, e) shows frame t iff s <= t < e. An event at the video's last tick (a rally that runs to the
    end of the file, a truncated edge) is covered by a clip that reaches the end."""
    if t >= duration:
        return any(e >= duration for _, e in ivs)
    return any(s <= t < e for s, e in ivs)


# ----- production finalization (SegmentBuilder.finalizeWithRaw), for fixture self-consistency -----

PREROLL, SHORT_PREROLL, POSTROLL = tick(2.0), tick(0.5), tick(0.5)
# Thresholds production compares in SECONDS against unquantized Double config values; kept exact here.
SHORT_RAW, MIN_GAP, MIN_LEN = Fraction("2.5"), Fraction("1.3513"), Fraction("2.6131")


def finalize(decided: list[tuple[int, int]], duration: int) -> tuple[list[tuple[int, int]], list[tuple[int, int]]]:
    """(raw, padded) as production finalizes the decider's ranges (SegmentBuilder.finalizeWithRaw):
    preroll 2.0 s, or 0.5 s when the decided range is under 2.5 s; postroll 0.5 s; clamped to
    [0, duration]; merged when the PADDED gap is at most 1.3513 s (the raw ranges are unioned with
    them); dropped when the padded range is under 2.6131 s. Gap and length are compared in seconds
    against the exact decimal thresholds, as production compares Doubles — never rounded to ticks."""
    built = []
    for s_, e_ in sorted(decided):
        pre = SHORT_PREROLL if Fraction(e_ - s_, TICKS) < SHORT_RAW else PREROLL
        built.append([max(0, s_ - pre), min(duration, e_ + POSTROLL), s_, e_])
    # Production sorts by PADDED start before merging: a short range's 0.5 s preroll can place it
    # after a longer neighbour whose 2.0 s preroll starts earlier, whatever the decided order.
    built.sort(key=lambda b: (b[0], b[1]))
    merged: list[list[int]] = []
    for b in built:
        if merged and Fraction(b[0] - merged[-1][1], TICKS) <= MIN_GAP:
            m = merged[-1]
            m[0] = min(m[0], b[0]); m[1] = max(m[1], b[1]); m[2] = min(m[2], b[2]); m[3] = max(m[3], b[3])
        else:
            merged.append(b)
    kept = [m for m in merged if Fraction(m[1] - m[0], TICKS) >= MIN_LEN]
    return [(m[2], m[3]) for m in kept], [(m[0], m[1]) for m in kept]


def production_consistency(fixture: dict) -> list[str]:
    """Why the fixture's pinned raw/padded lists are not what production builds from its `decided`
    ranges (the decider's output before finalization); empty when they are."""
    if "decided" not in fixture:
        return ["no `decided` list (the decider's ranges before finalization) to derive raw and padded from"]
    duration = tick(fixture["duration"])
    decided = [(tick(a), tick(b)) for a, b in fixture["decided"]]
    raw = [(tick(a), tick(b)) for a, b in fixture.get("raw", [])]
    padded = [(tick(a), tick(b)) for a, b in fixture.get("padded", [])]
    f_raw, f_padded = finalize(decided, duration)
    show = lambda ivs: [(sec(a), sec(b)) for a, b in ivs]
    problems = []
    if f_raw != raw:
        problems.append(f"raw {show(raw)} is not what production finalizes from decided {show(decided)}: {show(f_raw)}")
    if f_padded != normalise(padded):
        problems.append(f"padded {show(padded)} is not what production builds from decided {show(decided)}: {show(f_padded)}")
    return problems


# ----- the two scorers --------------------------------------------------------------------

def raw_boundary_score(truth: list[dict], raw: list[tuple[int, int]], p: dict) -> dict:
    """Event truth (serve contact → ball dead, kind rally) against raw decider boundaries."""
    rallies = [t for t in truth if t["kind"] == "rally"]
    excluded = normalise([(t["s"], t["e"]) for t in truth if t["kind"] != "rally"])
    # Excluded time (a missed serve, a marked non-rally) is MASKED, not disqualifying: each prediction
    # keeps its scorable pieces (prediction minus the excluded union) and is scored on those; a
    # prediction with nothing left outside excluded time is unscored (neither a hit nor a false clip).
    masked = [(r, subtract([r], excluded)) for r in raw]
    scored = [(r, pieces) for r, pieces in masked if pieces]
    unscored = len(raw) - len(scored)
    scored_preds = [(pieces[0][0], pieces[-1][1]) for _, pieces in scored]   # scorable span: first to last scorable tick
    piece_sets = [pieces for _, pieces in scored]

    def masked_iou(t: dict, k: int) -> Fraction:
        inter = length(intersect([(t["s"], t["e"])], piece_sets[k]))
        union = (t["e"] - t["s"]) + length(piece_sets[k]) - inter
        return Fraction(inter, union) if union else Fraction(0)

    # Greedy one-to-one matching by descending IoU on the masked pieces; ties broken by earlier truth
    # start, then earlier prediction start. Boundary errors use the scorable span's ends: a start
    # that lies inside excluded time is not a boundary the contract can judge.
    pairs = [(masked_iou(t, ri), ti, ri) for ti, t in enumerate(rallies) for ri in range(len(scored_preds))]
    pairs = [x for x in pairs if x[0] >= ratio(p["iou"])]
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
    cover = lambda t, k: length(intersect([(t["s"], t["e"])], piece_sets[k]))
    split = sum(1 for t in rallies if sum(1 for k in range(len(scored_preds)) if cover(t, k) >= ratio(p["split"]) * (t["e"] - t["s"])) >= 2)
    merged = sum(1 for k in range(len(scored_preds)) if sum(1 for t in rallies if cover(t, k) >= ratio(p["merged"]) * (t["e"] - t["s"])) >= 2)
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
        complete = retained >= ratio(p["complete"]) and covers(P, t["contact"], duration) and covers(P, t["e"], duration)
        status = "complete" if complete else ("clipped" if retained >= ratio(p["detected"]) else "missed")
        per.append({"retainedFraction": round(float(retained), 6), "contactInExport": covers(P, t["contact"], duration),
                    "deadBallInExport": covers(P, t["e"], duration), "status": status})
    complete = sum(1 for x in per if x["status"] == "complete")
    clipped = sum(1 for x in per if x["status"] == "clipped")
    missed = sum(1 for x in per if x["status"] == "missed")
    scorable = subtract([(0, duration)], excluded)          # the dead-time denominator never counts excluded spans
    dead = subtract(scorable, G)
    dead_kept = intersect(P, dead)
    # A false clip is a clip with no rally in it that still delivers scorable (non-excluded) time; a clip
    # lying wholly inside excluded time is neither a rally nor false.
    false_clips = sum(1 for c in P if length(intersect([c], G)) == 0 and length(subtract([c], excluded)) > 0)
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
    # A missing or null kind is a legacy mark made before live tagging: a rally (SCORING_CONTRACT §1).
    truth = [{"s": tick(t["start"]), "e": tick(t["end"]), "kind": t.get("kind") or "rally",
              "contact": tick(t["contact"] if t.get("contact") is not None else t["start"])}
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
        problems = production_consistency(fixture)
        if problems:
            bad += 1
            print(f"{path.name}: NOT one production run — " + "; ".join(problems))
            continue
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
