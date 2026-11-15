"""Trusted negatives (the adopted gate G7) and the negative-coverage gate (G6 as amended by A3).

The owner, 2026-11-14: "Only explicitly reviewed clean intervals or eligible Stage 1 verified coverage may supply
trusted negatives under the adopted G7 policy." and "If fewer than the required groups contribute trusted
negatives, report the exact deficiency rather than weakening the gate."

**What is trusted is read from the manifest, never from a step's label.** A recording's trusted time is:

- the whole recording, when it has eligible Stage 1 verified coverage — `coverage.state` `stage1_complete` and
  `eligibility.fullVideoNegatives` `standard`;
- its reviewed-clean intervals — `coverage.audit.cleanIntervals` (`[{startTick, endTick}]`, half-open ticks),
  read only under the label schema `rally_activity_truth_v2` and only when its full-video negatives are
  `standard` (an edited recording supplies no negative, whatever an audit record says);
- nothing otherwise. `rally_activity_truth_v1` has no audit record: there a declared-complete recording's
  negatives are **declared, not audited**.

A *negative step* is a step labelled `NON_RALLY` or `NON_RALLY_ACTIVITY` with loss weight. It is trusted when
its tick lies in its recording's trusted time. Seconds are step time (`folds.step_seconds`).

**G7** holds when every negative step is trusted. Under v2 the exporter and the validator already promise it,
so an untrusted negative step there is a broken dataset and `report` raises `CoverageError` (defence in depth:
nothing is counted, nothing is run). Under v1 the untrusted steps are counted and reported.

**G6** (amendment A3, counted over trusted negatives only — audit spec D7): at least two-thirds of the
dataset's groups, rounded up, contribute trusted negatives, and at least two such groups in every fold. A group
contributes when its recordings hold trusted-negative time.

Neither gate is decided leniently anywhere: `report` states each one as met or not, with every deficiency
spelled out (which groups, which folds, by how many). Standard library only.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import folds as fd  # noqa: E402
import validate_dataset as v  # noqa: E402

DECLARED_LABELS = "rally_activity_truth_v1"
AUDITED_LABELS = "rally_activity_truth_v2"
LABEL_SCHEMAS = (DECLARED_LABELS, AUDITED_LABELS)
G6_FRACTION = (2, 3)            # of the dataset's groups, rounded up
G6_GROUPS_PER_FOLD = 2
STAGE1, CLEAN, NONE = "stage1_verified", "reviewed_clean_intervals", "none"
POLICY = ("G7 (adopted 2026-11-14): only explicitly reviewed clean intervals or eligible Stage 1 verified coverage supply "
          "trusted negatives. G6 (amendment A3, over trusted negatives): at least two-thirds of the groups, rounded up, "
          "and at least two groups in every fold contribute trusted negatives.")


class CoverageError(Exception):
    """The dataset's negatives are not what its label schema promises, or an audit record cannot be read."""


def trusted_time(rec: dict, audited: bool) -> tuple:
    """(source, spans, why not): `spans` is None for the whole recording, else [(startTick, endTick)] — empty when
    the recording supplies no trusted negative, and then the third value says why. `audited`: the dataset's label
    schema is the audited one (v2), so `coverage.audit` is read."""
    cov, level = rec["coverage"], rec["eligibility"]["fullVideoNegatives"]
    if level != "standard":
        return NONE, [], f"full-video negatives are {level}: the recording supplies no negative"
    if cov["state"] == "stage1_complete":
        return STAGE1, None, None
    if not audited:
        return NONE, [], f"coverage {cov['state']}: declared, not audited (this label schema carries no audit record)"
    audit = cov.get("audit")
    if audit is None:
        return NONE, [], f"coverage {cov['state']}: not audited"
    try:
        spans = [(s["startTick"], s["endTick"]) for s in audit["cleanIntervals"]]
    except (KeyError, TypeError) as e:
        raise CoverageError(f"{rec['recordingId']}: coverage.audit.cleanIntervals cannot be read ({e!r})")
    if any(isinstance(x, bool) or not isinstance(x, int) for span in spans for x in span) or any(a >= b for a, b in spans):
        raise CoverageError(f"{rec['recordingId']}: coverage.audit.cleanIntervals must be integer ticks with startTick < endTick")
    if not spans:
        return NONE, [], f"audited ({audit.get('state')}): no reviewed-clean interval"
    return CLEAN, spans, None


