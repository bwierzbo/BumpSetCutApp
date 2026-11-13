"""Score clips against a recording's truth with the reference scorecard, and pool, compare and report.

Nothing here computes a rally metric of its own: every per-recording number is `reference_scorecard.score`
(scoring contract v1) on a fixture built from the dataset's ticks. What this file adds is bookkeeping — which
recordings a table holds, sums over them, the paired group bootstrap, and the hypotheses' wording.

A recording's fixture: truth = its rallies (contact = start) and its missed-serve / other marks as excluded
spans; cuts = its cut ranges **and its time-breaking spans** (both are not footage in this dataset);
`fullyMarked` = coverage complete **and** full-video negatives `standard` (preregistration §6) — otherwise the
scorecard leaves dead time and false clips null; raw = one span per clip, the union of the raws it joined
(the contract's finalized raw boundary); padded = the clip.

Beside the contract's scorecard a card carries two more raw-boundary scores from the same function: at
IoU ≥ 0.3, and of the clips' **pre-merge** raw spans (`preMergeRawBoundary`) — the model's own splits and
merges, before the padding joins neighbours (research document §5).

Tables: the headline tables hold the standard recordings; restricted recordings are scored the same way and
reported apart. A table with fewer than 3 groups or 30 rallies is marked indicative only (preregistration §7).

Intervals: paired group bootstrap, 1,000 draws, seed 0, recording groups as units, the same draw for both sides
(the `paired_compare.py` convention); 5th and 95th percentiles of the difference. Medians are not resampled.
"""

from __future__ import annotations

import os
import statistics
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scoring"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference_scorecard as rs  # noqa: E402
import validate_dataset as v  # noqa: E402

DRAWS = 1000
BOOTSTRAP_SEED = 0
MIN_GROUPS, MIN_RALLIES = 3, 30
TOLERANCE_SEC = rs.DEFAULTS["tolerance"]


def fully_marked(rec: dict) -> bool:
    return rec["coverage"]["state"] in v.COMPLETE and rec["eligibility"]["fullVideoNegatives"] == "standard"


def _sec(tick: int) -> float:
    return tick / v.TIMESCALE


def fixture(rec: dict, clips: list) -> dict:
    """The reference scorecard's input for a recording and a set of clips ({rawSpans, startTick, endTick})."""
    truth = [{"start": _sec(r["startTick"]), "end": _sec(r["endTick"]), "kind": "rally", "contact": _sec(r["startTick"])} for r in rec["rallies"]]
    truth += [{"start": _sec(s["startTick"]), "end": _sec(s["endTick"]), "kind": s["kind"]} for s in rec["excludedSpans"]]
    return {"duration": _sec(round(rec["durationSec"] * v.TIMESCALE)), "truth": truth,
            "cuts": [[_sec(s["startTick"]), _sec(s["endTick"])] for s in rec["cutRanges"] + rec["timeBreakingSpans"]],
            "raw": [[_sec(min(q["startTick"] for q in c["rawSpans"])), _sec(max(q["endTick"] for q in c["rawSpans"]))] for c in clips],
            "padded": [[_sec(c["startTick"]), _sec(c["endTick"])] for c in clips],
            "fullyMarked": fully_marked(rec)}


def score(rec: dict, clips: list) -> dict:
    return rs.score(fixture(rec, clips))


def card(rec: dict, fold: int, clips: list) -> dict:
    """A recording's evaluation for one set of clips."""
    fx = fixture(rec, clips)
    scorecard = rs.score(fx)
    per = scorecard["paddedExport"]["perRally"]
    padded = rs.normalise([(c["startTick"], c["endTick"]) for c in clips])
    missed_serves = [(s["startTick"], s["endTick"]) for s in rec["excludedSpans"] if s["kind"] == "missedServe"]
    return {
        "recordingId": rec["recordingId"], "groupId": rec["groupId"], "surface": rec["surface"], "fold": fold,
        "restrictedUse": rec["restrictedUse"], "fullyMarked": fx["fullyMarked"],
        "clips": [{"startTick": c["startTick"], "endTick": c["endTick"], "rawSpans": c["rawSpans"]} for c in clips],
        "scorecard": scorecard,
        "rawBoundaryIou03": rs.score({**fx, "params": {"iou": 0.3}})["rawBoundary"],
        "preMergeRawBoundary": rs.score({**fx, "raw": [[_sec(q["startTick"]), _sec(q["endTick"])] for c in clips for q in c["rawSpans"]]})["rawBoundary"],
        # One class per truth rally, from the scorecard's own fields: missed and clipped by status; a complete
        # rally is `merged` when its clip also holds another rally, `preserved` otherwise.
        "rallyClasses": {"preserved": sum(1 for x in per if x["status"] == "complete" and not x["inMergedExport"]),
                         "merged": sum(1 for x in per if x["status"] == "complete" and x["inMergedExport"]),
                         "clipped": sum(1 for x in per if x["status"] == "clipped"),
                         "missed": sum(1 for x in per if x["status"] == "missed")},
        "missedServeSpans": len(missed_serves),
        "missedServeSpansEntered": sum(1 for s in missed_serves if rs.length(rs.intersect([s], padded)) > 0),
    }


