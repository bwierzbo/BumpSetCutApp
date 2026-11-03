#!/usr/bin/env python3
"""Validate a rally-classifier dataset (``rally_classifier_dataset_v1``).

The contract is docs/ml-roadmap/RALLY_CLASSIFIER_DATASET_CONTRACT.md. This tool is
the fail-closed backstop a trainer runs before reading a dataset: it checks the
manifest, every steps file, the feature and label schemas, the label states
against the recording's rallies and spans, group/split integrity, and — first of
all — that no withheld recording is present. Standard library only; it reads only
the dataset folder (and, optionally, a withheld-closure file) and writes nothing
unless asked to write the synthetic example.

    python3 scripts/rally_classifier/validate_dataset.py <dataset dir> [--withheld closure.json] [--json]
    python3 scripts/rally_classifier/validate_dataset.py --write-synthetic <dir> [--seed N]

Exit status 0 when there is no error, 1 otherwise. Warnings never fail the run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import sys

SCHEMA_VERSION = "rally_classifier_dataset_v1"
FEATURE_VERSION = "rcf_v1"
LABEL_VERSION = "rally_activity_truth_v1"
TIMESCALE = 600
GAP_SEC = 0.5           # a gap between processed frames longer than this breaks the segment
TICK_TOLERANCE = 0      # tick must equal round(t * TIMESCALE) exactly

# name, nullable, kind, lookaheadSec — the order is the column order of `f`.
FEATURES = [
    ("dt", True, "raw", 0.0),
    ("has_ball", False, "raw", 0.0),
    ("n_court_dets", False, "raw", 0.0),
    ("n_dets", False, "raw", 0.0),
    ("max_conf", True, "raw", 0.0),
    ("ball_y_any", True, "raw", 0.0),
    ("is_projectile", False, "raw", 0.0),
    ("sel_x", True, "raw", 0.0),
    ("sel_y", True, "raw", 0.0),
    ("sel_size", True, "raw", 0.0),
    ("r2", True, "raw", 0.0),
    ("grav", True, "raw", 0.0),
    ("n_cands", False, "raw", 0.0),
    ("n_cands_proj", False, "raw", 0.0),
    ("n_cands_rejected", False, "raw", 0.0),
    ("y_above_net", True, "raw", 0.0),
    ("serve_emitted", False, "raw", 0.0),
    ("serve_contact_offset", True, "raw", 0.0),
]
FEATURE_INDEX = {name: i for i, (name, _, _, _) in enumerate(FEATURES)}
BINARY = {"has_ball", "is_projectile", "serve_emitted"}
COUNTS = {"n_court_dets", "n_dets", "n_cands", "n_cands_proj", "n_cands_rejected"}
UNIT = {"max_conf", "ball_y_any", "sel_x", "sel_y", "r2", "grav"}

STATES = {"NON_RALLY": 0, "ACTIVE_RALLY": 1, "TRANSITION": 2, "UNKNOWN": 3, "EXCLUDED": 4, "NON_RALLY_ACTIVITY": 5}
WEIGHTS = {"0": 1.0, "1": 1.0, "2": 0.0, "3": 0.0, "4": 0.0, "5": 1.0}
STATE_NAMES = {v: k for k, v in STATES.items()}

SPLITS = {"train", "dev_val", "tune"}
ELIGIBLE = {"standard", "restricted"}
LEVELS = {"standard", "restricted", "not_assessed", "quarantined", "ineligible"}
COVERAGE = {"declared_complete", "stage1_complete", "partial", "none"}
COMPLETE = {"declared_complete", "stage1_complete"}
PROVENANCE = {"legacy_declared", "legacy_nil_kind", "stage1_reviewed"}
EXCLUDED_KINDS = {"missedServe", "other"}
RECORDING_TYPES = {"continuous", "edited", "unknown"}
TB_TRAITS = {"slow_motion", "replay", "montage", "camera_angle_change"}
STEP_KEYS = {"t", "tick", "seg", "f", "y", "w"}
RECORDING_KEYS = {
    "recordingId", "sourceId", "fingerprint", "groupId", "split", "fold", "surface", "camera", "orientation",
    "originKind", "uploader", "durationSec", "frameRateNominal", "vfr", "aspect", "upright", "net",
    "recordingType", "eligibility", "restrictedUse", "coverage", "labelProvenance", "rallies", "excludedSpans",
    "cutRanges", "timeBreakingSpans", "nonRallyActivitySpans", "exposure", "stepsFile", "stepsSha256",
    "stepCount", "labelCounts",
}
MANIFEST_KEYS = {
    "schemaVersion", "createdAt", "generator", "project", "splitManifest", "withheld", "detector",
    "pipelineConfigSha256", "timescale", "samplingHzNominal", "featureSchema", "labelSchema", "recordings",
}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def closure_sha256(names, source_ids, fingerprints) -> str:
    canon = json.dumps({"names": sorted(names), "sourceIds": sorted(source_ids), "fingerprints": sorted(fingerprints)},
                       sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def feature_schema() -> dict:
    return {"version": FEATURE_VERSION,
            "features": [{"name": n, "nullable": nullable, "kind": kind, "lookaheadSec": la} for n, nullable, kind, la in FEATURES]}


def label_schema(boundary_ignore_sec: float = 0.5) -> dict:
    return {"version": LABEL_VERSION, "states": dict(STATES), "weights": dict(WEIGHTS), "boundaryIgnoreSec": boundary_ignore_sec}


class Report:
    def __init__(self):
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.info: dict = {}

    def error(self, msg: str):
        self.errors.append(msg)

    def warn(self, msg: str):
        self.warnings.append(msg)

    @property
    def ok(self) -> bool:
        return not self.errors

    def as_dict(self) -> dict:
        return {"ok": self.ok, "errors": self.errors, "warnings": self.warnings, "info": self.info}


# ----------------------------------------------------------------------------- label rule

def _inside(tick: int, span) -> bool:
    return span["startTick"] <= tick < span["endTick"]


def expected_state(tick: int, rec: dict, ignore_ticks: int) -> int:
    """The contract's §5 rule: EXCLUDED > TRANSITION > ACTIVE_RALLY > NON_RALLY_ACTIVITY > NON_RALLY > UNKNOWN."""
    for span in rec["cutRanges"] + rec["timeBreakingSpans"] + rec["excludedSpans"]:
        if _inside(tick, span):
            return STATES["EXCLUDED"]
    for r in rec["rallies"]:
        half_start = max(ignore_ticks, r.get("contactUncertaintyTicks") or 0)
        half_end = max(ignore_ticks, r.get("deadUncertaintyTicks") or 0)
        if abs(tick - r["startTick"]) < half_start or abs(tick - r["endTick"]) < half_end:
            return STATES["TRANSITION"]
    for span in rec["excludedSpans"]:
        if abs(tick - span["startTick"]) < ignore_ticks or abs(tick - span["endTick"]) < ignore_ticks:
            return STATES["TRANSITION"]
    for r in rec["rallies"]:
        if _inside(tick, r):
            return STATES["ACTIVE_RALLY"]
    for span in rec["nonRallyActivitySpans"]:
        if _inside(tick, span):
            return STATES["NON_RALLY_ACTIVITY"]
    if rec["eligibility"]["fullVideoNegatives"] == "standard" and rec["coverage"]["state"] in COMPLETE:
        return STATES["NON_RALLY"]
    return STATES["UNKNOWN"]


