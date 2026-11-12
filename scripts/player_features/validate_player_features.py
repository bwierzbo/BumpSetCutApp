#!/usr/bin/env python3
"""Fail-closed validator for a `player_features_v1` folder (docs/ml-roadmap/PLAYER_FEATURES_V1_CONTRACT.md).

Usage:
  validate_player_features.py <run>/features [--json]
  validate_player_features.py --write-synthetic <dir>   # a complete valid example (for tests)

Standard library only. Exit 0 when valid, 1 when refused, 2 on bad usage.
"""
import hashlib
import json
import math
import os
import sys

SCHEMA = "player_features_v1"
JOINTS = ["nose", "left_eye", "right_eye", "left_ear", "right_ear", "neck", "left_shoulder", "right_shoulder",
          "left_elbow", "right_elbow", "left_wrist", "right_wrist", "root", "left_hip", "right_hip",
          "left_knee", "right_knee", "left_ankle", "right_ankle"]
DEV_SPLITS = {"train", "dev_val", "tune"}
ELIGIBLE = {"standard", "restricted"}
COURT = {"in", "out", "unknown"}
# court_polygon_v1 (P2): a person's optional `zone` against a person-confirmed court.
ZONES = {"near_court", "far_court", "near_serving_area", "far_serving_area", "outside_court", "unknown"}
PLAYING = {"near_court", "far_court", "near_serving_area", "far_serving_area"}
STATES = {"tentative", "confirmed"}
SKIPS = {"cut": "cut", "time_break": "time_break"}
MANIFEST = "player-features-manifest.json"