def baseline_clips(variants: dict, name: str) -> list:
    return [{"rawSpans": c["rawSpans"], "startTick": c["startTick"], "endTick": c["endTick"]} for c in variants[name]]


# ----------------------------------------------------------------------------- sums and pooled metrics

SUM_KEYS = ["recordings", "rallies", "complete", "clipped", "missed", "mergedRallies", "clips", "exportSec", "rallySec",
            "excludedSecDelivered", "missedServeSpans", "missedServeSpansEntered", "fullyMarkedRecordings", "fullyMarkedClips",
            "falseClips", "deadSec", "deadSecRetained", "rawTp", "rawFp", "rawFn", "rawSplit", "rawMerged", "rawMatches",
            "startAbsErr", "endAbsErr", "startWithin", "endWithin", "rawTp03", "rawFn03", "preMergeSplit", "preMergeMerged"]


def sums(c: dict) -> np.ndarray:
    """A card's additive counts, in SUM_KEYS order."""
    pe, rb = c["scorecard"]["paddedExport"], c["scorecard"]["rawBoundary"]
    fm = c["fullyMarked"]
    starts, ends = [m["startError"] for m in rb["matches"]], [m["endError"] for m in rb["matches"]]
    s = {"recordings": 1, "rallies": pe["rallies"], "complete": pe["complete"], "clipped": pe["clipped"], "missed": pe["missed"],
         "mergedRallies": pe["mergedRallies"], "clips": pe["clips"], "exportSec": pe["exportSeconds"], "rallySec": pe["rallySeconds"],
         "excludedSecDelivered": pe["excludedSecondsDelivered"], "missedServeSpans": c["missedServeSpans"],
         "missedServeSpansEntered": c["missedServeSpansEntered"], "fullyMarkedRecordings": int(fm), "fullyMarkedClips": pe["clips"] if fm else 0,
         "falseClips": pe["falseClips"] if fm else 0, "deadSec": pe["deadSeconds"] if fm else 0.0,
         "deadSecRetained": pe["deadSecondsRetained"] if fm else 0.0,
         "rawTp": rb["tp"], "rawFp": rb["fp"], "rawFn": rb["fn"], "rawSplit": rb["split"], "rawMerged": rb["merged"], "rawMatches": len(starts),
         "startAbsErr": sum(abs(x) for x in starts), "endAbsErr": sum(abs(x) for x in ends),
         "startWithin": sum(1 for x in starts if abs(x) <= TOLERANCE_SEC), "endWithin": sum(1 for x in ends if abs(x) <= TOLERANCE_SEC),
         "rawTp03": c["rawBoundaryIou03"]["tp"], "rawFn03": c["rawBoundaryIou03"]["fn"],
         "preMergeSplit": c["preMergeRawBoundary"]["split"], "preMergeMerged": c["preMergeRawBoundary"]["merged"]}
    return np.array([s[k] for k in SUM_KEYS], dtype=np.float64)


def from_sums(total: np.ndarray) -> dict:
    """The pooled metrics a sum of cards gives. A ratio with an empty denominator is None; dead-time and
    false-clip numbers are None when no recording in the sum is fully marked."""
    s = dict(zip(SUM_KEYS, total.tolist()))
    rate = lambda a, b: a / b if b else None
    marked = s["fullyMarkedRecordings"] > 0
    return {
        "completeRallyRecall": rate(s["complete"], s["rallies"]), "complete": s["complete"], "clipped": s["clipped"], "missed": s["missed"],
        "mergedRallies": s["mergedRallies"], "clips": s["clips"],
        "deadTimeRetention": rate(s["deadSecRetained"], s["deadSec"]), "deadSecondsRetained": s["deadSecRetained"] if marked else None,
        "falseClips": s["falseClips"] if marked else None, "falseClipsPerClip": rate(s["falseClips"], s["fullyMarkedClips"]),
        "excludedSecondsDelivered": s["excludedSecDelivered"], "missedServeSpansEntered": s["missedServeSpansEntered"],
        "rawRecall": rate(s["rawTp"], s["rawTp"] + s["rawFn"]), "rawPrecision": rate(s["rawTp"], s["rawTp"] + s["rawFp"]),
        "rawRecallIou03": rate(s["rawTp03"], s["rawTp03"] + s["rawFn03"]),
        "rawSplit": s["rawSplit"], "rawMerged": s["rawMerged"], "preMergeSplit": s["preMergeSplit"], "preMergeMerged": s["preMergeMerged"],
        "startMAE": rate(s["startAbsErr"], s["rawMatches"]), "endMAE": rate(s["endAbsErr"], s["rawMatches"]),
        "startWithin1s": rate(s["startWithin"], s["rawMatches"]), "endWithin1s": rate(s["endWithin"], s["rawMatches"]),
    }