def crosses_non_footage(prev_tick: int, tick: int, rec: dict) -> bool:
    """True when a boundary of a cut range or a time-breaking span lies in (prev_tick, tick]: the segment must
    break there. Testing the boundaries, not the endpoints' membership, catches a span that falls entirely
    between two processed frames."""
    for span in rec["cutRanges"] + rec["timeBreakingSpans"]:
        for b in (span["startTick"], span["endTick"]):
            if prev_tick < b <= tick:
                return True
    return False


# ----------------------------------------------------------------------------- validation

def _check_spans(spans, where: str, rep: Report, kinds=None, extra_keys=()):
    for i, s in enumerate(spans):
        if not isinstance(s, dict) or not {"startTick", "endTick"} <= set(s):
            rep.error(f"{where}[{i}]: a span needs startTick and endTick")
            continue
        if not (isinstance(s["startTick"], int) and isinstance(s["endTick"], int)) or s["startTick"] >= s["endTick"]:
            rep.error(f"{where}[{i}]: ticks must be integers with startTick < endTick (got {s['startTick']}, {s['endTick']})")
        if kinds is not None and s.get("kind") not in kinds:
            rep.error(f"{where}[{i}]: kind {s.get('kind')!r} not in {sorted(kinds)}")
        for k in extra_keys:
            if k not in s:
                rep.error(f"{where}[{i}]: missing {k}")


def _check_feature_value(name: str, nullable: bool, v, rec: dict, rep: Report, where: str):
    if v is None:
        if not nullable:
            rep.error(f"{where}: {name} is null but not nullable")
        return
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        rep.error(f"{where}: {name} must be a finite number (got {v!r})")
        return
    if name in BINARY and v not in (0, 1):
        rep.error(f"{where}: {name} must be 0 or 1 (got {v})")
    elif name in COUNTS and (v < 0 or int(v) != v):
        rep.error(f"{where}: {name} must be a non-negative integer (got {v})")
    elif name in UNIT and not (0.0 <= v <= 1.0):
        rep.error(f"{where}: {name} must lie in [0, 1] (got {v})")
    elif name == "dt" and v <= 0:
        rep.error(f"{where}: dt must be positive (got {v})")
    elif name in ("sel_size", "serve_contact_offset") and v < 0:
        rep.error(f"{where}: {name} must be non-negative (got {v})")


