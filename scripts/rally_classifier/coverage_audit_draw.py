#!/usr/bin/env python3
"""Draw the coverage-audit sample (docs/ml-roadmap/RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md §3).

Reads a frozen inventory (``coverage_audit_inventory_v1``: recordings with their rally marks, the split-manifest
hashes and the withheld closure; produced by an adapter that reads metadata only, never a video), computes every
unmarked interval per recording, draws stage 1 (``--per-surface`` recordings per surface, at most one per recording
group, at least one ``train`` and one ``tune`` recording per surface) with a fixed seed, draws the blind-repeat set
(``--repeat-fraction`` of the reviewed intervals, at least ``--repeat-min`` per recording), and writes the draw with
the inventory's SHA-256 so the sample is frozen before anyone opens a video. Refuses the withheld closure by name,
source id and fingerprint, refuses an empty closure, and never overwrites an existing draw. Standard library only.

    python3 scripts/rally_classifier/coverage_audit_draw.py <inventory.json> --out <draw.json> [--seed 20261103]
        [--per-surface 4] [--exclude <recordingId> ...] [--repeat-fraction 0.2] [--repeat-min 2]
    python3 scripts/rally_classifier/coverage_audit_draw.py <inventory.json> --all --out <draw.json>   # stage 2: every recording

Exit status 0 when the draw was written, 1 otherwise. Nothing is read but the inventory file.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import math
import os
import random
import sys

INVENTORY_VERSION = "coverage_audit_inventory_v1"
DRAW_VERSION = "coverage_audit_draw_v1"
MIN_REVIEW_SEC = 1.0           # an unmarked interval shorter than this cannot hold a rally: listed, not reviewed
DEFAULT_SEED = 20261103
MAX_SHUFFLES = 10000
REQUIRED_SPLITS = ("train", "tune")
MARK_KINDS = {"rally", "missedServe", "other"}


class DrawError(Exception):
    pass


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ----------------------------------------------------------------------------- inventory

def load_inventory(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            inv = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        raise DrawError(f"inventory unreadable: {e}")
    if not isinstance(inv, dict) or inv.get("schemaVersion") != INVENTORY_VERSION:
        raise DrawError(f"inventory schemaVersion must be {INVENTORY_VERSION!r}")
    for key in ("splitManifest", "withheld", "recordings", "project"):
        if key not in inv:
            raise DrawError(f"inventory missing {key!r}")
    wh = inv["withheld"]
    if not isinstance(wh, dict) or not all(isinstance(wh.get(k), list) for k in ("names", "sourceIds", "fingerprints")):
        raise DrawError("withheld must carry names, sourceIds and fingerprints lists")
    if not wh["names"]:
        raise DrawError("withheld.names is empty: an empty closure proves nothing; the inventory must carry the closure it refused")
    if not isinstance(inv["recordings"], list) or not inv["recordings"]:
        raise DrawError("recordings must be a non-empty list")
    names, sids, fps = set(wh["names"]), set(wh["sourceIds"]), set(wh["fingerprints"])
    seen = set()
    for i, r in enumerate(inv["recordings"]):
        where = f"recordings[{i}]"
        if not isinstance(r, dict):
            raise DrawError(f"{where}: not an object")
        for key in ("recordingId", "groupId", "surface", "split", "durationSec", "ralliesMarked", "marks", "marksSha256"):
            if key not in r:
                raise DrawError(f"{where}: missing {key!r}")
        rid = r["recordingId"]
        if rid in seen:
            raise DrawError(f"{where}: duplicate recordingId {rid!r}")
        seen.add(rid)
        if rid in names:
            raise DrawError(f"{where}: WITHHELD recording {rid!r} present (name in the closure)")
        if r.get("sourceId") and r["sourceId"] in sids:
            raise DrawError(f"{where}: WITHHELD recording {rid!r} present (sourceId in the closure)")
        if r.get("fingerprint") and r["fingerprint"] in fps:
            raise DrawError(f"{where}: WITHHELD recording {rid!r} present (fingerprint in the closure)")
        if r["ralliesMarked"] is not True:
            raise DrawError(f"{where}: {rid!r} is not declared complete (ralliesMarked != true); the audit is for declared-complete recordings")
        if not isinstance(r["durationSec"], (int, float)) or isinstance(r["durationSec"], bool) or not (r["durationSec"] > 0):
            raise DrawError(f"{where}: durationSec must be a positive number")
        if not isinstance(r["marks"], list):
            raise DrawError(f"{where}: marks must be a list")
        for j, m in enumerate(r["marks"]):
            mw = f"{where}.marks[{j}]"
            if not isinstance(m, dict) or not {"start", "end"} <= set(m):
                raise DrawError(f"{mw}: a mark needs start and end")
            if any(isinstance(m[k], bool) or not isinstance(m[k], (int, float)) or not math.isfinite(m[k]) for k in ("start", "end")):
                raise DrawError(f"{mw}: start and end must be finite numbers")
            if m.get("kind", "rally") not in MARK_KINDS:
                raise DrawError(f"{mw}: kind {m.get('kind')!r} not in {sorted(MARK_KINDS)}")
    return inv


# ----------------------------------------------------------------------------- intervals

def unmarked_intervals(marks, duration: float, min_review_sec: float = MIN_REVIEW_SEC) -> list:
    """The maximal intervals of [0, duration) that no mark covers (every kind counts as marked; overlapping marks are
    merged; a mark with end <= start is ignored; marks are clamped to the recording). Each interval carries whether it
    is reviewed (length >= min_review_sec) and why not."""
    spans = sorted((max(0.0, float(m["start"])), min(duration, float(m["end"]))) for m in marks)
    merged: list = []
    for s, e in spans:
        if e <= s:
            continue
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    out = []
    cursor = 0.0
    for s, e in merged + [[duration, duration]]:
        if s > cursor:
            length = s - cursor
            out.append({"index": len(out), "start": round(cursor, 3), "end": round(s, 3), "durationSec": round(length, 3),
                        "review": length >= min_review_sec, "reason": None if length >= min_review_sec else "too_short"})
        cursor = max(cursor, e)
    return out


# ----------------------------------------------------------------------------- draw

def draw_stage1(recordings: list, per_surface: int, rng: random.Random) -> list:
    """Per surface, `per_surface` recordings, at most one per group, at least one of each REQUIRED_SPLITS when the
    surface offers it; found by re-shuffling (deterministic under the seed), refused when infeasible."""
    chosen = []
    for surface in sorted({r["surface"] for r in recordings}):
        pool = sorted((r for r in recordings if r["surface"] == surface), key=lambda r: r["recordingId"])
        groups = {r["groupId"] for r in pool}
        if len(groups) < per_surface:
            raise DrawError(f"surface {surface!r}: {len(groups)} recording group(s), fewer than {per_surface} — reduce --per-surface or widen the inventory")
        need = [s for s in REQUIRED_SPLITS if any(r["split"] == s for r in pool)]
        pick = None
        for _ in range(MAX_SHUFFLES):
            order = pool[:]
            rng.shuffle(order)
            cand, used = [], set()
            for r in order:
                if r["groupId"] in used:
                    continue
                cand.append(r)
                used.add(r["groupId"])
                if len(cand) == per_surface:
                    break
            if len(cand) == per_surface and all(any(r["split"] == s for r in cand) for s in need):
                pick = cand
                break
        if pick is None:
            raise DrawError(f"surface {surface!r}: no draw of {per_surface} recordings from distinct groups holds every split in {need} after {MAX_SHUFFLES} shuffles")
        chosen.extend(sorted(pick, key=lambda r: r["recordingId"]))
    return chosen


def draw_repeat(intervals: list, fraction: float, minimum: int, rng: random.Random) -> list:
    reviewed = [iv["index"] for iv in intervals if iv["review"]]
    if not reviewed:
        return []
    k = min(len(reviewed), max(minimum, int(math.ceil(fraction * len(reviewed)))))
    return sorted(rng.sample(reviewed, k))


def build_draw(inventory_path: str, *, seed: int = DEFAULT_SEED, per_surface: int = 4, exclude=(), all_recordings: bool = False,
               repeat_fraction: float = 0.2, repeat_min: int = 2, now: str | None = None) -> dict:
    inv = load_inventory(inventory_path)
    excluded = sorted(set(exclude))
    known = {r["recordingId"] for r in inv["recordings"]}
    unknown = [x for x in excluded if x not in known]
    if unknown:
        raise DrawError(f"--exclude names not in the inventory: {unknown}")
    eligible = [r for r in inv["recordings"] if r["recordingId"] not in excluded]
    if not eligible:
        raise DrawError("no eligible recording after exclusions")
    rng = random.Random(seed)
    picked = sorted(eligible, key=lambda r: r["recordingId"]) if all_recordings else draw_stage1(eligible, per_surface, rng)
    out_recs, totals = [], {"recordings": 0, "intervals": 0, "reviewedIntervals": 0, "reviewSeconds": 0.0, "rallyMarks": 0, "marks": 0}
    for r in picked:
        ivs = unmarked_intervals(r["marks"], float(r["durationSec"]))
        rep = draw_repeat(ivs, repeat_fraction, repeat_min, rng)
        out_recs.append({"recordingId": r["recordingId"], "groupId": r["groupId"], "surface": r["surface"], "split": r["split"],
                         "camera": r.get("camera"), "durationSec": r["durationSec"], "fingerprint": r.get("fingerprint"),
                         "marksSha256": r["marksSha256"], "rallyMarks": sum(1 for m in r["marks"] if m.get("kind", "rally") == "rally"),
                         "intervals": ivs, "repeatIndices": rep})
        totals["recordings"] += 1
        totals["intervals"] += len(ivs)
        totals["reviewedIntervals"] += sum(1 for iv in ivs if iv["review"])
        totals["reviewSeconds"] = round(totals["reviewSeconds"] + sum(iv["durationSec"] for iv in ivs if iv["review"]), 3)
        totals["rallyMarks"] += out_recs[-1]["rallyMarks"]
        totals["marks"] += len(r["marks"])
    created = now or _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "schemaVersion": DRAW_VERSION, "createdAt": created,
        "drawId": f"coverage-audit-{created.replace(':', '').replace('-', '')}-seed{seed}",
        "stage": "all" if all_recordings else "stage1",
        "seed": seed, "perSurface": None if all_recordings else per_surface, "repeatFraction": repeat_fraction, "repeatMin": repeat_min,
        "minReviewSec": MIN_REVIEW_SEC, "excluded": excluded,
        "inventory": {"path": os.path.basename(inventory_path), "sha256": sha256_file(inventory_path), "project": inv["project"],
                      "splitManifest": inv["splitManifest"], "withheld": {k: len(inv["withheld"][k]) for k in ("names", "sourceIds", "fingerprints")}},
        "recordings": out_recs, "totals": totals,
    }


def write_draw(draw: dict, out_path: str) -> None:
    if os.path.exists(out_path):
        raise DrawError(f"{out_path} exists: a draw is never overwritten; write a new file with a new stamp and a stated reason")
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(draw, fh, indent=1, sort_keys=True)
    os.replace(tmp, out_path)


# ----------------------------------------------------------------------------- CLI

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("inventory", help="the frozen inventory JSON (coverage_audit_inventory_v1)")
    ap.add_argument("--out", required=True, help="the draw file to write (must not exist)")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--per-surface", type=int, default=4)
    ap.add_argument("--exclude", action="append", default=[], metavar="RECORDING", help="leave this recording out of the draw (repeatable)")
    ap.add_argument("--all", action="store_true", help="list every eligible recording's intervals (stage 2) instead of drawing stage 1")
    ap.add_argument("--repeat-fraction", type=float, default=0.2)
    ap.add_argument("--repeat-min", type=int, default=2)
    args = ap.parse_args(argv)
    try:
        draw = build_draw(args.inventory, seed=args.seed, per_surface=args.per_surface, exclude=args.exclude, all_recordings=args.all,
                          repeat_fraction=args.repeat_fraction, repeat_min=args.repeat_min)
        write_draw(draw, args.out)
    except DrawError as e:
        print(f"error: {e}")
        return 1
    t = draw["totals"]
    print(f"wrote {args.out}: {draw['drawId']}; {t['recordings']} recording(s), {t['reviewedIntervals']} interval(s) to review "
          f"({t['reviewSeconds']} s), {t['rallyMarks']} rally marks; inventory sha256 {draw['inventory']['sha256'][:16]}…")
    return 0


if __name__ == "__main__":
    sys.exit(main())