def metrics(cards: list) -> dict:
    """Pooled metrics of a set of cards, with what a sum cannot give: the signed medians of the boundary errors."""
    out = from_sums(sum((sums(c) for c in cards), np.zeros(len(SUM_KEYS))))
    for key, field in (("startMedianSigned", "startError"), ("endMedianSigned", "endError")):
        errors = [m[field] for c in cards for m in c["scorecard"]["rawBoundary"]["matches"]]
        out[key] = statistics.median(errors) if errors else None
    return out


def paired_bootstrap(a: list, b: list) -> dict:
    """Per metric, a − b over the same recordings and the 90 % interval of that difference under a resampling of
    whole recording groups. `a` and `b` are the two sides' cards for the same recordings."""
    if sorted(c["recordingId"] for c in a) != sorted(c["recordingId"] for c in b):
        raise ValueError("a paired comparison needs the same recordings on both sides")
    units = sorted({c["groupId"] for c in a})
    stack = lambda cards: np.array([sum((sums(c) for c in cards if c["groupId"] == u), np.zeros(len(SUM_KEYS))) for u in units])
    ga, gb = stack(a), stack(b)
    point_a, point_b = from_sums(ga.sum(axis=0)), from_sums(gb.sum(axis=0))
    deltas: dict = {k: [] for k in point_a}
    if len(units) >= 2:
        rng = np.random.default_rng(BOOTSTRAP_SEED)
        for _ in range(DRAWS):
            picks = rng.integers(0, len(units), len(units))
            da, db = from_sums(ga[picks].sum(axis=0)), from_sums(gb[picks].sum(axis=0))
            for k in deltas:
                if da[k] is not None and db[k] is not None:
                    deltas[k].append(da[k] - db[k])
    out = {}
    for k in point_a:
        delta = None if point_a[k] is None or point_b[k] is None else point_a[k] - point_b[k]
        interval = [float(np.percentile(deltas[k], 5)), float(np.percentile(deltas[k], 95))] if deltas[k] else None
        out[k] = {"a": point_a[k], "b": point_b[k], "delta": delta, "interval90": interval, "draws": len(deltas[k]), "units": len(units),
                  "reading": ("no interval" if interval is None else "interval excludes zero: higher" if interval[0] > 0
                              else "interval excludes zero: lower" if interval[1] < 0
                              else "interval includes zero: not told apart at this sample size (not evidence of equivalence)")}
    return out


# ----------------------------------------------------------------------------- tables

def scope(cards: dict, keep, reference: str = "r0") -> dict:
    """One table: `cards` is {variant: [card]}, `keep` picks the recordings (by card). Every variant's pooled
    metrics, and each other variant's paired difference from the reference."""
    chosen = {name: [c for c in cs if keep(c)] for name, cs in cards.items()}
    ref = chosen[reference]
    groups, rallies = len({c["groupId"] for c in ref}), sum(c["scorecard"]["paddedExport"]["rallies"] for c in ref)
    return {"sample": {"recordings": len(ref), "groups": groups, "rallies": rallies},
            "indicativeOnly": groups < MIN_GROUPS or rallies < MIN_RALLIES,
            "variants": {name: metrics(cs) for name, cs in chosen.items()} if ref else {},
            "differences": {f"{name} - {reference}": paired_bootstrap(cs, ref) for name, cs in chosen.items() if name != reference} if ref else {}}