def validate_steps(path: str, rec: dict, ignore_ticks: int, rep: Report) -> dict:
    """Validate one steps file against its recording record. Returns label counts and the line count."""
    counts = {name: 0 for name in STATES}
    n = 0
    prev_t = None
    prev_tick = None
    prev_seg = None
    rid = rec["recordingId"]
    has_net = rec.get("net") is not None
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            where = f"{rid} line {lineno}"
            line = line.strip()
            if not line:
                rep.error(f"{where}: empty line")
                continue
            try:
                step = json.loads(line)
            except json.JSONDecodeError as e:
                rep.error(f"{where}: not JSON ({e})")
                continue
            n += 1
            if not isinstance(step, dict) or set(step) != STEP_KEYS:
                rep.error(f"{where}: keys must be exactly {sorted(STEP_KEYS)}")
                continue
            t, tick, seg, f, y, w = step["t"], step["tick"], step["seg"], step["f"], step["y"], step["w"]
            if not isinstance(t, (int, float)) or isinstance(t, bool) or not math.isfinite(t):
                rep.error(f"{where}: t must be a finite number")
                continue
            if prev_t is not None and t <= prev_t:
                rep.error(f"{where}: t {t} is not after the previous step's {prev_t}")
            if not isinstance(tick, int) or tick != round(t * TIMESCALE):
                rep.error(f"{where}: tick {tick!r} != round(t × {TIMESCALE}) = {round(t * TIMESCALE)}")
                tick = round(t * TIMESCALE)
            if not isinstance(f, list) or len(f) != len(FEATURES):
                rep.error(f"{where}: f must hold {len(FEATURES)} values (got {len(f) if isinstance(f, list) else type(f).__name__})")
            else:
                for (name, nullable, _, _), v in zip(FEATURES, f):
                    _check_feature_value(name, nullable, v, rec, rep, where)
                dt = f[FEATURE_INDEX["dt"]]
                if prev_t is None:
                    if dt is not None:
                        rep.error(f"{where}: the first step's dt must be null")
                elif dt is None or abs(dt - (t - prev_t)) > 1e-6:
                    rep.error(f"{where}: dt {dt} != t − previous t = {t - prev_t:.6f}")
                nc, npj, nrj = f[FEATURE_INDEX["n_cands"]], f[FEATURE_INDEX["n_cands_proj"]], f[FEATURE_INDEX["n_cands_rejected"]]
                if isinstance(nc, (int, float)) and isinstance(npj, (int, float)) and npj > nc:
                    rep.error(f"{where}: n_cands_proj {npj} > n_cands {nc}")
                if isinstance(nc, (int, float)) and isinstance(nrj, (int, float)) and nrj > nc:
                    rep.error(f"{where}: n_cands_rejected {nrj} > n_cands {nc}")
                if not has_net and f[FEATURE_INDEX["y_above_net"]] is not None:
                    rep.error(f"{where}: y_above_net must be null when the recording has no net")
                sel_y, ban = f[FEATURE_INDEX["sel_y"]], f[FEATURE_INDEX["y_above_net"]]
                if has_net and (sel_y is None) != (ban is None):
                    rep.error(f"{where}: y_above_net must be null exactly when sel_y is null")
                emitted, offset = f[FEATURE_INDEX["serve_emitted"]], f[FEATURE_INDEX["serve_contact_offset"]]
                if emitted in (0, 1) and (emitted == 0) != (offset is None):
                    rep.error(f"{where}: serve_contact_offset must be null exactly when serve_emitted is 0")
            # segments
            if prev_seg is None:
                if seg != 0:
                    rep.error(f"{where}: the first step's seg must be 0 (got {seg})")
            else:
                gap = (t - prev_t) > GAP_SEC
                crossing = crosses_non_footage(prev_tick, tick, rec)
                should_break = gap or crossing
                if should_break and seg != prev_seg + 1:
                    rep.error(f"{where}: seg must increment to {prev_seg + 1} at a {'gap' if gap else 'cut/time-breaking boundary'} (got {seg})")
                elif not should_break and seg != prev_seg:
                    rep.error(f"{where}: seg changed to {seg} without a gap or a non-footage boundary")
            # labels
            if not isinstance(y, int) or isinstance(y, bool) or y not in STATE_NAMES:
                rep.error(f"{where}: y {y!r} is not a label state code")
            else:
                exp = expected_state(tick, rec, ignore_ticks)
                if y != exp:
                    rep.error(f"{where}: y is {STATE_NAMES[y]} but the recording's rallies and spans say {STATE_NAMES[exp]} at tick {tick}")
                counts[STATE_NAMES[y]] += 1
                if not isinstance(w, (int, float)) or isinstance(w, bool) or w != WEIGHTS[str(y)]:
                    rep.error(f"{where}: w {w!r} != the weight of {STATE_NAMES[y]} ({WEIGHTS[str(y)]})")
            prev_t, prev_tick, prev_seg = t, tick, seg if isinstance(seg, int) else prev_seg
    if n == 0:
        rep.error(f"{rid}: the steps file is empty")
    return {"counts": counts, "lines": n}


