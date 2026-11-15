#!/usr/bin/env python3
"""Inventory adapter for the negative-coverage audit (docs/ml-roadmap/RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md §3).

Reads metadata only — the dataset manifest, the frozen folds file, the withheld-closure file the dataset was
exported against, and the project folder's JSON (project.json, manifests/manifest.json,
pipeline_tuning/validation.json, sessions/, footage-properties/ and the `<video>.rallylabels.json` marks sidecars) —
and writes the inventory the draw reads (`coverage_audit_inventory_v2`). It never opens a video. The dataset is one
`validate_dataset.py` has passed: its manifest's fields are read as the contract defines them.

For every recording of the dataset it either lists the recording as eligible, with the unmarked intervals of its
**current** marks and cut ranges in ticks, or lists it under `leftOut` with the reason (edited, withheld, no marks
file, …); none is dropped silently. The spans are computed as `RallyClassifierExporter` computes them
(`RallyTruth` over the marks and the session's normalised cut ranges; a rally starts at its marked serve contact when
there is one; ticks are `round(seconds × 600)`, half to even), so an interval here is exactly the time the exporter
labels outside every rally, excluded span and cut range. Each eligible recording carries the SHA-256 of its marks
file now and the one the dataset recorded, and whether they differ.

Refusals (nothing is written): an empty withheld closure; a closure file that is not the closure the dataset was
exported against; a folds file that `folds.load` refuses (drawn for another dataset, or edited); a split manifest
older than project.json or validation.json (the closure's inputs). A recording that is in the withheld closure by name, sourceId, card or
content fingerprint, or alias group — the closure file's lists and the project's closure as it is now
(`content_lineage/audit.py withheld_closure`) — is left out and listed.

    python3 scripts/rally_classifier/coverage_audit_inventory.py --dataset <dataset dir> --project <project dir>
        --closure <stamp>-closure.json --folds <folds.json> --out <inventory.json>

Exit status 0 when the inventory was written, 1 otherwise. Standard library only.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "..", "content_lineage"))
sys.path.insert(0, os.path.join(_HERE, "..", "desktop_training"))
import audit as lineage  # noqa: E402
import folds as fold_draw  # noqa: E402
import validate_dataset as v  # noqa: E402
import withheld_closure as wc  # noqa: E402

INVENTORY_VERSION = "coverage_audit_inventory_v2"
SLIVER_SEC = 0.1                    # RallyTruth.sliver: a piece a cut leaves shorter than this is dropped
EXCLUDED_KINDS = ("missedServe", "other")
CONTACT_KINDS = {"serve", "pass", "set", "attack", "block", "freeBall"}
SPLIT_MANIFEST_KEYS = ("projectJson", "sessions", "validationJson", "manifestJson")
RECORDING_KEYS = {
    "recordingId", "groupId", "surface", "camera", "split", "fold", "durationSec", "durationTicks", "recordingType",
    "fullVideoNegatives", "fingerprint", "contentFingerprint", "sourceId", "aliasGroup", "marksSha256",
    "datasetMarksSha256", "marksChangedSinceExport", "spansChangedSinceExport", "rallies", "excludedSpans",
    "cutRanges", "rallyMarks", "missedServeMarks", "otherMarks", "intervals", "unmarkedTicks",
}


class AuditError(Exception):
    """The coverage audit's tools refuse: the message says why, for a person."""


# ----------------------------------------------------------------------------- files

def load_json(path: str, what: str):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        raise AuditError(f"{what} unreadable: {e}")