def tables(cards: dict, reference: str = "r0") -> dict:
    ref = cards[reference]
    standard = lambda c: not c["restrictedUse"]
    by = lambda key: {str(val): scope(cards, lambda c, val=val: standard(c) and c[key] == val, reference)
                      for val in sorted({c[key] for c in ref if standard(c)})}
    return {"pooled": scope(cards, standard, reference), "bySurface": by("surface"), "byFold": by("fold"), "byGroup": by("groupId"),
            "restricted": scope(cards, lambda c: c["restrictedUse"], reference),
            "restrictedByRecording": {c["recordingId"]: scope(cards, lambda x, rid=c["recordingId"]: x["recordingId"] == rid, reference)
                                      for c in ref if c["restrictedUse"]}}


# ----------------------------------------------------------------------------- hypotheses

def _clause(diff: dict, metric: str, higher_is_better: bool, need_interval_beyond_zero: bool = False) -> dict:
    d = diff[metric]
    if d["delta"] is None:
        return {**d, "meets": None, "note": "not evaluable: the metric is undefined on this sample"}
    point = d["delta"] >= 0 if higher_is_better else d["delta"] <= 0
    lo, hi = d["interval90"] if d["interval90"] else (None, None)
    wrong_side = d["interval90"] is not None and (hi < 0 if higher_is_better else lo > 0)
    out = {**d, "pointMeetsBar": point, "intervalOnWrongSide": wrong_side, "meets": point and not wrong_side}
    if need_interval_beyond_zero:
        out["pointMeetsBar"] = d["delta"] > 0
        out["intervalAboveZero"] = d["interval90"] is not None and lo > 0
        out["meets"] = out["pointMeetsBar"] and out["intervalAboveZero"]
    return out


def h1(pooled: dict, candidate: str) -> dict:
    """H1 as the preregistration words it: complete-rally recall ≥ R0's, dead-time retention ≤ R0's and false
    clips ≤ R0's, pooled over the folds; it holds when every clause's point estimate meets its bar and no
    interval lies on the wrong side of zero."""
    diff = pooled["differences"][f"{candidate} - r0"]
    clauses = {"completeRallyRecall": _clause(diff, "completeRallyRecall", True),
               "deadTimeRetention": _clause(diff, "deadTimeRetention", False),
               "falseClips": _clause(diff, "falseClips", False)}
    evaluable = all(c["meets"] is not None for c in clauses.values())
    return {"hypothesis": "H1", "comparison": f"{candidate} vs r0", "clauses": clauses,
            "holds": all(c["meets"] for c in clauses.values()) if evaluable else None,
            "notToldApart": sorted(k for k, c in clauses.items() if c["meets"] is not None and c["reading"].startswith("interval includes zero"))}


def h2(r2_cards: list, r1_cards: list) -> dict:
    """H2 as worded: R2's pooled complete-rally recall higher than R1's with the paired 90 % interval of the
    recall difference above zero, at dead-time retention and false clips no worse than R1's."""
    standard = lambda cards: [c for c in cards if not c["restrictedUse"]]
    diff = paired_bootstrap(standard(r2_cards), standard(r1_cards))
    clauses = {"completeRallyRecall": _clause(diff, "completeRallyRecall", True, need_interval_beyond_zero=True),
               "deadTimeRetention": _clause(diff, "deadTimeRetention", False),
               "falseClips": _clause(diff, "falseClips", False)}
    for key in ("deadTimeRetention", "falseClips"):          # "no worse than R1's": the point estimates
        if clauses[key]["meets"] is not None:
            clauses[key]["meets"] = clauses[key]["pointMeetsBar"]
    evaluable = all(c["meets"] is not None for c in clauses.values())
    return {"hypothesis": "H2", "comparison": "r2 vs r1", "clauses": clauses,
            "holds": all(c["meets"] for c in clauses.values()) if evaluable else None}


# ----------------------------------------------------------------------------- markdown

_COLUMNS = [("completeRallyRecall", "complete recall"), ("clipped", "clipped"), ("missed", "missed"), ("mergedRallies", "merged (padded)"),
            ("falseClips", "false clips"), ("deadTimeRetention", "dead-time retention"), ("rawSplit", "split (raw)"),
            ("rawMerged", "merged (raw)"), ("preMergeMerged", "merged (pre-merge raw)"), ("startMAE", "start MAE s"), ("endMAE", "end MAE s"),
            ("startMedianSigned", "start median s"), ("endMedianSigned", "end median s")]


def _fmt(x) -> str:
    if x is None:
        return "—"
    return str(int(x)) if float(x).is_integer() and abs(x) >= 1 or x == 0 else f"{x:.3f}"


