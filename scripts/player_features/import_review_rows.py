#!/usr/bin/env python3
"""Fills a court-review folder's persons.csv and frames.csv from the owner's labels on the Court Check page (a private
claude.ai artifact; Claude exports its `labels` documents to JSON). Only what the owner entered is written: a box with no
label stays blank, a frame whose missed counts were never set stays blank. The unfilled sheets are kept once as
persons.blank.csv / frames.blank.csv. Stdlib only.

usage: import_review_rows.py <export.json> <review-folder>
export.json: {"artifact": "<url>", "labels": [{"id": "<image stem>", "recordingId", "tick", "image", "labels": {"<track>": "<label>"},
              "missedNear": n|null, "missedFar": n|null, "notes": "", "by": "<viewer id>"}, ...]}
"""
import csv
import json
import os
import shutil
import sys

LABELS = {"near_court", "far_court", "near_serving_area", "far_serving_area", "player_off_court", "spectator", "adjacent_court",
          "referee_or_other", "duplicate_or_not_a_person", "unsure"}


def read(path):
    with open(path, newline="", encoding="utf-8") as f:
        r = csv.DictReader(f)
        return r.fieldnames, list(r)


def write(path, header, rows):
    tmp = path + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    os.replace(tmp, path)


def fill(export, folder):
    """Returns (labelled boxes, frames with both missed counts). Raises ValueError on a label or box the sheets don't have."""
    docs = {d["image"]: d for d in export["labels"]}
    reviewer = "owner (Court Check page %s)" % export.get("artifact", "")
    paths = {k: os.path.join(folder, k + ".csv") for k in ("persons", "frames")}
    for k, p in paths.items():
        blank = os.path.join(folder, k + ".blank.csv")
        if not os.path.exists(blank):
            shutil.copyfile(p, blank)
    ph, persons = read(os.path.join(folder, "persons.blank.csv"))
    fh, frames = read(os.path.join(folder, "frames.blank.csv"))
    known = {(r["image"], r["track"]) for r in persons}
    images = {r["image"] for r in frames}
    for image, d in docs.items():
        if image not in images:
            raise ValueError("the export has a frame the sheets don't: %s" % image)
        for track, label in (d.get("labels") or {}).items():
            if label not in LABELS:
                raise ValueError("unknown label %r on %s #%s" % (label, image, track))
            if (image, str(track)) not in known:
                raise ValueError("the export labels a box the sheets don't have: %s #%s" % (image, track))
    boxes = 0
    for r in persons:
        d = docs.get(r["image"])
        label = (d.get("labels") or {}).get(r["track"]) if d else None
        if label:
            r["label"], r["reviewer"] = label, reviewer
            boxes += 1
    counted = 0
    for r in frames:
        d = docs.get(r["image"])
        if not d:
            continue
        near, far = d.get("missedNear"), d.get("missedFar")
        if near is not None:
            r["missed_near_players"] = str(int(near))
        if far is not None:
            r["missed_far_players"] = str(int(far))
        if near is not None or far is not None or d.get("labels"):
            r["reviewer"] = reviewer
        r["notes"] = (d.get("notes") or "").replace("\n", " ").strip()
        counted += near is not None and far is not None
    write(paths["persons"], ph, persons)
    write(paths["frames"], fh, frames)
    return boxes, counted


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        export = json.load(f)
    boxes, counted = fill(export, argv[2])
    print("filled %d labelled boxes and %d frames with both missed counts" % (boxes, counted))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