def inside(tick: int, spans) -> bool:
    return spans is None or any(a <= tick < b for a, b in spans)


def coverage_of(rec: dict, steps: list, audited: bool) -> dict:
    """One recording's trusted and untrusted negative steps and seconds, and where its trust comes from."""
    source, spans, why = trusted_time(rec, audited)
    audit = rec["coverage"].get("audit") if audited else None
    row = {"recordingId": rec["recordingId"], "groupId": rec["groupId"], "source": source, "whyNone": why,
           "auditState": audit.get("state") if audit else None,
           "cleanIntervals": len(spans) if source == CLEAN else None,
           "cleanSec": round(sum(b - a for a, b in spans) / v.TIMESCALE, 3) if source == CLEAN else None,
           "trustedNegativeSteps": 0, "trustedNegativeSec": 0.0, "untrustedNegativeSteps": 0, "untrustedNegativeSec": 0.0,
           "firstUntrusted": None}
    for s, seconds in zip(steps, fd.step_seconds(steps)):
        if s["y"] not in fd.NEGATIVE or not s["w"] > 0:
            continue
        kind = "trusted" if inside(s["tick"], spans) else "untrusted"
        row[f"{kind}NegativeSteps"] += 1
        row[f"{kind}NegativeSec"] += seconds
        if kind == "untrusted" and row["firstUntrusted"] is None:
            row["firstUntrusted"] = {"tick": s["tick"], "state": v.STATE_NAMES[s["y"]]}
    row["trustedNegativeSec"], row["untrustedNegativeSec"] = round(row["trustedNegativeSec"], 3), round(row["untrustedNegativeSec"], 3)
    return row