def _scope_md(title: str, sc: dict) -> list:
    s = sc["sample"]
    out = [f"### {title}", "",
           f"{s['recordings']} recordings, {s['groups']} groups, {s['rallies']} rallies" + (" — **indicative only**" if sc["indicativeOnly"] else ""), ""]
    if not sc["variants"]:
        return out + ["No recording.", ""]
    out += ["| variant | " + " | ".join(label for _, label in _COLUMNS) + " |", "|---|" + "---|" * len(_COLUMNS)]
    out += [f"| {name} | " + " | ".join(_fmt(m[key]) for key, _ in _COLUMNS) + " |" for name, m in sc["variants"].items()]
    out.append("")
    for name, diff in sc["differences"].items():
        out += [f"| {name} | difference | 90 % interval | reading |", "|---|---|---|---|"]
        for key in ("completeRallyRecall", "deadTimeRetention", "falseClips", "mergedRallies", "clipped", "missed", "startMAE", "endMAE"):
            d = diff[key]
            interval = "—" if d["interval90"] is None else f"[{_fmt(d['interval90'][0])}, {_fmt(d['interval90'][1])}]"
            out.append(f"| {key} | {_fmt(d['delta'])} | {interval} | {d['reading']} |")
        out.append("")
    return out


def markdown(report: dict) -> str:
    """The report as a page: identity, the choices per fold, the hypotheses, then every table."""
    ident, t = report["identity"], report["tables"]
    out = [f"# Rally classifier — {ident['candidate']} ({ident['net']} net), development folds", "",
           f"Dataset `{ident['dataset']['name']}` · digest `{ident['dataset']['digest']}` · manifest `{ident['dataset']['manifestSha256']}`  ",
           f"Folds file `{ident['foldsFileSha256']}` · seed {ident['foldDraw']['seed']} · shuffle {ident['foldDraw']['shuffle']} · {ident['foldDraw']['folds']} folds  ",
           f"Trainer seed {ident['seed'] if ident['seed'] is not None else '— (deterministic)'} · scoring contract v1 (`reference_scorecard.py` `{ident['codeSha256']['reference_scorecard.py'][:16]}…`)", "",
           "Development evidence only: every recording here has training and selection exposure (preregistration §1).", "",
           "## Choices made inside the training folds", "",
           "| outer fold | nested fold | model choice | temperature | decode point | nested recall vs R0 | constraint met |", "|---|---|---|---|---|---|---|"]
    for f in report["folds"]:
        sel, p = f["decode"]["selection"], f["decode"]["point"]
        out.append(f"| {f['fold']} | {f['nestedFold']} | {f['model']} | {f['calibration']['temperature']:.4f} | "
                   f"θ_on {p['thetaOn']}, θ_off {p['thetaOff']}, on {p['sustainOnSec']} s, off {p['sustainOffSec']} s | "
                   f"{sel['complete']} vs {sel['r0Complete']} of {sel['rallies']} | {'yes' if sel['constraintMet'] else '**no**'} |")
    out += ["", "## Hypotheses", ""]
    for h in report["hypotheses"]:
        verdict = "not evaluable" if h.get("holds") is None else ("holds" if h["holds"] else "does not hold")
        out += [f"**{h['hypothesis']} ({h['comparison']}): {verdict}.** {h.get('note', '')}", ""]
        for key, c in h.get("clauses", {}).items():
            interval = "—" if c["interval90"] is None else f"[{_fmt(c['interval90'][0])}, {_fmt(c['interval90'][1])}]"
            out.append(f"- {key}: {_fmt(c['a'])} vs {_fmt(c['b'])}, difference {_fmt(c['delta'])}, interval {interval} — {c.get('note') or c['reading']}")
        out.append("")
    out += ["## Tables", ""] + _scope_md("Pooled (standard recordings)", t["pooled"])
    for key, label in (("bySurface", "Surface"), ("byFold", "Fold"), ("byGroup", "Group")):
        for name, sc in t[key].items():
            out += _scope_md(f"{label} {name}", sc)
    out += _scope_md("Restricted recordings (apart)", t["restricted"])
    for name, sc in t["restrictedByRecording"].items():
        out += _scope_md(f"Restricted recording {name}", sc)
    d = report.get("diagnostics")
    if d:
        out += ["## The learned path", "",
                f"Decoded intervals dropped by the raw floor: {d['droppedByRawFloor']} · unprimed intervals (no serve contact within 3 s of the start): "
                f"{d['unprimedIntervals']} of {d['decodedIntervals']} · recordings over 20 % uncertain: {d['recordingsOverUncertainLimit'] or 'none'}", "",
                "On-device processing time, memory and bundle size: not measured.", ""]
    return "\n".join(out) + "\n"
