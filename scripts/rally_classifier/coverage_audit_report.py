#!/usr/bin/env python3
"""Results of the negative-coverage audit (docs/ml-roadmap/RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md §5–§8, as
amended by RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL_AMENDMENT_1.md and …_AMENDMENT_2.md).

Reads a frozen draw (`coverage_audit_draw_v2`) and the audit records the review wrote —
`<video>.coverageaudit.json` (`coverage_audit_v2`) beside each drawn recording's marks, found through the project's
dataset sessions — and reports, per recording and in total: the intervals reviewed and not reviewed; each finding
kind's count and seconds; the recording's derived state; the repeat's agreement per verdict class, labelled by its
method; *m*, *n*, the exact one-sided Clopper–Pearson upper 90 % bound on *m/n* and pass / fail; and the recording
groups (and groups per fold) whose reviewed-clean intervals would supply trusted negatives, against gate G6.

It never certifies anything itself: a verdict exists only where a record holds one. A record is void — every
interval of that recording counts as not reviewed — when it is for another draw, dataset or file identity, or was
not made blind to the pipeline. Pass / fail is evaluated only when every interval of the pilot has a first verdict
given over the interval played whole; until then the outcome is `incomplete` and what is missing is listed.
Amendment 2 (D-041): no blind repeat is owed and none is taken, so the first look is the verdict and the result is
reported as a single look. A record that holds a repeat verdict is still read as the protocol says — its agreement is
reported, and a disagreement counts for nothing until a resolution settles it. No video is opened and nothing is written unless `--json-out` names a new file.

    python3 scripts/rally_classifier/coverage_audit_report.py <pilot draw.json> --project <project dir>
        [--stage2 <stage 2 draw.json>] [--json-out <report.json>]

Exit status 0 only when the pilot passes; 1 when it fails, is incomplete, or the inputs are refused.
Standard library only.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import coverage_audit_inventory as inv  # noqa: E402
import validate_dataset as v  # noqa: E402

DRAW_VERSION = "coverage_audit_draw_v2"
RECORD_VERSION = "coverage_audit_v2"
REPORT_VERSION = "coverage_audit_report_v2"
STAGES = ("pilot", "stage2")
FINDING_KINDS = ("missed_rally", "missed_serve", "boundary_error", "non_rally_activity", "edited_footage", "uncertain")
MISSED_KINDS = ("missed_rally", "missed_serve")          # what m counts, and what makes a recording contaminated
PARTIAL_KINDS = ("boundary_error", "uncertain")           # what leaves a recording partial
FINDING_EDGES = {"missed_rally": ("start", "end"), "boundary_error": ("leading", "trailing")}
REPEAT_METHODS = ("second_reviewer", "same_reviewer_after_24h")
SAME_REVIEWER_WAIT = datetime.timedelta(hours=24)
MAX_COVERAGE_RATE = 3.0             # `clean` needs the whole interval played at no more than this rate (amendment 1, D-040)
FIRST_COVERAGE_RATE = 2.0           # the protocol's first limit: a clean look played faster is counted apart
CONFIDENCE = 0.90                   # one-sided
MAX_UPPER_BOUND = 0.05              # the bound on m/n the pilot must meet
MAX_MISSED_PER_RECORDING = 2
G6_NUMERATOR, G6_DENOMINATOR = 2, 3     # gate G6 (amendment A3): at least two-thirds of the dataset's groups…
G6_MIN_GROUPS_PER_FOLD = 2              # …and at least two such groups in every fold


# ----------------------------------------------------------------------------- the bound

def binomial_cdf(k: int, n: int, p: float) -> float:
    """P(X <= k) for X ~ Binomial(n, p), summed in log space."""
    if k >= n or p <= 0.0:
        return 1.0
    if p >= 1.0:
        return 0.0
    log_p, log_q = math.log(p), math.log1p(-p)
    return math.fsum(math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * log_p + (n - i) * log_q)
                     for i in range(k + 1))


def upper_bound(m: int, n: int, confidence: float = CONFIDENCE) -> float:
    """The exact one-sided (Clopper–Pearson) upper confidence bound on a binomial proportion with m of n: the p at
    which P(X <= m | n, p) falls to 1 − confidence, found by bisection. 1.0 when m >= n."""
    if n <= 0 or m < 0:
        raise inv.AuditError(f"the bound needs n > 0 and m >= 0 (got m={m}, n={n})")
    if m >= n:
        return 1.0
    alpha, lo, hi = 1.0 - confidence, m / n, 1.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if binomial_cdf(m, n, mid) > alpha:
            lo = mid
        else:
            hi = mid
    return hi


def largest_passing_m(n: int) -> int | None:
    """The most missed rallies and serves among n rally marks whose bound is still within MAX_UPPER_BOUND; None when
    even m = 0 is not (n too small to show 5 % at 90 %)."""
    m = -1
    while m + 1 < n and upper_bound(m + 1, n) <= MAX_UPPER_BOUND:
        m += 1
    return m if m >= 0 else None


# ----------------------------------------------------------------------------- reading

def read_draw(path: str) -> tuple[dict, str]:
    """A draw file and the SHA-256 of its bytes (what every audit record of it names)."""
    draw = inv.load_json(path, "draw")
    if not isinstance(draw, dict) or draw.get("schemaVersion") != DRAW_VERSION or draw.get("stage") not in STAGES:
        raise inv.AuditError(f"{path}: not a {DRAW_VERSION} draw")
    for key in ("drawId", "dataset", "recordings", "seed"):
        if key not in draw:
            raise inv.AuditError(f"{path}: draw missing {key!r}")
    return draw, v.sha256_file(path)


def _parse_time(text) -> datetime.datetime | None:
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def _verdict(entry, time_key: str, needs_coverage: bool) -> tuple[Counter | None, str | None]:
    """One verdict entry as (its class, None) or (None, why it is not accepted). The class is a Counter of finding
    kinds — empty for `clean` — so two looks agree exactly when their classes are equal."""
    if not isinstance(entry, dict):
        return None, "not an object"
    if not isinstance(entry.get("reviewer"), str) or not entry["reviewer"].strip():
        return None, "no reviewer"
    if _parse_time(entry.get(time_key)) is None:
        return None, f"{time_key} is not a UTC time (YYYY-MM-DDTHH:MM:SSZ)"
    findings = entry.get("findings") or []
    if not isinstance(findings, list):
        return None, "findings is not a list"
    rate = entry.get("playedAllAtMaxRate")
    if entry.get("verdict") == "clean":
        if findings:
            return None, "clean with findings"
        if needs_coverage or rate is not None:
            if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not (0 < rate <= MAX_COVERAGE_RATE):
                return None, f"clean without playedAllAtMaxRate in (0, {MAX_COVERAGE_RATE}]: the whole interval must have been played"
        return Counter(), None
    if entry.get("verdict") != "not_clean":
        return None, f"verdict {entry.get('verdict')!r}"
    if not findings:
        return None, "not_clean without a finding"
    for f in findings:
        if not isinstance(f, dict) or f.get("kind") not in FINDING_KINDS:
            return None, f"finding kind {f.get('kind') if isinstance(f, dict) else f!r}"
        times = [f.get(k) for k in ("approxStartSec", "approxEndSec")]
        if any(t is not None and (isinstance(t, bool) or not isinstance(t, (int, float)) or not math.isfinite(t)) for t in times):
            return None, f"{f['kind']}: approximate times must be numbers"
        if None not in times and times[1] < times[0]:
            return None, f"{f['kind']}: approxEndSec before approxStartSec"
        if f.get("edge") is not None and f["edge"] not in FINDING_EDGES.get(f["kind"], ()):
            return None, f"{f['kind']}: edge {f['edge']!r}"
        if f["kind"] == "uncertain" and not (isinstance(f.get("note"), str) and f["note"].strip()):
            return None, "uncertain without a note"
    return Counter(f["kind"] for f in findings), None


def _played_whole(entry) -> bool:
    """Whether a look covered its whole interval (`playedAllAtMaxRate` in (0, 3]). A look that gave findings before
    the interval had played whole is unfinished: its findings stand, and the interval waits for the rest of it."""
    rate = entry.get("playedAllAtMaxRate")
    return not isinstance(rate, bool) and isinstance(rate, (int, float)) and 0 < rate <= MAX_COVERAGE_RATE


def _by_index(entries, what: str, problems: list) -> dict:
    """Entries keyed by interval index; an index given twice is ambiguous and none of its entries is taken."""
    out, twice = {}, set()
    for e in entries if isinstance(entries, list) else []:
        index = e.get("index") if isinstance(e, dict) else None
        if isinstance(index, bool) or not isinstance(index, int):
            problems.append(f"{what}: an entry without an interval index")
        elif index in out or index in twice:
            twice.add(index)
            out.pop(index, None)
        else:
            out[index] = e
    problems.extend(f"{what}: interval {i} is recorded more than once; none is taken" for i in sorted(twice))
    return out


def _void_reasons(record, rec: dict, draw: dict, draw_sha: str) -> list:
    """Why a record cannot be used for this draw at all; empty when it can."""
    if not isinstance(record, dict):
        return ["not an object"]
    checks = [("annotationVersion", RECORD_VERSION), ("recordingId", rec["recordingId"]), ("drawId", draw["drawId"]),
              ("drawSha256", draw_sha), ("datasetName", draw["dataset"]["name"]), ("timescale", draw["dataset"]["timescale"]),
              ("sourceFingerprint", rec["contentFingerprint"]), ("blindToPipeline", True)]
    return [f"{key} is {record.get(key)!r}, not {want!r}" for key, want in checks if record.get(key) != want]


# ----------------------------------------------------------------------------- one recording

def review_recording(rec: dict, draw: dict, draw_sha: str, record, ignore_ticks: int) -> dict:
    """What one drawn recording's audit record says, interval by interval. `record` is the parsed sidecar or None."""
    timescale = draw["dataset"]["timescale"]
    problems: list = []
    void = _void_reasons(record, rec, draw, draw_sha) if record is not None else []
    usable = record is not None and not void
    if void:
        problems.append("record void: " + "; ".join(void))

    firsts = _by_index(record.get("intervals"), "intervals", problems) if usable else {}
    repeat_block = record.get("repeat") if usable and isinstance(record.get("repeat"), dict) else {}
    method = repeat_block.get("method")
    if repeat_block and method not in REPEAT_METHODS:
        problems.append(f"repeat: method {method!r} is not one of {list(REPEAT_METHODS)}; no repeat verdict is taken")
        repeat_block = {}
    repeats = _by_index(repeat_block.get("intervals"), "repeat", problems)
    resolutions = _by_index(record.get("resolutions"), "resolutions", problems) if usable else {}

    drawn = {iv["index"]: iv for iv in rec["intervals"]}
    for index in sorted(set(firsts) | set(repeats) | set(resolutions)):
        if index not in drawn:
            problems.append(f"interval {index} is not in the draw")

    intervals = []
    # Agreement by who made the repeat — the method is the reviewer's, interval by interval: a record whose block says
    # same_reviewer_after_24h can hold a second reviewer's repeats too (RallyLab labels the block so when any repeat
    # is the first reviewer's); a block that says second_reviewer never holds one of the first reviewer's.
    agreement = {m: {"compared": 0, "identical": 0, "byClass": {c: {"both": 0, "firstOnly": 0, "repeatOnly": 0} for c in ("clean",) + FINDING_KINDS}}
                 for m in REPEAT_METHODS}
    for index, iv in sorted(drawn.items()):
        seconds = (iv["endTick"] - iv["startTick"]) / timescale
        row = {"index": index, "startTick": iv["startTick"], "endTick": iv["endTick"], "seconds": seconds,
               "reviewed": False, "repeated": False,
               "disagreement": False, "resolved": False, "settled": False, "unfinished": False, "fast": False, "verdict": None, "findings": []}
        first = firsts.get(index)
        first_class = None
        if first is not None:
            if (first.get("startTick"), first.get("endTick")) != (iv["startTick"], iv["endTick"]):
                problems.append(f"interval {index}: recorded bounds {first.get('startTick')}–{first.get('endTick')} are not the draw's")
            else:
                first_class, why = _verdict(first, "reviewedAt", needs_coverage=True)
                if why:
                    problems.append(f"interval {index}: first verdict not accepted — {why}")
        if first_class is None:
            intervals.append(row)
            continue
        row["reviewed"] = True
        effective, effective_entry = first_class, first
        looks = [first]

        repeat = repeats.get(index)
        repeat_class = None
        if repeat is not None:
            repeat_class, why = _verdict(repeat, "reviewedAt", needs_coverage=False)
            if not why:
                same = repeat["reviewer"] == first["reviewer"]
                waited = _parse_time(repeat["reviewedAt"]) - _parse_time(first["reviewedAt"]) >= SAME_REVIEWER_WAIT
                if same and method != "same_reviewer_after_24h":
                    why = "the repeat is by the first reviewer but the record calls it second_reviewer"
                elif same and not waited:
                    why = "a repeat by the same reviewer less than 24 h after the first verdict"
            if why:
                problems.append(f"interval {index}: repeat verdict not accepted — {why}")
                repeat_class = None
        if repeat_class is not None:
            row["repeated"] = True
            looks.append(repeat)
            by = agreement["same_reviewer_after_24h" if repeat["reviewer"] == first["reviewer"] else "second_reviewer"]
            by["compared"] += 1
            by["identical"] += first_class == repeat_class
            for c in ("clean",) + FINDING_KINDS:
                a = (not first_class) if c == "clean" else first_class[c] > 0
                b = (not repeat_class) if c == "clean" else repeat_class[c] > 0
                if a or b:
                    by["byClass"][c]["both" if a and b else "firstOnly" if a else "repeatOnly"] += 1
            row["disagreement"] = first_class != repeat_class

        resolution = resolutions.get(index)
        if resolution is not None and not row["disagreement"]:
            problems.append(f"interval {index}: a resolution without a disagreement between a first and a repeat verdict; not taken")
        elif resolution is not None:
            resolved_class, why = _verdict(resolution, "resolvedAt", needs_coverage=False)
            if why:
                problems.append(f"interval {index}: resolution not accepted — {why}")
            else:
                row["resolved"] = True
                looks.append(resolution)
                effective, effective_entry = resolved_class, resolution

        row["unfinished"] = not all(_played_whole(look) for look in looks)
        # Amendment 1 (D-040): a look played faster than the protocol's first limit is counted apart.
        row["fast"] = any(_played_whole(look) and look["playedAllAtMaxRate"] > FIRST_COVERAGE_RATE for look in looks)
        row["settled"] = (row["resolved"] or not row["disagreement"]) and not row["unfinished"]
        if row["resolved"] or not row["disagreement"]:
            row["verdict"] = "not_clean" if effective else "clean"
            row["findings"] = [{"kind": f["kind"],
                                "seconds": (f["approxEndSec"] - f["approxStartSec"]) if f.get("approxStartSec") is not None and f.get("approxEndSec") is not None
                                else (seconds if f["kind"] == "uncertain" else None)}
                               for f in effective_entry.get("findings") or []]
        intervals.append(row)

    counted = [r for r in intervals if r["verdict"] is not None]
    kinds = Counter(f["kind"] for r in counted for f in r["findings"])
    contaminated = any(kinds[k] for k in MISSED_KINDS)
    partial = any(not r["reviewed"] or r["verdict"] is None or r["unfinished"] for r in intervals) or any(kinds[k] for k in PARTIAL_KINDS)
    clean = [r for r in counted if r["verdict"] == "clean" and not r["unfinished"]]
    # A clean interval no longer than the two ignore bands at its ends holds only TRANSITION steps: no negative.
    trusted = [r for r in clean if r["endTick"] - r["startTick"] > 2 * ignore_ticks]
    return {
        "recordingId": rec["recordingId"], "groupId": rec["groupId"], "surface": rec["surface"], "fold": rec["fold"],
        "rallyMarks": rec["rallyMarks"], "record": "missing" if record is None else "void" if void else "read",
        "marksAtReview": record.get("marksSha256") if usable else None,
        "marksChangedSinceDraw": usable and record.get("marksSha256") != rec["marksSha256"],
        "state": "contaminated" if contaminated else "partial" if partial else "audited_clean",
        "contaminated": contaminated, "partial": partial,
        "intervals": len(intervals),
        "reviewed": sum(r["reviewed"] for r in intervals),
        "notReviewed": [r["index"] for r in intervals if not r["reviewed"]],
        "repeated": sum(r["repeated"] for r in intervals),
        "unfinished": [r["index"] for r in intervals if r["unfinished"]],
        "unresolved": [r["index"] for r in intervals if r["disagreement"] and not r["resolved"]],
        "secondsDrawn": sum(r["seconds"] for r in intervals),
        "secondsReviewed": sum(r["seconds"] for r in intervals if r["reviewed"]),
        "cleanIntervals": len(clean), "cleanSeconds": sum(r["seconds"] for r in clean),
        "cleanFastIntervals": sum(r["fast"] for r in clean), "cleanFastSeconds": sum(r["seconds"] for r in clean if r["fast"]),
        "findings": _finding_tally(counted),
        "missed": sum(kinds[k] for k in MISSED_KINDS),
        "suppliesTrustedNegatives": bool(trusted) and not kinds["edited_footage"],
        "agreement": agreement,
        "problems": problems,
    }