def validate_recording(rec, i: int, m: dict, dataset_dir: str, rep: Report, withheld: dict, groups: dict, seen_ids: dict):
    where = f"recordings[{i}]"
    if not isinstance(rec, dict):
        rep.error(f"{where}: not an object")
        return
    missing = RECORDING_KEYS - set(rec)
    if missing:
        rep.error(f"{where}: missing keys {sorted(missing)}")
        return
    rid = rec["recordingId"]
    where = rid
    # protected material first
    if rid in withheld["names"]:
        rep.error(f"{where}: WITHHELD recording present (name in the closure)")
    if rec["sourceId"] and rec["sourceId"] in withheld["sourceIds"]:
        rep.error(f"{where}: WITHHELD recording present (sourceId {rec['sourceId']} in the closure)")
    if rec["fingerprint"] and rec["fingerprint"] in withheld["fingerprints"]:
        rep.error(f"{where}: WITHHELD recording present (fingerprint in the closure)")
    if rec["split"] not in SPLITS:
        rep.error(f"{where}: split {rec['split']!r} is not a development split {sorted(SPLITS)}")
    # eligibility
    el = rec["eligibility"]
    if not isinstance(el, dict) or not {"rallyClassifier", "fullVideoNegatives", "reasons"} <= set(el):
        rep.error(f"{where}: eligibility needs rallyClassifier, fullVideoNegatives, reasons")
        el = {"rallyClassifier": None, "fullVideoNegatives": None, "reasons": []}
    if el["rallyClassifier"] not in ELIGIBLE:
        rep.error(f"{where}: eligibility.rallyClassifier {el['rallyClassifier']!r} — only {sorted(ELIGIBLE)} may be in a dataset")
    if el["fullVideoNegatives"] not in LEVELS:
        rep.error(f"{where}: eligibility.fullVideoNegatives {el['fullVideoNegatives']!r} is not a level")
    if el["rallyClassifier"] == "restricted":
        if not el["reasons"]:
            rep.error(f"{where}: restricted eligibility needs at least one reason")
        if rec["restrictedUse"] is not True:
            rep.error(f"{where}: restrictedUse must be true for a restricted recording")
    elif el["rallyClassifier"] == "standard" and rec["restrictedUse"] is not False:
        rep.error(f"{where}: restrictedUse must be false for a standard recording")
    if rec["recordingType"] not in RECORDING_TYPES:
        rep.error(f"{where}: recordingType {rec['recordingType']!r}")
    if rec["recordingType"] == "unknown" and el["fullVideoNegatives"] == "standard":
        rep.error(f"{where}: an unknown recording type cannot have standard full-video negatives")
    cov = rec["coverage"]
    if not isinstance(cov, dict) or cov.get("state") not in COVERAGE:
        rep.error(f"{where}: coverage.state must be one of {sorted(COVERAGE)}")
        cov = {"state": "none"}
    lp = rec["labelProvenance"]
    if not isinstance(lp, dict) or lp.get("method") not in {"legacy_declared", "stage1_verified"} or not lp.get("marksSha256"):
        rep.error(f"{where}: labelProvenance needs method ∈ {{legacy_declared, stage1_verified}} and marksSha256")
    # spans
    _check_spans(rec["rallies"], f"{where}.rallies", rep, kinds={"rally"}, extra_keys=("provenance",))
    for j, r in enumerate(rec["rallies"]):
        if isinstance(r, dict) and r.get("provenance") not in PROVENANCE:
            rep.error(f"{where}.rallies[{j}]: provenance {r.get('provenance')!r} not in {sorted(PROVENANCE)}")
    _check_spans(rec["excludedSpans"], f"{where}.excludedSpans", rep, kinds=EXCLUDED_KINDS)
    _check_spans(rec["cutRanges"], f"{where}.cutRanges", rep)
    _check_spans(rec["timeBreakingSpans"], f"{where}.timeBreakingSpans", rep, extra_keys=("trait", "origin"))
    for j, s in enumerate(rec["timeBreakingSpans"]):
        if isinstance(s, dict) and (s.get("trait") not in TB_TRAITS or s.get("origin") not in {"confirmed", "proposed"}):
            rep.error(f"{where}.timeBreakingSpans[{j}]: trait must be in {sorted(TB_TRAITS)} and origin confirmed|proposed")
    _check_spans(rec["nonRallyActivitySpans"], f"{where}.nonRallyActivitySpans", rep)
    rallies = sorted((r for r in rec["rallies"] if isinstance(r, dict) and isinstance(r.get("startTick"), int)), key=lambda r: r["startTick"])
    for a, b in zip(rallies, rallies[1:]):
        if b["startTick"] < a["endTick"]:
            rep.error(f"{where}: rallies overlap ([{a['startTick']}, {a['endTick']}) and [{b['startTick']}, {b['endTick']}))")
    for r in rallies:
        for c in rec["cutRanges"]:
            if isinstance(c, dict) and r["startTick"] < c.get("endTick", 0) and c.get("startTick", 0) < r["endTick"]:
                rep.error(f"{where}: rally [{r['startTick']}, {r['endTick']}) overlaps cut range [{c['startTick']}, {c['endTick']}): a rally mark inside non-footage")
    if not isinstance(rec["exposure"], list):
        rep.error(f"{where}: exposure must be a list (may be empty)")
    # groups and identities
    g = groups.setdefault(rec["groupId"], {"splits": set(), "folds": set(), "members": []})
    g["splits"].add(rec["split"])
    g["folds"].add(rec["fold"])
    g["members"].append(rid)
    for key in ("sourceId", "fingerprint"):
        v = rec[key]
        if v:
            prev = seen_ids.setdefault((key, v), (rid, rec["groupId"]))
            if prev[1] != rec["groupId"]:
                rep.error(f"{where}: shares {key} {v} with {prev[0]} in another group ({prev[1]} vs {rec['groupId']})")
    # steps file
    steps_path = os.path.join(dataset_dir, rec["stepsFile"])
    if not rec["stepsFile"].startswith("steps/") or not os.path.isfile(steps_path):
        rep.error(f"{where}: steps file {rec['stepsFile']!r} missing or outside steps/")
        return
    actual = sha256_file(steps_path)
    if actual != rec["stepsSha256"]:
        rep.error(f"{where}: stepsSha256 {rec['stepsSha256'][:16]}… != file {actual[:16]}…")
    ignore_ticks = int(round(m["labelSchema"]["boundaryIgnoreSec"] * TIMESCALE))
    result = validate_steps(steps_path, rec, ignore_ticks, rep)
    if result["lines"] != rec["stepCount"]:
        rep.error(f"{where}: stepCount {rec['stepCount']} != {result['lines']} lines")
    if rec["labelCounts"] != result["counts"]:
        rep.error(f"{where}: labelCounts {rec['labelCounts']} != counted {result['counts']}")
    if rec["labelCounts"].get("ACTIVE_RALLY", 0) == 0:
        rep.warn(f"{where}: no ACTIVE_RALLY step")


