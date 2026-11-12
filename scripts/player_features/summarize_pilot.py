#!/usr/bin/env python3
"""Summarise a player-feasibility run (player_features_v1) for the P0 report.

Usage:
  summarize_pilot.py <run folder> [--audit <filled audit-sample.csv>] [--json out.json]

<run folder> holds features/ (validated by validate_player_features.py) and diagnostics/.
The per-interval numbers are the run's own diagnostics/summary.json (PlayerFeaturesSummary,
the same values the Player Lab window shows) — model output only. Accuracy comes only from
a filled audit sheet: detector accuracy is never inferred from the detector. Standard library only.
"""
import csv
import json
import os
import statistics
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from validate_player_features import MANIFEST, read_bytes  # noqa: E402


def mean(v):
    v = [x for x in v if x is not None]
    return statistics.fmean(v) if v else None


KIND_FIELDS = ("personsPerFrame", "inCourtPerFrame", "poseShare", "meanSpeedInCourt", "movingShareInCourt", "coherenceInCourt", "armRaisedShare")


def summarize(run, audit_path=None):
    """The run's own numbers (diagnostics/summary.json, written by the Swift run and shown by the Player Lab window),
    grouped by interval kind, plus runtime and, when given, the filled audit sheet."""
    diagnostics = os.path.join(run, "diagnostics")
    rows = json.loads(read_bytes(os.path.join(diagnostics, "summary.json")))
    m = json.loads(read_bytes(os.path.join(run, "features", MANIFEST)))
    by_kind = defaultdict(lambda: defaultdict(list))
    for r in rows:
        for k in KIND_FIELDS:
            if r.get(k) is not None:
                by_kind[r["kind"]][k].append(r[k])
    out = {"run": m["generator"].get("run"), "detector": m["detector"], "rows": rows,
           "byIntervalKind": {k: {f: mean(v) for f, v in d.items()} for k, d in by_kind.items()}}
    rt = os.path.join(diagnostics, "runtime.json")
    if os.path.exists(rt):
        out["runtime"] = json.loads(read_bytes(rt))
    if audit_path:
        out["audit"] = audit(audit_path)
    return out


def share_yes(answers):
    judged = [a for a in answers if a not in ("na", "n/a", "")]
    return sum(1 for a in judged if a in ("yes", "y", "1")) / len(judged) if judged else None


def audit(path):
    with open(path, newline="", encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if (r.get("visible_on_court_players") or "").strip() != ""]
    groups = defaultdict(list)
    for r in rows:
        groups[r["recording"]].append(r)
    groups["ALL"] = rows

    def n(r, k):
        v = (r.get(k) or "").strip()
        return int(v) if v.lstrip("-").isdigit() else 0

    res = {}
    for g, rs in groups.items():
        visible = sum(n(r, "visible_on_court_players") for r in rs)
        found = sum(n(r, "detected_on_court_players") for r in rs)
        res[g] = {"frames": len(rs), "visibleOnCourt": visible, "detectedOnCourt": found,
                  "recall": found / visible if visible else None,
                  "falseOnCourtPerFrame": sum(n(r, "false_on_court_detections") for r in rs) / len(rs) if rs else None,
                  "offCourtDetectionsPerFrame": sum(n(r, "off_court_detections") for r in rs) / len(rs) if rs else None,
                  # Not assessed when nobody filled the column: a blank is not zero switches.
                  "identitySwitches": (sum(n(r, "identity_switches_vs_previous_sampled") for r in rs)
                                       if any((r.get("identity_switches_vs_previous_sampled") or "").strip() for r in rs) else None),
                  # "na" (no on-court pose to judge) leaves the denominator.
                  "posesPlausibleShare": share_yes([(r.get("poses_plausible") or "").strip().lower() for r in rs]),
                  "reviewers": sorted({(r.get("reviewer") or "").strip() for r in rs})}
    return res


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    audit_path = argv[argv.index("--audit") + 1] if "--audit" in argv else None
    out = summarize(argv[0], audit_path)
    text = json.dumps(out, indent=2, default=str)
    if "--json" in argv:
        with open(argv[argv.index("--json") + 1], "w", encoding="utf-8") as fh:
            fh.write(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