def _finding_tally(interval_rows: list) -> dict:
    """Per finding kind: how many, the seconds of those with approximate times (an `uncertain` finding without
    times takes its whole interval), and how many carry no times — their seconds are unknown, not zero."""
    out = {k: {"count": 0, "seconds": 0.0, "withoutTimes": 0} for k in FINDING_KINDS}
    for r in interval_rows:
        for f in r["findings"]:
            out[f["kind"]]["count"] += 1
            if f["seconds"] is None:
                out[f["kind"]]["withoutTimes"] += 1
            else:
                out[f["kind"]]["seconds"] += f["seconds"]
    return out


# ----------------------------------------------------------------------------- the report

def _read_records(draw: dict, draw_sha: str, project_dir: str) -> list:
    ignore_ticks = round(draw["dataset"]["boundaryIgnoreSec"] * draw["dataset"]["timescale"])
    out = []
    for rec in draw["recordings"]:
        path = inv.sidecar_path(inv.session_video(project_dir, rec["recordingId"]), "coverageaudit")
        record, sha = None, None
        if os.path.exists(path):
            # Read once: the bytes evaluated are the bytes hashed, so a record saved meanwhile can't pair its hash
            # with another's verdicts. A dataset exported from these records carries the same hash
            # (`coverage.audit.auditSha256`): a trainer can tell the records it trusts are the ones that passed.
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
                record, sha = json.loads(data.decode("utf-8")), hashlib.sha256(data).hexdigest()
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
                raise inv.AuditError(f"{rec['recordingId']}: audit record unreadable: {e}")
        row = review_recording(rec, draw, draw_sha, record, ignore_ticks)
        row["recordSha256"] = sha
        # The draw holds only recordings typed continuous. One a person has typed otherwise since (or whose type can
        # no longer be read) supplies no negative, whatever its record says — the inventory and the exporter's rule.
        row["typeNow"] = _type_now(project_dir, rec["recordingId"])
        if row["typeNow"] != "continuous":
            row["suppliesTrustedNegatives"] = False
        out.append(row)
    return out