def validate(dataset_dir: str, withheld_path: str | None = None) -> Report:
    rep = Report()
    mpath = os.path.join(dataset_dir, "dataset-manifest.json")
    if not os.path.isfile(mpath):
        rep.error("dataset-manifest.json missing")
        return rep
    try:
        with open(mpath, "r", encoding="utf-8") as fh:
            m = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        rep.error(f"dataset-manifest.json unreadable: {e}")
        return rep
    if not isinstance(m, dict):
        rep.error("dataset-manifest.json is not an object")
        return rep
    if m.get("schemaVersion") != SCHEMA_VERSION:
        rep.error(f"schemaVersion {m.get('schemaVersion')!r}; this validator reads {SCHEMA_VERSION} only")
        return rep
    missing = MANIFEST_KEYS - set(m)
    if missing:
        rep.error(f"manifest missing keys {sorted(missing)}")
        return rep
    # schemas
    if m["featureSchema"] != feature_schema():
        rep.error(f"featureSchema differs from {FEATURE_VERSION} (names, order, nullable, kind and lookaheadSec must match exactly)")
    ls = m["labelSchema"]
    if not isinstance(ls, dict) or ls.get("version") != LABEL_VERSION or ls.get("states") != STATES or ls.get("weights") != WEIGHTS:
        rep.error(f"labelSchema differs from {LABEL_VERSION} (version, states and weights must match exactly)")
    if not isinstance(ls, dict) or not isinstance(ls.get("boundaryIgnoreSec"), (int, float)) or ls["boundaryIgnoreSec"] <= 0:
        rep.error("labelSchema.boundaryIgnoreSec must be a positive number")
        m["labelSchema"] = {**(ls if isinstance(ls, dict) else {}), "boundaryIgnoreSec": 0.5}
    if m["timescale"] != TIMESCALE:
        rep.error(f"timescale must be {TIMESCALE}")
    for key in ("projectJson", "sessions", "validationJson", "manifestJson"):
        if not isinstance(m["splitManifest"], dict) or not _is_sha(m["splitManifest"].get(key)):
            rep.error(f"splitManifest.{key} must be a SHA-256 hex")
    if not isinstance(m["detector"], dict) or not m["detector"].get("name") or not m["detector"].get("canonicalDigest"):
        rep.error("detector needs name and canonicalDigest")
    if not _is_sha(m["pipelineConfigSha256"]):
        rep.error("pipelineConfigSha256 must be a SHA-256 hex")
    # withheld closure: fail closed
    wh = m["withheld"]
    withheld = {"names": set(), "sourceIds": set(), "fingerprints": set()}
    if not isinstance(wh, dict) or not all(isinstance(wh.get(k), list) for k in ("names", "sourceIds", "fingerprints")):
        rep.error("withheld must carry names, sourceIds and fingerprints lists")
    else:
        withheld = {k: set(wh[k]) for k in ("names", "sourceIds", "fingerprints")}
        if not withheld["names"]:
            rep.error("withheld.names is empty: an empty closure proves nothing, the export must carry the closure it refused")
        if wh.get("closureSha256") != closure_sha256(wh["names"], wh["sourceIds"], wh["fingerprints"]):
            rep.error("withheld.closureSha256 does not match the lists it carries")
    if withheld_path:
        try:
            with open(withheld_path, "r", encoding="utf-8") as fh:
                ext = json.load(fh)
        except (OSError, json.JSONDecodeError) as e:
            rep.error(f"withheld file unreadable: {e}")
            ext = {}
        for k in ("names", "sourceIds", "fingerprints"):
            extra = set(ext.get(k, [])) - withheld[k]
            if extra:
                rep.error(f"the external withheld closure has {len(extra)} {k} the manifest's closure lacks (e.g. {sorted(extra)[0]!r}): the export ran against a smaller closure")
            withheld[k] |= set(ext.get(k, []))
    # recordings
    recs = m["recordings"]
    if not isinstance(recs, list) or not recs:
        rep.error("recordings must be a non-empty list")
        return rep
    groups: dict = {}
    seen_ids: dict = {}
    seen_rids = set()
    referenced = set()
    for i, rec in enumerate(recs):
        if isinstance(rec, dict) and rec.get("recordingId") in seen_rids:
            rep.error(f"recordings[{i}]: duplicate recordingId {rec['recordingId']!r}")
        if isinstance(rec, dict):
            seen_rids.add(rec.get("recordingId"))
            referenced.add(rec.get("stepsFile"))
        validate_recording(rec, i, m, dataset_dir, rep, withheld, groups, seen_ids)
    for gid, g in groups.items():
        if len(g["splits"]) > 1:
            rep.error(f"group {gid} is split across {sorted(g['splits'])}: {g['members']}")
        if len(g["folds"]) > 1:
            rep.error(f"group {gid} is in several folds {sorted(str(f) for f in g['folds'])}: {g['members']}")
    # stray files
    for root, _, files in os.walk(dataset_dir):
        for name in files:
            rel = os.path.relpath(os.path.join(root, name), dataset_dir)
            if rel == "dataset-manifest.json" or rel in referenced:
                continue
            rep.error(f"stray file {rel!r}: a dataset holds only its manifest and the referenced steps files")
    rep.info = {
        "recordings": len(recs), "groups": len(groups),
        "withheld": {k: len(v) for k, v in withheld.items()},
        "labelCounts": _sum_counts(recs),
        "bySplit": _count_by(recs, "split"), "bySurface": _count_by(recs, "surface"),
        "restricted": sorted(r["recordingId"] for r in recs if isinstance(r, dict) and r.get("restrictedUse") is True),
    }
    return rep