def tick(t):
    """Swift's `(t * 600).rounded()`: half away from zero."""
    v = t * 600
    return int(math.floor(v + 0.5)) if v >= 0 else -int(math.floor(-v + 0.5))


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def write_bytes(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def closure_sha(w):
    text = "\n".join(list(w["names"]) + ["--"] + list(w["sourceIds"]) + ["--"] + list(w["fingerprints"]))
    return sha256_bytes(text.encode("utf-8"))


def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def validate(folder):
    errors, warnings = [], []
    mpath = os.path.join(folder, MANIFEST)
    if not os.path.isfile(mpath):
        return {"ok": False, "errors": [f"{MANIFEST} missing"], "warnings": []}
    try:
        m = json.loads(read_bytes(mpath).decode("utf-8"))
    except Exception as e:  # noqa: BLE001 - any decode failure refuses
        return {"ok": False, "errors": [f"{MANIFEST} unreadable: {e}"], "warnings": []}

    def need(cond, msg):
        if not cond:
            errors.append(msg)
        return cond

    need(m.get("schemaVersion") == SCHEMA, f"schemaVersion {m.get('schemaVersion')!r} is not {SCHEMA}")
    need(m.get("timescale") == 600, "timescale must be 600")
    need(m.get("coordinateSpace") == "vision_normalized_upright", "coordinateSpace must be vision_normalized_upright")
    need(m.get("jointNames") == JOINTS, "jointNames differ from the 19 Vision joints in order")
    for k in ("generator", "project", "splitManifest", "detector", "sampling", "tracker", "court", "derived", "recordings", "withheld"):
        need(k in m, f"manifest key {k} missing")
    w = m.get("withheld") or {}
    withheld_names, withheld_src, withheld_fp = set(w.get("names", [])), set(w.get("sourceIds", [])), set(w.get("fingerprints", []))
    if need(bool(withheld_names), "the withheld closure is missing or empty: nothing proves a withheld recording is kept out"):
        need(w.get("closureSha256") == closure_sha(w), "withheld.closureSha256 does not match the lists it carries")

    recs = m.get("recordings") or []
    need(bool(recs), "no recordings")
    expected_files = {MANIFEST}
    seen_ids, group_split, src_group, fp_group = set(), {}, {}, {}
    total = 0
    for r in recs:
        rid = r.get("recordingId", "?")
        p = f"{rid}:"
        need(rid not in seen_ids, f"{p} listed twice")
        seen_ids.add(rid)
        need(r.get("split") in DEV_SPLITS, f"{p} split {r.get('split')!r} is not a development split")
        need(rid not in withheld_names, f"{p} is withheld")
        if r.get("sourceId"):
            need(r["sourceId"] not in withheld_src, f"{p} sourceId is withheld")
            g = src_group.setdefault(r["sourceId"], r.get("groupId"))
            need(g == r.get("groupId"), f"{p} shares sourceId with another group")
        for fp in (r.get("fingerprint"), (r.get("decoded") or {}).get("fingerprint")):
            if fp:
                need(fp not in withheld_fp, f"{p} file fingerprint {fp} is withheld")
                g = fp_group.setdefault(fp, r.get("groupId"))
                need(g == r.get("groupId"), f"{p} shares a file with another group")
        gs = group_split.setdefault(r.get("groupId"), r.get("split"))
        need(gs == r.get("split"), f"{p} group {r.get('groupId')} has two splits")
        need((r.get("eligibility") or {}).get("rally_classifier") in ELIGIBLE, f"{p} not eligible for the rally classifier")
        dec = r.get("decoded") or {}
        need(dec.get("kind") in ("scrub_proxy", "original"), f"{p} decoded.kind must be scrub_proxy or original")
        need(num(r.get("aspect")) and r["aspect"] > 0, f"{p} aspect missing")
        intervals = r.get("intervals") or []
        need(bool(intervals), f"{p} no intervals")
        by_name = {}
        last_end = -1.0
        for iv in sorted(intervals, key=lambda i: i.get("startSec", 0)):
            need(iv.get("kind") in ("active_play", "between_rallies", "difficult"), f"{p} interval {iv.get('name')} kind invalid")
            need(num(iv.get("startSec")) and num(iv.get("endSec")) and iv["endSec"] > iv["startSec"], f"{p} interval {iv.get('name')} empty")
            need(iv.get("startSec", 0) >= last_end, f"{p} interval {iv.get('name')} overlaps the previous")
            last_end = iv.get("endSec", 0)
            by_name[iv.get("name")] = iv
        excluded = [(s["startTick"], s["endTick"], s["kind"]) for s in (r.get("cutRanges") or []) + (r.get("timeBreakingSpans") or [])]
        court_unknown = r.get("courtUnknownReason") is not None

        ff = r.get("framesFile", "")
        expected_files.add(ff)
        fpath = os.path.join(folder, ff)
        if not need(ff.startswith("frames/") and os.path.isfile(fpath), f"{p} frames file {ff!r} missing"):
            continue
        data = read_bytes(fpath)
        need(sha256_bytes(data) == r.get("framesSha256"), f"{p} framesSha256 mismatch")
        lines = [ln for ln in data.split(b"\n") if ln]
        need(len(lines) == r.get("frameCount"), f"{p} frameCount {r.get('frameCount')} != {len(lines)} lines")
        total += len(lines)
        prev = None
        track_seg = {}
        for n, raw in enumerate(lines, 1):
            q = f"{p}{n}:"
            try:
                f = json.loads(raw)
            except Exception:  # noqa: BLE001
                errors.append(f"{q} not JSON")
                continue
            t, k = f.get("t"), f.get("tick")
            if not need(num(t) and isinstance(k, int), f"{q} t/tick missing"):
                continue
            need(k == tick(t), f"{q} tick {k} != round(t*600) = {tick(t)}")
            iv = by_name.get(f.get("interval"))
            if not need(iv is not None, f"{q} unknown interval {f.get('interval')!r}"):
                continue
            need(iv["startSec"] - 1e-6 <= t < iv["endSec"], f"{q} t={t} outside its interval")
            seg, reset = f.get("seg"), f.get("reset")
            new_interval = prev is None or prev["interval"] != f.get("interval")
            if prev is not None:
                need(t > prev["t"], f"{q} time not increasing")
                need(seg == prev["seg"] + (1 if reset is not None else 0), f"{q} seg {seg} inconsistent with reset {reset!r}")
            else:
                need(seg == 0, f"{q} first segment must be 0")
            if new_interval:
                need(reset == "interval_start", f"{q} an interval's first frame must reset with interval_start")
            masks = f.get("masks") or {}
            inside = next((kind for s, e, kind in excluded if s <= k < e), None)
            persons = f.get("persons") or []
            if masks.get("ran") is False:
                need(masks.get("skipped") in SKIPS, f"{q} skipped reason {masks.get('skipped')!r} invalid")
                need(inside == masks.get("skipped"), f"{q} not analysed but not inside a {masks.get('skipped')} span")
                need(not persons and not f.get("unmatchedPoses"), f"{q} not analysed yet has persons")
            else:
                need(masks.get("ran") is True, f"{q} masks.ran missing")
                need(inside is None, f"{q} analysed inside excluded time ({inside})")
            ids = set()
            for person in persons:
                b = person.get("box") or {}
                need(all(num(b.get(c)) for c in ("x", "y", "w", "h")) and b.get("w", 0) > 0 and b.get("h", 0) > 0, f"{q} bad box")
                # Vision extends a person cut off by the frame edge beyond it (kept raw); the box must still overlap the frame.
                need(b.get("x", 0) < 1 and b.get("x", 0) + b.get("w", 0) > 0 and b.get("y", 0) < 1 and b.get("y", 0) + b.get("h", 0) > 0,
                     f"{q} box does not overlap the frame")
                need(num(person.get("conf")) and 0 <= person["conf"] <= 1, f"{q} bad conf")
                need(person.get("court") in COURT, f"{q} bad court")
                if court_unknown:
                    need(person.get("court") == "unknown", f"{q} court {person.get('court')} though the recording has no lane")
                zone = person.get("zone")
                if zone is not None:
                    need(zone.get("zone") in ZONES and zone.get("raw") in ZONES, f"{q} bad zone")
                    need(zone.get("foot") in ("ankles", "box"), f"{q} bad zone foot")
                    want = "unknown" if zone.get("zone") == "unknown" else ("in" if zone.get("zone") in PLAYING else "out")
                    need(person.get("court") == want, f"{q} court {person.get('court')} disagrees with zone {zone.get('zone')}")
                need(person.get("state") in STATES, f"{q} bad track state")
                tid = person.get("track")
                need(isinstance(tid, int) and tid not in ids, f"{q} track id {tid} missing or repeated in a frame")
                ids.add(tid)
                owner = track_seg.setdefault(tid, seg)
                need(owner == seg, f"{q} track {tid} reused across segments {owner} and {seg}")
                for pose in [person.get("pose")] if person.get("pose") is not None else []:
                    check_pose(pose, q, need)
            for pose in f.get("unmatchedPoses") or []:
                check_pose(pose, q, need)
            prev = {"t": t, "seg": seg, "interval": f.get("interval")}

    present = set()
    for root, _, files in os.walk(folder):
        for name in files:
            present.add(os.path.relpath(os.path.join(root, name), folder))
    for stray in sorted(present - expected_files):
        errors.append(f"stray file {stray}")
    return {"ok": not errors, "errors": errors, "warnings": warnings, "recordings": len(recs), "frames": total}


def check_pose(pose, q, need):
    j = pose.get("joints")
    if not need(isinstance(j, list) and len(j) == len(JOINTS), f"{q} pose joints must have {len(JOINTS)} slots"):
        return
    for slot in j:
        if slot is None:
            continue
        # The detector's raw joint score: Vision 0–1, RTMPose's SimCC score can exceed 1; a non-positive one is written null.
        need(all(num(slot.get(c)) for c in ("x", "y", "c")) and slot["c"] > 0, f"{q} bad joint {slot}")


def write_synthetic(out):
    """A small valid folder: two recordings, a cut, a skipped frame, a reset, nulls."""
    os.makedirs(os.path.join(out, "frames"), exist_ok=True)

    def joints(n):
        return [{"x": 0.5, "y": 0.5, "c": 0.8} if i < n else None for i in range(len(JOINTS))]

    def person(tid, court="in", pose=True, state="confirmed"):
        return {"box": {"x": 0.4, "y": 0.2, "w": 0.05, "h": 0.2}, "conf": 0.9, "track": tid, "state": state, "hits": 3, "gap": 0,
                "ambiguous": False, "court": court, "derived": {"speed": 0.1},
                **({"pose": {"conf": 0.7, "joints": joints(12)}} if pose else {})}

    def frame(t, interval, seg, reset, persons, ran=True, skipped=None):
        f = {"t": t, "tick": tick(t), "interval": interval, "seg": seg, "persons": persons, "unmatchedPoses": [],
             "scene": {"persons": len(persons), "confirmed": len(persons), "inCourt": len(persons), "posesInCourt": 0},
             "masks": {"ran": ran, "rectFailed": False, "poseFailed": False, **({"skipped": skipped} if skipped else {})}, "ms": {}}
        if reset:
            f["reset"] = reset
        return f

    recs = []
    specs = {
        "rec_a": ("in", [frame(10.0, "active_1", 0, "interval_start", [person(1)]), frame(10.2, "active_1", 0, None, [person(1)]),
                         frame(10.4, "active_1", 1, "cut_boundary", [], ran=False, skipped="cut"),
                         frame(10.6, "active_1", 2, "cut_boundary", [person(2, pose=False)]),
                         frame(30.0, "between_1", 3, "interval_start", [])],
                  [{"startTick": tick(10.3), "endTick": tick(10.5), "kind": "cut"}], None),
        "rec_b": ("unknown", [frame(5.0, "active_1", 0, "interval_start", [person(1, court="unknown", state="tentative")])], [],
                  "camera \"Sideline / near net\" is not behind the end line: the lane assumes it is"),
    }
    for rid, (_, frames, cuts, why) in specs.items():
        data = "".join(json.dumps(f, sort_keys=True) + "\n" for f in frames).encode("utf-8")
        write_bytes(os.path.join(out, "frames", f"{rid}.jsonl"), data)
        recs.append({"recordingId": rid, "groupId": rid, "split": "train", "surface": "beach", "camera": "End line, ground level",
                     "sourceId": None, "fingerprint": f"file:{rid}",
                     "decoded": {"kind": "scrub_proxy", "fileName": f"{rid}.mp4", "fingerprint": f"file:{rid}-proxy", "width": 960, "height": 540,
                                 "orientation": 1, "nominalFrameRate": 30, "durationSec": 60},
                     "aspect": 960 / 540, "recordingType": "continuous", "eligibility": {"rally_classifier": "standard"}, "eligibilityReasons": [],
                     "net": None, "courtUnknownReason": why, "cutRanges": cuts, "timeBreakingSpans": [],
                     "intervals": [{"name": "active_1", "kind": "active_play", "startSec": 10.0 if rid == "rec_a" else 5.0,
                                    "endSec": 25.0 if rid == "rec_a" else 20.0, "selection": "synthetic"}]
                     + ([{"name": "between_1", "kind": "between_rallies", "startSec": 30.0, "endSec": 45.0, "selection": "synthetic"}] if rid == "rec_a" else []),
                     "framesFile": f"frames/{rid}.jsonl", "framesSha256": sha256_bytes(data), "frameCount": len(frames)})
    w = {"names": ["held_1"], "sourceIds": [], "fingerprints": ["file:held_1"]}
    w["closureSha256"] = closure_sha(w)
    m = {"schemaVersion": SCHEMA, "createdAt": "2026-11-08T00:00:00Z", "generator": {"tool": "synthetic"}, "project": "synthetic",
         "splitManifest": {}, "withheld": w, "timescale": 600, "coordinateSpace": "vision_normalized_upright", "jointNames": JOINTS,
         "detector": {}, "sampling": {}, "tracker": {}, "court": {}, "derived": {}, "recordings": recs}
    write_bytes(os.path.join(out, MANIFEST), json.dumps(m, indent=2, sort_keys=True).encode("utf-8"))


def main(argv):
    if len(argv) >= 2 and argv[0] == "--write-synthetic":
        write_synthetic(argv[1])
        return 0
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    report = validate(argv[0])
    if "--json" in argv:
        print(json.dumps(report, indent=2))
    else:
        print(("✅ valid" if report["ok"] else "❌ refused") + f": {report.get('recordings', 0)} recordings, {report.get('frames', 0)} frames")
        for e in report["errors"][:50]:
            print("  - " + e)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