def _type_now(project_dir: str, recording_id: str) -> str | None:
    """The recording's footage type as the project records it now; None when there is no record or it can't be read."""
    path = os.path.join(project_dir, "footage-properties", recording_id + ".json")
    try:
        with open(path, encoding="utf-8") as fh:
            typed = json.load(fh).get("recordingType")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, AttributeError):
        return None
    return typed if isinstance(typed, str) else None


def _sum_agreement(rows: list) -> dict:
    """The repeat's agreement by method. A repeat by the same reviewer is a repeat, never inter-rater agreement."""
    out = {}
    for row in rows:
        for method, a in row["agreement"].items():
            if not a["compared"]:
                continue
            total = out.setdefault(method, {"independent": method == "second_reviewer", "compared": 0, "identical": 0,
                                            "byClass": {c: {"both": 0, "firstOnly": 0, "repeatOnly": 0} for c in a["byClass"]}})
            total["compared"] += a["compared"]
            total["identical"] += a["identical"]
            for c, cell in a["byClass"].items():
                for k, n in cell.items():
                    total["byClass"][c][k] += n
    return out


def _totals(rows: list) -> dict:
    findings = {k: {"count": 0, "seconds": 0.0, "withoutTimes": 0} for k in FINDING_KINDS}
    for row in rows:
        for k, cell in row["findings"].items():
            for field, value in cell.items():
                findings[k][field] += value
    return {"recordings": len(rows), "intervals": sum(r["intervals"] for r in rows), "reviewed": sum(r["reviewed"] for r in rows),
            "notReviewed": sum(len(r["notReviewed"]) for r in rows), "repeated": sum(r["repeated"] for r in rows),
            "unfinished": sum(len(r["unfinished"]) for r in rows),
            "unresolved": sum(len(r["unresolved"]) for r in rows),
            "secondsDrawn": sum(r["secondsDrawn"] for r in rows), "secondsReviewed": sum(r["secondsReviewed"] for r in rows),
            "cleanIntervals": sum(r["cleanIntervals"] for r in rows), "cleanSeconds": sum(r["cleanSeconds"] for r in rows),
            "cleanFastIntervals": sum(r["cleanFastIntervals"] for r in rows), "cleanFastSeconds": sum(r["cleanFastSeconds"] for r in rows),
            "findings": findings,
            "states": dict(Counter(r["state"] for r in rows)), "alsoPartial": sum(r["contaminated"] and r["partial"] for r in rows),
            "agreement": _sum_agreement(rows)}