def _is_sha(v) -> bool:
    return isinstance(v, str) and len(v) == 64 and all(c in "0123456789abcdef" for c in v)


def _sum_counts(recs) -> dict:
    total = {name: 0 for name in STATES}
    for r in recs:
        if isinstance(r, dict) and isinstance(r.get("labelCounts"), dict):
            for k, v in r["labelCounts"].items():
                if k in total and isinstance(v, int):
                    total[k] += v
    return total


def _count_by(recs, key) -> dict:
    out: dict = {}
    for r in recs:
        if isinstance(r, dict):
            out[str(r.get(key))] = out.get(str(r.get(key)), 0) + 1
    return out


# ----------------------------------------------------------------------------- synthetic example

def _synthetic_recording(rng: random.Random, rid: str, group: str, split: str, fold: int, surface: str, *,
                         recording_type: str, negatives: str, coverage: str, cuts=(), tb=(), net=True,
                         restricted_reasons=(), nra=(), rallies=(), excluded=(), gap_at: float | None = None) -> tuple[dict, list]:
    duration = 60.0
    rec = {
        "recordingId": rid, "sourceId": f"youtube:{rid}", "fingerprint": f"fp:{hashlib.sha256(rid.encode()).hexdigest()[:16]}",
        "groupId": group, "split": split, "fold": fold, "surface": surface, "camera": "End line, elevated (stands/tripod 2m+)",
        "orientation": "Landscape", "originKind": "file", "uploader": "synthetic", "durationSec": duration,
        "frameRateNominal": 30.0, "vfr": False, "aspect": 16 / 9, "upright": True,
        "net": {"x": 0.16, "y": 0.67, "w": 0.57, "h": 0.11, "confidence": 0.8} if net else None,
        "recordingType": recording_type,
        "eligibility": {"rallyClassifier": "restricted" if restricted_reasons else "standard",
                        "fullVideoNegatives": negatives, "reasons": list(restricted_reasons)},
        "restrictedUse": bool(restricted_reasons),
        "coverage": {"state": coverage, "verifiedCoverageSec": duration if coverage == "stage1_complete" else None},
        "labelProvenance": {"method": "stage1_verified" if coverage == "stage1_complete" else "legacy_declared",
                            "marksSha256": hashlib.sha256(f"marks:{rid}".encode()).hexdigest(), "rallyEventsSha256": None},
        "rallies": [{"rallyId": None, "startTick": round(s * TIMESCALE), "endTick": round(e * TIMESCALE), "kind": "rally",
                     "provenance": "legacy_declared", "contactUncertaintyTicks": None, "deadUncertaintyTicks": None} for s, e in rallies],
        "excludedSpans": [{"startTick": round(s * TIMESCALE), "endTick": round(e * TIMESCALE), "kind": k} for s, e, k in excluded],
        "cutRanges": [{"startTick": round(s * TIMESCALE), "endTick": round(e * TIMESCALE)} for s, e in cuts],
        "timeBreakingSpans": [{"startTick": round(s * TIMESCALE), "endTick": round(e * TIMESCALE), "trait": tr, "origin": o} for s, e, tr, o in tb],
        "nonRallyActivitySpans": [{"startTick": round(s * TIMESCALE), "endTick": round(e * TIMESCALE)} for s, e in nra],
        "exposure": [{"date": "2026-11-03", "kind": "training_package", "ref": "synthetic"}],
        "stepsFile": f"steps/{rid}.jsonl", "stepsSha256": "", "stepCount": 0, "labelCounts": {},
    }
    ignore_ticks = int(round(0.5 * TIMESCALE))
    steps = []
    t = 0.0
    prev_t = None
    prev_tick = None
    seg = 0
    gap_pending = gap_at is not None
    while t < duration:
        tick = round(t * TIMESCALE)
        in_rally = any(_inside(tick, r) for r in rec["rallies"])
        has_ball = 1 if (in_rally and rng.random() < 0.85) or (not in_rally and rng.random() < 0.2) else 0
        n_court = rng.randint(1, 2) if has_ball else 0
        n_dets = n_court + (1 if rng.random() < 0.1 else 0)
        proj = 1 if has_ball and rng.random() < (0.8 if in_rally else 0.15) else 0
        sel = proj == 1
        sel_y = round(rng.uniform(0.3, 0.95), 4) if sel else None
        n_cands = rng.randint(0, 2) + proj
        f = [
            None if prev_t is None else round(t - prev_t, 6),
            has_ball, n_court, n_dets,
            round(rng.uniform(0.5, 1.0), 4) if n_dets else None,
            sel_y if sel else (round(rng.uniform(0.2, 0.8), 4) if n_court else None),
            proj,
            round(rng.uniform(0.05, 0.95), 4) if sel else None, sel_y,
            round(rng.uniform(0.01, 0.05), 4) if sel else None,
            round(rng.uniform(0.8, 1.0), 4) if sel else None, round(rng.uniform(0.3, 1.0), 4) if sel else None,
            n_cands, proj, max(0, n_cands - proj - rng.randint(0, 1)),
            (round(sel_y - (rec["net"]["y"] + rec["net"]["h"]), 4) if (sel and net) else None),
        ]
        emitted = 1 if (in_rally and rng.random() < 0.02) else 0
        f += [emitted, round(rng.uniform(0.8, 2.0), 3) if emitted else None]
        if prev_tick is not None and (crosses_non_footage(prev_tick, tick, rec) or (t - prev_t) > GAP_SEC):
            seg += 1
        y = expected_state(tick, rec, ignore_ticks)
        steps.append({"t": round(t, 6), "tick": tick, "seg": seg, "f": f, "y": y, "w": WEIGHTS[str(y)]})
        prev_t, prev_tick = t, tick
        if gap_pending and t >= gap_at:
            gap_pending = False
            t = round(t + 1.0, 6)           # one second of no processed frames: a segment break
        else:
            t = round(t + 1 / 30, 6)
    return rec, steps