def report(manifest: dict, rows: list, folds_doc: dict) -> dict:
    """Both gates for a dataset and a fold draw, from `coverage_of` rows (one per recording). Raises CoverageError
    for an audited (v2) dataset that holds an untrusted negative step."""
    labels = manifest["labelSchema"]["version"]
    audited = labels == AUDITED_LABELS
    untrusted = [r for r in rows if r["untrustedNegativeSteps"]]
    if audited and untrusted:
        shown = "; ".join(f"{r['recordingId']} ({r['untrustedNegativeSteps']} step(s), first {r['firstUntrusted']['state']} at tick "
                          f"{r['firstUntrusted']['tick']}; {r['whyNone'] or 'outside its reviewed-clean intervals'})" for r in untrusted[:5])
        raise CoverageError(f"{sum(r['untrustedNegativeSteps'] for r in untrusted)} negative step(s) with loss weight in {len(untrusted)} recording(s) "
                            f"lie outside every reviewed-clean interval of a recording without Stage 1 verified coverage — {labels} allows none: "
                            + shown + (" …" if len(untrusted) > 5 else ""))
    fold_of = {g["groupId"]: g["fold"] for g in folds_doc["groups"]}
    groups = [{"groupId": gid, "fold": fold_of[gid],
               "recordings": sorted(r["recordingId"] for r in rows if r["groupId"] == gid),
               "trustedNegativeSec": round(sum(r["trustedNegativeSec"] for r in rows if r["groupId"] == gid), 3),
               "untrustedNegativeSec": round(sum(r["untrustedNegativeSec"] for r in rows if r["groupId"] == gid), 3)}
              for gid in sorted(fold_of)]
    contributing = [g for g in groups if g["trustedNegativeSec"] > 0]
    required = -(-G6_FRACTION[0] * len(groups) // G6_FRACTION[1])
    per_fold = []
    for f in range(folds_doc["folds"]):
        mine = [g for g in groups if g["fold"] == f]
        per_fold.append({"fold": f, "groups": len(mine),
                         "groupsWithTrustedNegatives": [g["groupId"] for g in mine if g["trustedNegativeSec"] > 0],
                         "groupsWithout": [g["groupId"] for g in mine if g["trustedNegativeSec"] <= 0],
                         "trustedNegativeSec": round(sum(g["trustedNegativeSec"] for g in mine), 3),
                         "untrustedNegativeSec": round(sum(g["untrustedNegativeSec"] for g in mine), 3)})
    g6 = []
    if len(contributing) < required:
        g6.append(f"{len(contributing)} of {len(groups)} groups contribute trusted negatives; at least {required} are required "
                  f"(two-thirds, rounded up): {required - len(contributing)} short. Groups without: "
                  + ", ".join(g["groupId"] for g in groups if g["trustedNegativeSec"] <= 0))
    for p in per_fold:
        have = len(p["groupsWithTrustedNegatives"])
        if have < G6_GROUPS_PER_FOLD:
            g6.append(f"fold {p['fold']}: {have} group(s) with trusted negatives ({', '.join(p['groupsWithTrustedNegatives']) or 'none'}); "
                      f"at least {G6_GROUPS_PER_FOLD} are required: {G6_GROUPS_PER_FOLD - have} short. Groups without: {', '.join(p['groupsWithout'])}")
    steps, seconds = sum(r["untrustedNegativeSteps"] for r in untrusted), round(sum(r["untrustedNegativeSec"] for r in untrusted), 3)
    g7 = [f"{steps} negative step(s) with loss weight ({seconds} s) in {len(untrusted)} recording(s) are declared, not audited: "
          "they lie in no reviewed-clean interval and under no Stage 1 verified coverage"] if untrusted else []
    return {
        "policy": POLICY, "labelSchema": labels,
        "negativeLabels": ("audited" if audited else "declared, not audited" if untrusted
                           else "none declared: Stage 1 verified coverage only"),
        "g7": {"met": not g7, "deficiencies": g7}, "g6": {"met": not g6, "deficiencies": g6},
        "met": not g7 and not g6, "deficiencies": [f"G7: {d}" for d in g7] + [f"G6: {d}" for d in g6],
        "groups": len(groups), "groupsWithTrustedNegatives": len(contributing), "groupsRequired": required,
        "groupsRequiredPerFold": G6_GROUPS_PER_FOLD,
        "trustedNegativeSteps": sum(r["trustedNegativeSteps"] for r in rows),
        "trustedNegativeSec": round(sum(r["trustedNegativeSec"] for r in rows), 3),
        "untrustedNegativeSteps": steps, "untrustedNegativeSec": seconds,
        "recordingsBySource": {name: sum(1 for r in rows if r["source"] == name) for name in (STAGE1, CLEAN, NONE)},
        "perFold": per_fold, "perGroup": groups, "perRecording": rows,
    }


def markdown(doc: dict) -> list:
    """The gates as lines of a report."""
    out = ["## Trusted negatives (G7) and the negative-coverage gate (G6)", "", doc["policy"], "",
           f"Label schema `{doc['labelSchema']}` — negatives **{doc['negativeLabels']}**. Recordings by source of trust: "
           f"{doc['recordingsBySource'][STAGE1]} Stage 1 verified, {doc['recordingsBySource'][CLEAN]} with reviewed-clean intervals, "
           f"{doc['recordingsBySource'][NONE]} supplying none.", "",
           f"- **G7: {'met' if doc['g7']['met'] else 'NOT MET'}** — {doc['trustedNegativeSteps']} trusted negative steps "
           f"({doc['trustedNegativeSec']} s); {doc['untrustedNegativeSteps']} untrusted ({doc['untrustedNegativeSec']} s).",
           f"- **G6: {'met' if doc['g6']['met'] else 'NOT MET'}** — {doc['groupsWithTrustedNegatives']} of {doc['groups']} groups contribute "
           f"trusted negatives (required: {doc['groupsRequired']}; per fold: {doc['groupsRequiredPerFold']}).", "",
           "| fold | groups | with trusted negatives | trusted negative s | untrusted negative s |", "|---|---|---|---|---|"]
    out += [f"| {p['fold']} | {p['groups']} | {len(p['groupsWithTrustedNegatives'])} | {p['trustedNegativeSec']} | {p['untrustedNegativeSec']} |"
            for p in doc["perFold"]]
    return out + [""] + ([f"- {d}" for d in doc["deficiencies"]] + [""] if doc["deficiencies"] else [])