def _pilot_outcome(rows: list) -> dict:
    missing = {key: {r["recordingId"]: r[key] for r in rows if r[key]} for key in ("notReviewed", "unresolved", "unfinished")}
    n = sum(r["rallyMarks"] for r in rows)
    if any(missing.values()):
        return {"outcome": "incomplete", "missing": missing, "n": n,
                "note": "pass / fail is not evaluated while a pilot interval lacks a first verdict, holds a disagreement without a "
                        "resolution, or a look that counts gave findings before its interval had played whole"}
    m = sum(r["missed"] for r in rows)
    bound = upper_bound(m, n)
    worst = max(rows, key=lambda r: r["missed"])
    bound_ok, each_ok = bound <= MAX_UPPER_BOUND, worst["missed"] <= MAX_MISSED_PER_RECORDING
    return {"outcome": "pass" if bound_ok and each_ok else "fail", "m": m, "n": n, "estimate": m / n,
            "upperBound": bound, "confidence": CONFIDENCE, "maxUpperBound": MAX_UPPER_BOUND, "boundMet": bound_ok,
            "largestPassingM": largest_passing_m(n),
            "missedRallies": sum(r["findings"]["missed_rally"]["count"] for r in rows),
            "missedServes": sum(r["findings"]["missed_serve"]["count"] for r in rows),
            "mostInOneRecording": {"recordingId": worst["recordingId"], "missed": worst["missed"]},
            "maxPerRecording": MAX_MISSED_PER_RECORDING, "perRecordingMet": each_ok}