def write_synthetic(out_dir: str, seed: int = 0) -> str:
    """Write a complete, valid v1 dataset of four recordings in two groups (two folds)."""
    rng = random.Random(seed)
    os.makedirs(os.path.join(out_dir, "steps"), exist_ok=False)
    specs = [
        dict(rid="syn_bch_a", group="g-syn-a", split="train", fold=0, surface="beach", recording_type="continuous", negatives="standard",
             coverage="declared_complete", rallies=[(5, 12), (20, 31), (40, 48)], excluded=[(34, 36, "missedServe")],
             cuts=[(0.00833, 0.01667)], gap_at=15.0),   # a cut between two processed frames (ticks 5–10): the segment still breaks
        dict(rid="syn_bch_a_v2", group="g-syn-a", split="train", fold=0, surface="beach", recording_type="continuous", negatives="standard",
             coverage="declared_complete", rallies=[(8, 14), (24, 33)], cuts=[(0, 3)], tb=[(50, 55, "replay", "proposed")]),
        dict(rid="syn_grs_b", group="g-syn-b", split="tune", fold=1, surface="grass", recording_type="edited", negatives="restricted",
             coverage="declared_complete", rallies=[(6, 15), (22, 30)], restricted_reasons=["edited recording: temporal windows only within confirmed continuous spans"]),
        dict(rid="syn_ind_c", group="g-syn-c", split="dev_val", fold=1, surface="indoor", recording_type="continuous", negatives="standard",
             coverage="stage1_complete", rallies=[(4, 9), (18, 29)], nra=[(12, 15)], net=False),
    ]
    recordings = []
    for spec in specs:
        rec, steps = _synthetic_recording(rng, **spec)
        path = os.path.join(out_dir, rec["stepsFile"])
        with open(path, "w", encoding="utf-8") as fh:
            for s in steps:
                fh.write(json.dumps(s, separators=(",", ":")) + "\n")
        counts = {name: 0 for name in STATES}
        for s in steps:
            counts[STATE_NAMES[s["y"]]] += 1
        rec["stepsSha256"] = sha256_file(path)
        rec["stepCount"] = len(steps)
        rec["labelCounts"] = counts
        recordings.append(rec)
    names = ["withheld_syn_01", "withheld_syn_02"]
    source_ids = ["youtube:withheld_syn_01"]
    fps = ["fp:withheld0001"]
    manifest = {
        "schemaVersion": SCHEMA_VERSION, "createdAt": "2026-11-03T00:00:00Z",
        "generator": {"tool": "validate_dataset.py --write-synthetic", "codeSha": "synthetic"},
        "project": "Synthetic",
        "splitManifest": {k: hashlib.sha256(f"synthetic:{k}".encode()).hexdigest() for k in ("projectJson", "sessions", "validationJson", "manifestJson")},
        "withheld": {"names": names, "sourceIds": source_ids, "fingerprints": fps, "closureSha256": closure_sha256(names, source_ids, fps)},
        "detector": {"name": "ball_heat", "canonicalDigest": "0000000000000000"},
        "pipelineConfigSha256": hashlib.sha256(b"synthetic:config").hexdigest(),
        "timescale": TIMESCALE, "samplingHzNominal": 30,
        "featureSchema": feature_schema(), "labelSchema": label_schema(0.5),
        "recordings": recordings,
    }
    mpath = os.path.join(out_dir, "dataset-manifest.json")
    with open(mpath, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1)
    return mpath


# ----------------------------------------------------------------------------- CLI

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dataset", nargs="?", help="dataset folder to validate")
    ap.add_argument("--withheld", help="an external withheld-closure JSON ({names, sourceIds, fingerprints}); must not exceed the manifest's")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    ap.add_argument("--write-synthetic", metavar="DIR", help="write the synthetic example dataset to DIR (must not exist) and exit")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args(argv)
    if args.write_synthetic:
        path = write_synthetic(args.write_synthetic, args.seed)
        print(f"wrote {path}")
        return 0
    if not args.dataset:
        ap.error("a dataset folder is required")
    rep = validate(args.dataset, args.withheld)
    if args.json:
        print(json.dumps(rep.as_dict(), indent=1))
    else:
        for e in rep.errors:
            print(f"error: {e}")
        for w in rep.warnings:
            print(f"warning: {w}")
        print(f"{'OK' if rep.ok else 'FAILED'}: {len(rep.errors)} error(s), {len(rep.warnings)} warning(s); {json.dumps(rep.info)}")
    return 0 if rep.ok else 1


if __name__ == "__main__":
    sys.exit(main())