def write_new_json(path: str, doc: dict) -> None:
    """Write `doc` to a file that must not exist yet: an audit input or record is written once."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    try:
        with open(path, "x", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=1, sort_keys=True)
            fh.write("\n")
    except FileExistsError:
        raise AuditError(f"{path} exists: it is never overwritten; a new one is a new file")


def canonical_digest(directory: str) -> str:
    """`DatasetSplitManifest.canonicalDigest(ofDirectory:)`: SHA-256 over one `<sha256>  ./<relative path>` line per
    regular file, in byte order of the path."""
    paths = []
    for root, _, files in os.walk(directory):
        for name in files:
            paths.append(os.path.relpath(os.path.join(root, name), directory).replace(os.sep, "/"))
    lines = "".join(f"{v.sha256_file(os.path.join(directory, rel))}  ./{rel}\n" for rel in sorted(paths, key=lambda q: q.encode("utf-8")))
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()


def session_video(project_dir: str, recording_id: str) -> str:
    """The path of a recording's original as its dataset session names it. The file itself is never opened: the
    path only says where the sidecars lie."""
    session = load_json(os.path.join(project_dir, "sessions", recording_id + ".json"), f"{recording_id}: dataset session")
    path = session.get("sourcePath") if isinstance(session, dict) else None
    if not isinstance(path, str) or not path:
        raise AuditError(f"{recording_id}: the dataset session names no sourcePath")
    return path


def sidecar_path(video: str, suffix: str) -> str:
    """`<video without its extension>.<suffix>.json` — `RallyMarkModel.labelsURL` for `rallylabels`, the Stage 1
    record for `rallyevents`, the audit record for `coverageaudit`."""
    return os.path.splitext(video)[0] + "." + suffix + ".json"


# ----------------------------------------------------------------------------- marks, cuts, spans

def tick(seconds: float) -> int:
    """`RallyClassifierExporter.tick`: nearest tick, half to even (Python's `round` on a float)."""
    return round(seconds * v.TIMESCALE)


def _is_number(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def _is_rally(kind) -> bool:
    """`RallyTruth.isRally`: a rally by its kind, or a mark from before live tagging (no kind)."""
    return kind in (None, "rally")


def read_marks(path: str) -> list:
    """The marks sidecar as RallyLab decodes it (`[RallyMarkRecord]`): `{start, end, kind, contacts}` per mark.
    A file RallyLab could not decode is refused here too."""
    data = load_json(path, "rally marks")
    if not isinstance(data, list):
        raise AuditError("rally marks unreadable: not a list of marks")
    marks = []
    for i, m in enumerate(data):
        if not isinstance(m, dict) or not _is_number(m.get("startTime")) or not _is_number(m.get("endTime")):
            raise AuditError(f"rally marks unreadable: mark {i} needs numeric startTime and endTime")
        kind = m.get("kind")
        if not _is_rally(kind) and kind not in EXCLUDED_KINDS:
            raise AuditError(f"rally marks unreadable: mark {i} has kind {kind!r}")
        contacts = m.get("contacts") or []
        if not isinstance(contacts, list) or any(not isinstance(c, dict) or not _is_number(c.get("time")) or c.get("kind") not in CONTACT_KINDS
                                                 for c in contacts):
            raise AuditError(f"rally marks unreadable: mark {i} has a contact without a time or a known kind")
        marks.append({"start": float(m["startTime"]), "end": float(m["endTime"]), "kind": kind, "contacts": contacts})
    return marks


def normalised_cuts(cuts) -> list:
    """`[CutRange].normalised()`: empty and negative ones dropped, sorted, overlapping or touching ones merged."""
    out: list = []
    for s, e in sorted((c for c in cuts if c[1] > c[0] and c[0] >= 0), key=lambda c: c[0]):
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def _outside(cuts: list, a: float, b: float) -> list:
    """`[CutRange].outside(a, b)` over normalised cuts: the pieces of a ..< b outside every cut, in order."""
    if b <= a:
        return []
    pieces, start = [], a
    for s, e in cuts:
        if e > a and s < b:
            if s > start:
                pieces.append((start, s))
            start = max(start, e)
    if start < b:
        pieces.append((start, b))
    return pieces


def truth_spans(marks: list, raw_cuts: list) -> dict:
    """The recording's rallies, excluded spans and cut ranges in ticks, as the exporter writes them
    (`RallyClassifierExporter.export` and `.build`). Raises AuditError with the exporter's reason for leaving the
    recording out: a rally mark inside a cut range, or two rally marks that overlap."""
    cuts = normalised_cuts(raw_cuts)
    for m in marks:
        if _is_rally(m["kind"]) and any(s < m["end"] and m["start"] < e for s, e in cuts):
            raise AuditError("a rally mark overlaps a cut range (a rally mark inside non-footage)")
    pieces = [(s, e, m["kind"]) for m in sorted(marks, key=lambda m: m["start"]) for s, e in _outside(cuts, m["start"], m["end"])
              if e - s >= SLIVER_SEC]
    rally_pieces = [p for p in pieces if _is_rally(p[2])]
    if any(b[0] < a[1] for a, b in zip(rally_pieces, rally_pieces[1:])):
        raise AuditError("two rally marks overlap")
    rallies = []
    for s, e, _ in rally_pieces:
        record = next((m for m in marks if m["start"] == s and m["end"] == e and _is_rally(m["kind"])), None)
        first = record["contacts"][0] if record and record["contacts"] else None
        contact = first["time"] if first and first["kind"] == "serve" and s <= first["time"] < e else s
        if tick(contact) < tick(e):
            rallies.append({"startTick": tick(contact), "endTick": tick(e)})
    excluded = [{"startTick": tick(s), "endTick": tick(e), "kind": kind} for s, e, kind in pieces
                if not _is_rally(kind) and tick(s) < tick(e)]
    cut_ranges = [{"startTick": tick(s), "endTick": tick(e)} for s, e in cuts if tick(s) < tick(e)]
    return {"rallies": rallies, "excludedSpans": excluded, "cutRanges": cut_ranges}


def unmarked_intervals(spans, duration_ticks: int) -> list:
    """The maximal intervals of [0, duration) that no span covers, in ticks, indexed in time order. Overlapping or
    touching spans are merged and clamped to the recording first. Every interval is listed, whatever its length:
    a sub-second one can hold a missed serve, an edge one a rally the recording clipped."""
    merged: list = []
    for s, e in sorted((max(0, s), min(duration_ticks, e)) for s, e in spans):
        if e <= s:
            continue
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    out: list = []
    cursor = 0
    for s, e in merged + [[duration_ticks, duration_ticks]]:
        if s > cursor:
            out.append({"index": len(out), "startTick": cursor, "endTick": s})
        cursor = max(cursor, e)
    return out


def recording_intervals(rec: dict) -> list:
    """A recording's unmarked intervals from its rallies, excluded spans and cut ranges."""
    spans = [(s["startTick"], s["endTick"]) for key in ("rallies", "excludedSpans", "cutRanges") for s in rec[key]]
    return unmarked_intervals(spans, rec["durationTicks"])


def _span_pairs(spans, with_kind: bool = False) -> list:
    return sorted((s["startTick"], s["endTick"]) + ((s.get("kind"),) if with_kind else ()) for s in spans)


# ----------------------------------------------------------------------------- the withheld closure

def withheld_identity(rec: dict, withheld: dict) -> str | None:
    """Which of a recording's identities is a withheld one — its name, confirmed sourceId, card fingerprint or
    content fingerprint (the trainers' rule, `withheld_closure.withheld_identity`), or its alias group — or None.
    The one rule for the inventory and the draw."""
    hit = wc.withheld_identity(withheld, rec["recordingId"], [rec.get("sourceId")],
                               {key: rec.get(key) for key in ("fingerprint", "contentFingerprint")})
    if hit is None and rec.get("aliasGroup") and rec["aliasGroup"] in withheld["aliasGroups"]:
        hit = "aliasGroup"
    return hit


def _confirmed(value) -> str | None:
    """A split-manifest identity when a person confirmed it; an inferred one identifies nothing."""
    return value.get("value") if isinstance(value, dict) and value.get("origin") == "confirmed" and value.get("value") else None


def read_closure(closure_path: str, dataset_manifest: dict) -> dict:
    """The withheld-closure file the dataset was exported against. Refused: unreadable, without its three lists,
    empty (an empty closure proves nothing), not hashing to its own closureSha256 (`withheld_closure.read_closure`),
    or not the dataset's closure."""
    closure = load_json(closure_path, "withheld closure file")
    try:
        wc.read_closure(closure, "the withheld closure file")
    except wc.Refused as e:
        raise AuditError(str(e))
    ours = dataset_manifest.get("withheld")
    if not isinstance(ours, dict) or ours.get("closureSha256") != closure["closureSha256"]:
        raise AuditError("the withheld closure file is not the closure the dataset was exported against "
                         f"(file {closure['closureSha256'][:16]}…, dataset {str((ours or {}).get('closureSha256'))[:16]}…)")
    return closure


def project_withheld(closure: dict, rows: dict, manifest_now: dict, project: dict, listed: set) -> dict:
    """Everything the audit refuses: the closure file's lists, plus the project's closure as it is now
    (`withheld_closure`: reserved splits, validation.json's lists and every recording sharing an identity with one)
    with each withheld recording's identities and alias group from its split-manifest row."""
    try:
        now = lineage.withheld_closure(manifest_now, project, listed)
    except lineage.ReadError as e:
        raise AuditError(f"the project's withheld closure cannot be computed: {e}")
    names = set(closure["names"]) | set(now)
    source_ids, fingerprints, alias_groups = set(closure["sourceIds"]), set(closure["fingerprints"]), set()
    for name in names:
        row = rows.get(name)
        if row is None:
            continue
        if row.get("aliasGroup"):
            alias_groups.add(row["aliasGroup"])
        fingerprints.update(row[k] for k in ("fingerprint", "contentFingerprint") if row.get(k))
        if _confirmed(row.get("sourceId")):
            source_ids.add(_confirmed(row["sourceId"]))
    return {"names": sorted(names), "sourceIds": sorted(source_ids), "fingerprints": sorted(fingerprints),
            "aliasGroups": sorted(alias_groups), "namesNotInClosureFile": sorted(set(now) - set(closure["names"]))}


# ----------------------------------------------------------------------------- the inventory

def current_hashes(project_dir: str) -> dict:
    """The split-manifest hashes of the project as it is now (`RallyClassifierExporter.currentHashes`, plus the split
    manifest's own); None for a file that is not there."""
    def sha(*parts):
        path = os.path.join(project_dir, *parts)
        return v.sha256_file(path) if os.path.isfile(path) else None
    return {"projectJson": sha("project.json"), "sessions": canonical_digest(os.path.join(project_dir, "sessions")),
            "validationJson": sha("pipeline_tuning", "validation.json"), "manifestJson": sha("manifests", "manifest.json")}


def _eligible_record(project_dir: str, rec: dict, row: dict, fold: int) -> dict:
    """One eligible recording's inventory record from its current session, marks and cut ranges. Raises AuditError
    with the reason the recording is left out."""
    rid = rec["recordingId"]
    properties = os.path.join(project_dir, "footage-properties", rid + ".json")
    if not os.path.isfile(properties):
        raise AuditError("no footage-type record now (footage-properties): the type the dataset recorded cannot be re-read")
    typed = load_json(properties, "footage-type record").get("recordingType")
    if typed != "continuous":
        raise AuditError(f"typed {typed!r} now (footage-properties); continuous at export — an edited recording supplies no negatives")
    session = load_json(os.path.join(project_dir, "sessions", rid + ".json"), "dataset session")
    if session.get("ralliesMarked") is not True:
        raise AuditError("the pass is no longer declared complete (ralliesMarked is not true): what lies outside the marks is unknown")
    video = session_video(project_dir, rid)
    if os.path.exists(sidecar_path(video, "rallyevents")):
        raise AuditError("has a Stage 1 boundary record: its coverage is Stage 1's to verify, not this audit's")
    marks_path = sidecar_path(video, "rallylabels")
    if not os.path.isfile(marks_path):
        raise AuditError("no rally marks beside the video")
    raw_cuts = session.get("cuts") or []
    if any(not isinstance(c, dict) or not _is_number(c.get("start")) or not _is_number(c.get("end")) for c in raw_cuts):
        raise AuditError("the session's cut ranges are unreadable")
    spans = truth_spans(read_marks(marks_path), [(c["start"], c["end"]) for c in raw_cuts])
    marks_sha = v.sha256_file(marks_path)
    out = {
        "recordingId": rid, "groupId": rec["groupId"], "surface": rec["surface"], "camera": rec["camera"], "split": rec["split"],
        "fold": fold, "durationSec": rec["durationSec"], "durationTicks": tick(rec["durationSec"]),
        "recordingType": rec["recordingType"], "fullVideoNegatives": rec["eligibility"]["fullVideoNegatives"],
        "fingerprint": rec["fingerprint"], "contentFingerprint": row.get("contentFingerprint"), "sourceId": rec["sourceId"],
        "aliasGroup": row.get("aliasGroup"), "marksSha256": marks_sha, "datasetMarksSha256": rec["labelProvenance"]["marksSha256"],
        "marksChangedSinceExport": marks_sha != rec["labelProvenance"]["marksSha256"],
        "spansChangedSinceExport": any(_span_pairs(spans[key], with_kind=key == "excludedSpans") != _span_pairs(rec[key], with_kind=key == "excludedSpans")
                                       for key in ("rallies", "excludedSpans", "cutRanges")),
        **spans,
        "rallyMarks": len(spans["rallies"]),
        "missedServeMarks": sum(1 for s in spans["excludedSpans"] if s["kind"] == "missedServe"),
        "otherMarks": sum(1 for s in spans["excludedSpans"] if s["kind"] == "other"),
    }
    if not out["contentFingerprint"]:
        raise AuditError("its split-manifest row has no content fingerprint: the file the review must be bound to is unknown")
    out["intervals"] = recording_intervals(out)
    out["unmarkedTicks"] = sum(iv["endTick"] - iv["startTick"] for iv in out["intervals"])
    return out


def build_inventory(dataset_dir: str, project_dir: str, closure_path: str, folds_path: str, now: str | None = None) -> dict:
    dataset = load_json(os.path.join(dataset_dir, "dataset-manifest.json"), "dataset manifest")
    if not isinstance(dataset, dict) or dataset.get("schemaVersion") != v.SCHEMA_VERSION or dataset.get("timescale") != v.TIMESCALE:
        raise AuditError(f"the dataset manifest must be {v.SCHEMA_VERSION} at timescale {v.TIMESCALE}")
    try:
        folds = fold_draw.load(folds_path, dataset_dir)     # refuses a file for another dataset, or one edited since it was drawn
    except fold_draw.FoldsError as e:
        raise AuditError(str(e))
    identity = folds["dataset"]

    closure = read_closure(closure_path, dataset)
    try:
        manifest_now, project, listed = lineage.load_project(project_dir)
    except (OSError, json.JSONDecodeError) as e:
        raise AuditError(f"the project's split manifest, project.json or validation.json is unreadable: {e}")
    current = current_hashes(project_dir)
    recorded = manifest_now.get("hashes") or {}
    for key, label in (("projectJson", "project.json"), ("validationJson", "validation.json")):
        if recorded.get(key) != current[key]:
            raise AuditError(f"the split manifest is older than {label}: the withheld closure read from it would be stale — "
                             "write the manifest again (RallyLab --manifest) before the inventory")
    rows = {row["video"]: row for row in manifest_now["videos"]}
    withheld = project_withheld(closure, rows, manifest_now, project, listed)

    recordings, left_out = [], []
    for rec in sorted(dataset["recordings"], key=lambda r: r["recordingId"]):
        rid = rec["recordingId"]
        row = rows.get(rid) or {}
        identity_now = {"recordingId": rid, "sourceId": rec["sourceId"], "fingerprint": rec["fingerprint"],
                        "contentFingerprint": row.get("contentFingerprint"), "aliasGroup": row.get("aliasGroup")}
        match = withheld_identity(identity_now, withheld) or withheld_identity({**identity_now, "sourceId": _confirmed(row.get("sourceId")),
                                                                                "fingerprint": row.get("fingerprint")}, withheld)
        try:
            if match:
                raise AuditError(f"WITHHELD: its {match} is one of the withheld identities — never audited, never drawn")
            if rec["recordingType"] != "continuous":
                raise AuditError(f"{rec['recordingType']} recording: positives only, never audited for negatives and never a source of them")
            if rec["eligibility"]["fullVideoNegatives"] != "standard":
                raise AuditError(f"full-video negatives {rec['eligibility']['fullVideoNegatives']!r}, not standard")
            if not row:
                raise AuditError("not in the current split manifest")
            if row.get("fingerprint") != rec["fingerprint"] or _confirmed(row.get("sourceId")) != rec["sourceId"]:
                raise AuditError("its card fingerprint or confirmed sourceId changed since the export: the dataset's recording is not this one")
            if rid not in folds["recordings"]:
                raise AuditError("the folds file gives it no fold")
            recordings.append(_eligible_record(project_dir, rec, row, folds["recordings"][rid]))
        except AuditError as e:
            left_out.append({"recordingId": rid, "reason": str(e)})

    surfaces = sorted({r["surface"] for r in dataset["recordings"]})
    return {
        "schemaVersion": INVENTORY_VERSION,
        "createdAt": now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "project": dataset.get("project"),
        "dataset": {**identity, "timescale": v.TIMESCALE,
                    "labelSchema": (dataset.get("labelSchema") or {}).get("version"),
                    "boundaryIgnoreSec": (dataset.get("labelSchema") or {}).get("boundaryIgnoreSec"),
                    "recordings": len(dataset["recordings"]), "groups": len({r["groupId"] for r in dataset["recordings"]}),
                    "surfaces": surfaces},
        "folds": {"file": os.path.basename(folds_path), "sha256": v.sha256_file(folds_path), "folds": folds["folds"]},
        "splitManifest": {"atExport": {k: dataset["splitManifest"].get(k) for k in SPLIT_MANIFEST_KEYS}, "now": current,
                          "changedSinceExport": [k for k in SPLIT_MANIFEST_KEYS if dataset["splitManifest"].get(k) != current[k]]},
        "withheld": {"closureFile": os.path.basename(closure_path), "closureFileSha256": v.sha256_file(closure_path),
                     "closureSha256": closure["closureSha256"],
                     "closureFileCounts": {k: len(closure[k]) for k in wc.CLOSURE_KEYS}, **withheld},
        "recordings": recordings,
        "leftOut": left_out,
        "totals": totals(recordings, surfaces),
    }


def totals(recordings: list, surfaces: list) -> dict:
    """Counts over a list of inventory recordings: per surface and in all."""
    def tally(recs):
        return {"recordings": len(recs), "groups": len({r["groupId"] for r in recs}),
                "intervals": sum(len(r["intervals"]) for r in recs),
                "unmarkedSec": round(sum(r["unmarkedTicks"] for r in recs) / v.TIMESCALE, 3),
                "rallyMarks": sum(r["rallyMarks"] for r in recs), "missedServeMarks": sum(r["missedServeMarks"] for r in recs)}
    return {**tally(recordings),
            "intervalsUnder3Sec": sum(1 for r in recordings for iv in r["intervals"] if iv["endTick"] - iv["startTick"] < 3 * v.TIMESCALE),
            "marksChangedSinceExport": sorted(r["recordingId"] for r in recordings if r["marksChangedSinceExport"]),
            "spansChangedSinceExport": sorted(r["recordingId"] for r in recordings if r["spansChangedSinceExport"]),
            "bySurface": {s: tally([r for r in recordings if r["surface"] == s]) for s in surfaces}}


def load_inventory(path: str) -> dict:
    """Read an inventory for the draw. Refused: another schema; an empty closure; a recording that is withheld by
    any identity, is not continuous with standard full-video negatives, appears twice, or whose intervals do not
    follow from its spans (the file was edited after it was written)."""
    inv = load_json(path, "inventory")
    if not isinstance(inv, dict) or inv.get("schemaVersion") != INVENTORY_VERSION:
        raise AuditError(f"inventory schemaVersion must be {INVENTORY_VERSION!r}")
    for key in ("dataset", "folds", "splitManifest", "withheld", "recordings", "leftOut", "project"):
        if key not in inv:
            raise AuditError(f"inventory missing {key!r}")
    withheld = inv["withheld"]
    if not isinstance(withheld, dict) or not all(isinstance(withheld.get(k), list) for k in wc.CLOSURE_KEYS + ("aliasGroups",)):
        raise AuditError("inventory withheld must carry names, sourceIds, fingerprints and aliasGroups lists")
    if not withheld["names"]:
        raise AuditError("withheld.names is empty: an empty closure proves nothing; the inventory must carry the closure it refused")
    if not isinstance(inv["recordings"], list) or not inv["recordings"]:
        raise AuditError("the inventory lists no eligible recording")
    seen = set()
    for i, rec in enumerate(inv["recordings"]):
        if not isinstance(rec, dict) or RECORDING_KEYS - set(rec):
            raise AuditError(f"recordings[{i}]: missing {sorted(RECORDING_KEYS - set(rec)) if isinstance(rec, dict) else 'the record'}")
        rid = rec["recordingId"]
        if rid in seen:
            raise AuditError(f"recordings[{i}]: duplicate recordingId {rid!r}")
        seen.add(rid)
        match = withheld_identity(rec, withheld)
        if match:
            raise AuditError(f"recordings[{i}]: WITHHELD recording {rid!r} present ({match} in the closure)")
        if rec["recordingType"] != "continuous" or rec["fullVideoNegatives"] != "standard":
            raise AuditError(f"recordings[{i}]: {rid!r} is not a continuous recording with standard full-video negatives; "
                             "an edited recording is never audited for negatives")
        if not isinstance(rec["durationTicks"], int) or isinstance(rec["durationTicks"], bool) or rec["durationTicks"] <= 0:
            raise AuditError(f"recordings[{i}]: durationTicks must be a positive integer")
        if not rec["contentFingerprint"] or not rec["marksSha256"]:
            raise AuditError(f"recordings[{i}]: {rid!r} needs its content fingerprint and marks SHA-256 (what the draw binds to)")
        if rec["intervals"] != recording_intervals(rec):
            raise AuditError(f"recordings[{i}]: the intervals of {rid!r} do not follow from its rallies, excluded spans and cut ranges")
    return inv


# ----------------------------------------------------------------------------- CLI

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dataset", required=True, help="the dataset folder (its dataset-manifest.json is read)")
    ap.add_argument("--project", required=True, help="the RallyLab project folder (JSON only; no video is opened)")
    ap.add_argument("--closure", required=True, help="the withheld-closure file the dataset was exported against")
    ap.add_argument("--folds", required=True, help="the frozen folds file drawn for the dataset")
    ap.add_argument("--out", required=True, help="the inventory to write (must not exist)")
    args = ap.parse_args(argv)
    try:
        inv = build_inventory(args.dataset, args.project, args.closure, args.folds)
        write_new_json(args.out, inv)
    except AuditError as e:
        print(f"error: {e}")
        return 1
    t = inv["totals"]
    print(f"wrote {args.out}: {inv['dataset']['name']} — {t['recordings']} eligible recording(s) in {t['groups']} group(s), "
          f"{t['intervals']} unmarked interval(s), {t['unmarkedSec']} s, {t['rallyMarks']} rally marks; "
          f"{len(inv['leftOut'])} left out; marks changed since export: {t['marksChangedSinceExport'] or 'none'}")
    for s, row in t["bySurface"].items():
        print(f"  {s}: {row['recordings']} recording(s), {row['groups']} group(s), {row['intervals']} interval(s), {row['unmarkedSec']} s")
    for entry in inv["leftOut"]:
        print(f"  left out — {entry['recordingId']}: {entry['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