def _trusted_negatives(draw: dict, rows: list, pilot_passed: bool) -> dict:
    """Gate G6 over trusted negatives, estimated from the records: the groups with a recording that has a
    reviewed-clean interval longer than the ignore bands and no edited-footage finding. The export's own label
    counts are the authority; this says what the audit so far could supply."""
    groups = {}
    for r in rows:
        if r["suppliesTrustedNegatives"]:
            groups[r["groupId"]] = r["fold"]
    folds = range(draw["folds"]["folds"])
    per_fold = {str(f): sum(1 for fold in groups.values() if fold == f) for f in folds}
    need = -(-G6_NUMERATOR * draw["dataset"]["groups"] // G6_DENOMINATOR)
    short = [f"{need - len(groups)} group(s) short of {need} (two-thirds of {draw['dataset']['groups']})"] if len(groups) < need else []
    short += [f"fold {f} has {n} such group(s), fewer than {G6_MIN_GROUPS_PER_FOLD}" for f, n in per_fold.items() if n < G6_MIN_GROUPS_PER_FOLD]
    return {"usable": pilot_passed,
            "note": None if pilot_passed else "no negative is used until the pilot passes; the counts say what the records would supply",
            "groups": sorted(groups), "groupCount": len(groups), "groupsPerFold": per_fold,
            "g6": {"groupsRequired": need, "minGroupsPerFold": G6_MIN_GROUPS_PER_FOLD, "met": not short, "deficiency": short},
            "recordingsWithEditedFootage": sorted(r["recordingId"] for r in rows if r["findings"]["edited_footage"]["count"]),
            "recordingsNotContinuousNow": {r["recordingId"]: r["typeNow"] for r in sorted(rows, key=lambda r: r["recordingId"])
                                           if r["typeNow"] != "continuous"}}


def evaluate(draw_path: str, project_dir: str, stage2_path: str | None = None) -> dict:
    """The audit's results for a pilot draw and, when given, the stage 2 draw that follows it."""
    draw, draw_sha = read_draw(draw_path)
    if draw["stage"] != "pilot":
        raise inv.AuditError(f"{draw_path}: the report starts from the pilot draw (this one is {draw['stage']})")
    rows = _read_records(draw, draw_sha, project_dir)
    pilot = _pilot_outcome(rows)
    report = {"schemaVersion": REPORT_VERSION,
              "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "dataset": draw["dataset"],
              "pilot": {"drawId": draw["drawId"], "drawSha256": draw_sha, **pilot, "totals": _totals(rows), "recordings": rows}}
    all_rows = list(rows)
    if stage2_path:
        stage2, stage2_sha = read_draw(stage2_path)
        if stage2["stage"] != "stage2" or (stage2.get("follows") or {}).get("sha256") != draw_sha:
            raise inv.AuditError(f"{stage2_path}: not the stage 2 draw that follows {draw['drawId']}")
        stage2_rows = _read_records(stage2, stage2_sha, project_dir)
        report["stage2"] = {"drawId": stage2["drawId"], "drawSha256": stage2_sha, "totals": _totals(stage2_rows), "recordings": stage2_rows}
        all_rows += stage2_rows
    report["trustedNegatives"] = _trusted_negatives(draw, all_rows, pilot["outcome"] == "pass")
    return report


def render(report: dict) -> str:
    def seconds(x):
        return f"{x:.1f} s"

    def block(title, part):
        t = part["totals"]
        lines = [f"{title} — draw {part['drawId']} ({part['drawSha256'][:16]}…)",
                 f"  {t['recordings']} recording(s); intervals reviewed {t['reviewed']} of {t['intervals']} "
                 f"({seconds(t['secondsReviewed'])} of {seconds(t['secondsDrawn'])}); not reviewed {t['notReviewed']}; "
                 f"unresolved {t['unresolved']}",
                 f"  single look (amendment 2): no blind repeat is owed; second looks on record: {t['repeated']}",
                 f"  clean: {t['cleanIntervals']} interval(s), {seconds(t['cleanSeconds'])}; of them with a look played faster than "
                 f"{FIRST_COVERAGE_RATE:g}× (amendment 1): {t['cleanFastIntervals']} interval(s), {seconds(t['cleanFastSeconds'])}"]
        for k in FINDING_KINDS:
            cell = t["findings"][k]
            unknown = f" (+{cell['withoutTimes']} without times)" if cell["withoutTimes"] else ""
            lines.append(f"  {k}: {cell['count']}, {seconds(cell['seconds'])}{unknown}")
        lines.append("  recording states: " + (", ".join(f"{k} {n}" for k, n in sorted(t["states"].items())) or "none")
                     + (f" ({t['alsoPartial']} contaminated also partial)" if t["alsoPartial"] else ""))
        for method, a in sorted(t["agreement"].items()):
            label = "second reviewer" if a["independent"] else "repeat by the same reviewer after 24 h — not independent inter-rater agreement"
            per_class = "; ".join(f"{c} {cell['both']}/{cell['both'] + cell['firstOnly'] + cell['repeatOnly']}"
                                  for c, cell in a["byClass"].items() if cell["both"] + cell["firstOnly"] + cell["repeatOnly"])
            lines.append(f"  repeat ({label}): identical on {a['identical']} of {a['compared']}; by class {per_class}")
        for r in part["recordings"]:
            found = ", ".join(f"{k} {cell['count']}" for k, cell in r["findings"].items() if cell["count"]) or "no finding"
            lines.append(f"  {r['recordingId']} [{r['surface']}, group {r['groupId']}, fold {r['fold']}] {r['state']}"
                         f"{' + partial' if r['contaminated'] and r['partial'] else ''}: reviewed {r['reviewed']}/{r['intervals']} "
                         f"({seconds(r['secondsReviewed'])} of {seconds(r['secondsDrawn'])}), clean {r['cleanIntervals']}, {found}, record {r['record']}"
                         f"{', marks changed since the draw' if r['marksChangedSinceDraw'] else ''}"
                         + ("" if r["typeNow"] == "continuous" else f", {_typed(r['typeNow'])}: no negatives, whatever its record says"))
            lines += [f"    ! {p}" for p in r["problems"]]
        return lines

    p = report["pilot"]
    lines = [f"Coverage audit of {report['dataset']['name']}"] + block("Pilot", p)
    if p["outcome"] == "incomplete":
        lines.append(f"  PILOT INCOMPLETE — {p['note']}")
        for key, label in (("notReviewed", "no first verdict"), ("unresolved", "disagreement unresolved"),
                           ("unfinished", "findings given before the interval played whole")):
            lines += [f"    {label} — {rid}: intervals {indices}" for rid, indices in sorted(p["missing"][key].items())]
    else:
        lines.append(f"  PILOT {p['outcome'].upper()} — m = {p['m']} ({p['missedRallies']} missed rallies, {p['missedServes']} missed serves) "
                     f"of n = {p['n']} rally marks: {p['estimate']:.2%}, one-sided {p['confidence']:.0%} upper bound {p['upperBound']:.2%} "
                     f"(must be ≤ {p['maxUpperBound']:.0%}; largest passing m for this n is {p['largestPassingM']}); "
                     f"most in one recording {p['mostInOneRecording']['missed']} in {p['mostInOneRecording']['recordingId']} "
                     f"(must be ≤ {p['maxPerRecording']})")
    if "stage2" in report:
        lines += block("Stage 2", report["stage2"])
    tn = report["trustedNegatives"]
    lines.append(f"Trusted negatives (estimate from the records{'' if tn['usable'] else '; ' + tn['note']}): "
                 f"{tn['groupCount']} group(s), per fold {tn['groupsPerFold']}; G6 needs {tn['g6']['groupsRequired']} groups and "
                 f"{tn['g6']['minGroupsPerFold']} per fold — {'met' if tn['g6']['met'] else 'NOT met: ' + '; '.join(tn['g6']['deficiency'])}")
    if tn["recordingsWithEditedFootage"]:
        lines.append("  edited footage found in a recording typed continuous (no negatives until the type is re-confirmed): "
                     + ", ".join(tn["recordingsWithEditedFootage"]))
    if tn["recordingsNotContinuousNow"]:
        lines.append("  no longer typed continuous in the project (no negatives; not counted above): "
                     + ", ".join(f"{rid} ({_typed(t)})" for rid, t in tn["recordingsNotContinuousNow"].items()))
    return "\n".join(lines)


def _typed(type_now) -> str:
    return f"typed {type_now!r} now" if type_now else "no readable footage-type record now"


# ----------------------------------------------------------------------------- CLI

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("draw", help="the pilot draw (coverage_audit_draw_v2)")
    ap.add_argument("--project", required=True, help="the RallyLab project folder (its dataset sessions say where the audit records lie)")
    ap.add_argument("--stage2", help="the stage 2 draw that follows the pilot")
    ap.add_argument("--json-out", help="also write the report as JSON to this file (must not exist)")
    args = ap.parse_args(argv)
    try:
        report = evaluate(args.draw, args.project, args.stage2)
        if args.json_out:
            inv.write_new_json(args.json_out, report)
    except inv.AuditError as e:
        print(f"error: {e}")
        return 1
    print(render(report))
    return 0 if report["pilot"]["outcome"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
