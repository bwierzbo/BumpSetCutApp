#!/usr/bin/env python3
"""
Train the net detector from scratch, in plain PyTorch — no Ultralytics
code, weights or licence anywhere in it (decision of 2026-10-30,
docs/decisions/2026-10-30-net-model-direction.md).

The model sees one upright RGB frame, letterboxed to 384×216, and answers
nine numbers: is a net there (0–1) and the net's four corners — top-left,
top-right, bottom-right, bottom-left, each as x, y fractions of the frame,
y downwards (owner, 2026-10-31: the label is the four corners, since a
perspective net is a quadrilateral). The box a consumer reads is the
rectangle that just contains the corners. The pipeline reads three things
off that box: its top edge (the above-net gate, no margin) and its left and
right edges (the off-court gate, ±0.05 of the frame width), so the numbers
that matter are the top corners' error in frame heights, the side errors in
frame widths and the corner error, not a mAP.

Data:
    python train_net_model.py <RallyLab net dataset> --manifest <manifests/manifest.json>
                              [--extra <YOLO folder>]... [--epochs 40] [--seed N]
                              [--val-fraction 0.25] [--split <split.json>] [--name net_v1]
    python train_net_model.py <dataset> --manifest <m> --score-only <best.pt> --name <run>

  <RallyLab net dataset>  a folder written by `RallyLab --project P --export-net-dataset`:
      images/<video>.jpg, labels/<video>.txt (YOLO, class 0 = net: the corners'
      bounding box), net-dataset.json (every entry's four `corners`, Vision-
      normalised bottom-up, which are the label; an entry without them stops
      the run, and so does a YOLO box that is not the corners' bounds).
      Every entry is checked against the split manifest before it is used: the
      recording must be in the manifest, not withheld (lineage or legacy holdout,
      final test or candidate, or reserved as an alias of one), and the entry's
      fingerprint must be the manifest's; every image's SHA-256 must be the one
      the export recorded. Any failure stops the run naming the recording —
      the export refuses the same things, and the trainer refuses them again
      (D-002: an exclusion is only real if every consumer honours it).
  --extra <folder>  a YOLO-format folder from elsewhere (a Roboflow export): data.yaml
      with `names`, images and labels under train/valid/test or flat. Only the
      `net` class is read; an image with no net line is a no-net example. The
      folder must carry a provenance.json (`source`, `license`, `obtained`,
      `note`), recorded in metrics.json; without it the folder is refused.
      Extra images have no recording identity, so they only ever train: the
      validation set is our own recordings, split by recording group. They have
      boxes, not corners, so they supervise only the box the predicted corners
      span, never the corners themselves.

Validation: whole recording groups (videos of one clip card, alias group,
confirmed session or venue, or uploader, from the manifest, as
paired_compare.py groups them) are held out per surface until about
--val-fraction of each surface's frames is val. The groups chosen are
written to runs/net/<name>/split.json; pass that file as --split to another
run to validate on the same frames (and to compare two runs fairly).

Scores on the val frames: detect rate at 0.5; over the detected ones the
top error (the two top corners' vertical error, mean of the two, in frame
heights: median, mean, 90th percentile), the left/right edge errors of the
corners' box (frame widths), the corner error (mean distance of the four
corners, frame fractions), IoU of the boxes; by surface and by group; and
a 90% range of the median top error from resampling whole groups. The
checkpoint kept is the one with the lowest mean top error counting an
undetected net as an error of 1 (a miss is worse than any mislocation).

Results:
    runs/net/<name>/   best.pt  best.onnx  metrics.json  log.csv  split.json
    bring_back/<name>/ the same  ← copy this folder back; net_to_coreml.py converts it

The ONNX/Core ML model takes "frame" [1, 3, 216, 384] RGB 0–1 (letterboxed:
scaled to fit, centred, grey borders) and gives "net" [1, 9]: presence, then
x, y of the top-left, top-right, bottom-right and bottom-left corners in the
letterboxed frame (all 0–1, y downwards). The caller maps the corners back
through the same letterbox (`letterbox_corners_back`) and takes their
bounds (`corners_box`) where it needs a box.

Needs: torch (CUDA on the desktop; CPU works for the tests), opencv-python,
numpy, onnx. No other package.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

WIDTH, HEIGHT = 384, 216
NET_CLASS = "net"
PAD_GREY = 114
WITHHELD_SPLITS = {"lineage_holdout", "legacy_holdout", "final_test_candidate", "final_test"}
PRESENCE_THRESHOLD = 0.5
PROVENANCE_FIELDS = ("source", "license", "obtained", "note")
DRAWS, DRAW_SEED = 1000, 0


def say(msg: str) -> None:
    print(msg, flush=True)


def fail(msg: str) -> None:
    sys.exit(f"❌ {msg}")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Samples and labels


CORNER_NAMES = ("topLeft", "topRight", "bottomRight", "bottomLeft")
BOX_TOLERANCE = 1e-4


@dataclass
class Sample:
    image: Path
    video: str                # the recording (or the extra image's stem)
    group: str                # recording group; "extra:<folder>" for an extra image
    surface: str              # beach / grass / indoor / extra
    source: str               # "rallylab" or the extra folder's name
    box: Optional[tuple]      # (cx, cy, w, h), fractions of the frame, y down; None = no net
    corners: Optional[tuple] = None   # ((x, y) × 4: TL, TR, BR, BL), frame fractions, y down; None = box only (extra)


def rect_corners(box: tuple) -> tuple:
    """A box's corners in label order (top-left, top-right, bottom-right, bottom-left), y down."""
    l, t, r, b = edges(box)
    return ((l, t), (r, t), (r, b), (l, b))


def corners_box(corners: tuple) -> tuple:
    """The (cx, cy, w, h) box that just contains four corners."""
    xs, ys = [p[0] for p in corners], [p[1] for p in corners]
    l, r, t, b = min(xs), max(xs), min(ys), max(ys)
    return ((l + r) / 2, (t + b) / 2, r - l, b - t)


def read_corners(entry: dict, video: str) -> tuple:
    """The export's four corners, Vision-normalised (bottom-up) by name, as y-down frame fractions."""
    raw = entry.get("corners")
    if not isinstance(raw, dict) or any(k not in raw for k in CORNER_NAMES):
        fail(f"{video}: no corners in net-dataset.json — a box-only label from before corners were marked; "
             "mark the corners in the Net labels tab and export again")
    out = []
    for k in CORNER_NAMES:
        p = raw[k]
        try:
            x, y = float(p["x"]), float(p["y"])
        except (KeyError, TypeError, ValueError):
            fail(f"{video}: corner {k} is not an x, y point: {p!r}")
        if not (0 <= x <= 1 and 0 <= y <= 1):
            fail(f"{video}: corner {k} is outside the frame: {p!r}")
        out.append((x, 1 - y))
    return tuple(out)


def parse_yolo(text: str, net_index: int) -> tuple[Optional[tuple], int]:
    """The net boxes in a YOLO label file: the largest one as (cx, cy, w, h) and
    how many net lines there were. A line that is not `class cx cy w h` with the
    four in 0…1 and a positive size is an error, not a skipped line."""
    boxes = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 5:
            raise ValueError(f"line {n}: expected `class cx cy w h`, got {raw!r}")
        try:
            cls = int(parts[0])
            cx, cy, w, h = (float(p) for p in parts[1:])
        except ValueError as e:
            raise ValueError(f"line {n}: {e}") from None
        if cls != net_index:
            continue
        if not (0 <= cx <= 1 and 0 <= cy <= 1 and 0 < w <= 1 and 0 < h <= 1):
            raise ValueError(f"line {n}: box out of the frame or empty: {raw!r}")
        boxes.append((cx, cy, w, h))
    if not boxes:
        return None, 0
    return max(boxes, key=lambda b: b[2] * b[3]), len(boxes)


def surface_of(video: str, manifest_row: Optional[dict]) -> str:
    if manifest_row and manifest_row.get("surface"):
        return str(manifest_row["surface"])
    prefix = video.split("_", 1)[0]
    return {"bch": "beach", "grs": "grass", "ind": "indoor"}.get(prefix, "unknown")


def load_manifest(path: Path) -> tuple[dict, dict[str, dict]]:
    manifest = json.loads(path.read_text())
    return manifest, {row["video"]: row for row in manifest["videos"]}


def read_rallylab_export(root: Path, manifest_rows: dict[str, dict]) -> tuple[list[Sample], dict]:
    """The frames of a `--export-net-dataset` folder, each checked against the
    manifest and against the export's own record before it is a sample."""
    record_path = root / "net-dataset.json"
    if not record_path.exists():
        fail(f"{root}: no net-dataset.json — not a RallyLab net dataset export")
    record = json.loads(record_path.read_text())
    names = read_names(root / "data.yaml") if (root / "data.yaml").exists() else {0: NET_CLASS}
    net_index = index_of_net(names, root)
    samples: list[Sample] = []
    multi = 0
    for entry in record["entries"]:
        video = entry["video"]
        row = manifest_rows.get(video)
        if row is None:
            fail(f"{video}: not in the manifest — its identity and split are unknown, so it is not used")
        if row.get("split") in WITHHELD_SPLITS or row.get("reservedAs"):
            fail(f"{video}: withheld in the manifest (split {row.get('split')}, reservedAs {row.get('reservedAs')}) — "
                 "a withheld recording never trains or validates a model")
        if row.get("fingerprint") and row["fingerprint"] != entry.get("fingerprint"):
            fail(f"{video}: the export's fingerprint is not the manifest's — the label is another file's")
        image = root / entry["image"]
        if not image.exists():
            fail(f"{video}: {image} is missing")
        if sha256_file(image) != entry["imageSHA256"]:
            fail(f"{video}: {image.name} is not the file the export recorded (SHA-256 differs)")
        label = root / "labels" / f"{video}.txt"
        if not label.exists():
            fail(f"{video}: no label file {label}")
        try:
            box, count = parse_yolo(label.read_text(), net_index)
        except ValueError as e:
            fail(f"{label}: {e}")
        if box is None:
            fail(f"{video}: the label file has no net line — an exported recording always has a net box")
        corners = read_corners(entry, video)
        if max(abs(a - b) for a, b in zip(box, corners_box(corners))) > BOX_TOLERANCE:
            fail(f"{video}: the YOLO box {box} is not the corners' bounds {corners_box(corners)} — the export is inconsistent")
        multi += count > 1
        samples.append(Sample(image=image, video=video, group=video, surface=surface_of(video, row),
                              source="rallylab", box=box, corners=corners))
    info = {"folder": str(root), "project": record.get("project"), "createdAt": record.get("createdAt"),
            "entries": len(samples), "skipped_by_export": len(record.get("skipped", [])), "multi_net_images": multi,
            "record_sha256": sha256_file(record_path)}
    return samples, info


def read_names(yaml_path: Path) -> dict[int, str]:
    """`names:` from a data.yaml, either `names: [a, b]` or `names:\\n  0: a`. No
    YAML package is needed for the two shapes Roboflow and our export write."""
    names: dict[int, str] = {}
    lines = yaml_path.read_text().splitlines()
    for i, raw in enumerate(lines):
        line = raw.strip()
        if not line.startswith("names:"):
            continue
        rest = line[len("names:"):].strip()
        if rest.startswith("["):
            items = [s.strip().strip("'\"") for s in rest.strip("[]").split(",") if s.strip()]
            return {k: v for k, v in enumerate(items)}
        for sub in lines[i + 1:]:
            s = sub.strip()
            if not s or not (sub.startswith(" ") or sub.startswith("\t")):
                break
            if s.startswith("- "):
                names[len(names)] = s[2:].strip().strip("'\"")
            elif ":" in s:
                k, v = s.split(":", 1)
                names[int(k.strip())] = v.strip().strip("'\"")
        return names
    fail(f"{yaml_path}: no `names:` entry")
    return names


def index_of_net(names: dict[int, str], where: Path) -> int:
    for k, v in names.items():
        if v.strip().lower() == NET_CLASS:
            return k
    fail(f"{where}: no class named `{NET_CLASS}` in {names} — nothing here is a net label")
    return -1


def read_extra_folder(root: Path) -> tuple[list[Sample], dict]:
    """A YOLO-format folder from elsewhere: provenance required, net class only,
    no recording identity (train only)."""
    prov_path = root / "provenance.json"
    if not prov_path.exists():
        fail(f"{root}: no provenance.json ({', '.join(PROVENANCE_FIELDS)}) — where this data came from and under what "
             "licence must be on record before it trains anything")
    prov = json.loads(prov_path.read_text())
    missing = [f for f in PROVENANCE_FIELDS if not str(prov.get(f, "")).strip()]
    if missing:
        fail(f"{prov_path}: missing {missing}")
    yaml_path = root / "data.yaml"
    if not yaml_path.exists():
        fail(f"{root}: no data.yaml")
    net_index = index_of_net(read_names(yaml_path), yaml_path)
    image_dirs = [d for d in (root / "train" / "images", root / "valid" / "images", root / "test" / "images",
                              root / "images") if d.is_dir()]
    if not image_dirs:
        fail(f"{root}: no images folder (train/images, valid/images, test/images or images)")
    samples: list[Sample] = []
    negatives = multi = 0
    for image_dir in image_dirs:
        label_dir = image_dir.parent / "labels"
        for image in sorted(p for p in image_dir.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png")):
            label = label_dir / f"{image.stem}.txt"
            box, count = (None, 0)
            if label.exists():
                try:
                    box, count = parse_yolo(label.read_text(), net_index)
                except ValueError as e:
                    fail(f"{label}: {e}")
            negatives += box is None
            multi += count > 1
            samples.append(Sample(image=image, video=f"{root.name}/{image.stem}", group=f"extra:{root.name}",
                                  surface="extra", source=root.name, box=box))
    if not samples:
        fail(f"{root}: no images")
    info = {"folder": str(root), "provenance": {f: prov[f] for f in PROVENANCE_FIELDS}, "images": len(samples),
            "no_net_images": negatives, "multi_net_images": multi, "net_class_index": net_index}
    return samples, info


def group_samples(samples: list[Sample], manifest_path: Path) -> None:
    """Give every RallyLab sample its recording group from the manifest."""
    from paired_compare import clusters_from_manifest
    videos = sorted({s.video for s in samples if s.source == "rallylab"})
    if not videos:
        return
    groups = clusters_from_manifest(manifest_path, videos)
    for s in samples:
        if s.source == "rallylab":
            s.group = groups[s.video]


def split_by_group(samples: list[Sample], fraction: float, rng: random.Random,
                   val_groups: Optional[set[str]] = None) -> tuple[list[Sample], list[Sample], list[str]]:
    """Hold out whole recording groups per surface until about `fraction` of that
    surface's frames are val (at least one group where a surface has two). Extra
    images always train. With `val_groups` given, exactly those are val."""
    ours = [s for s in samples if s.source == "rallylab"]
    if val_groups is None:
        chosen: set[str] = set()
        for surface in sorted({s.surface for s in ours}):
            of_surface = [s for s in ours if s.surface == surface]
            groups = sorted({s.group for s in of_surface})
            if len(groups) < 2:
                continue   # one group: nothing to hold out without losing the surface from training
            rng.shuffle(groups)
            want, got, taken = fraction * len(of_surface), 0, 0
            for g in groups:
                if got >= want and taken > 0 or taken >= len(groups) - 1:
                    break
                chosen.add(g)
                taken += 1
                got += sum(1 for s in of_surface if s.group == g)
        val_groups = chosen
    unknown = sorted(val_groups - {s.group for s in ours})
    if unknown:
        fail(f"--split names groups that are not in this dataset: {unknown}")
    val = [s for s in ours if s.group in val_groups]
    train = [s for s in samples if s.source != "rallylab" or s.group not in val_groups]
    return train, val, sorted(val_groups)


def dataset_digest(samples: list[Sample]) -> str:
    """SHA-256 over every sample's image bytes and box, in a fixed order."""
    h = hashlib.sha256()
    for s in sorted(samples, key=lambda s: (s.source, s.video)):
        h.update(f"{s.source}\t{s.video}\t{s.box}\t{s.corners}\n".encode())
        h.update(bytes.fromhex(sha256_file(s.image)))
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Letterbox and boxes


def letterbox_params(w: int, h: int) -> tuple[float, int, int]:
    """Scale and offsets that fit a w×h image centred in WIDTH×HEIGHT."""
    scale = min(WIDTH / w, HEIGHT / h)
    nw, nh = int(round(w * scale)), int(round(h * scale))
    return scale, (WIDTH - nw) // 2, (HEIGHT - nh) // 2


def letterbox_image(img: np.ndarray) -> tuple[np.ndarray, tuple[float, int, int]]:
    import cv2
    h, w = img.shape[:2]
    scale, ox, oy = letterbox_params(w, h)
    nw, nh = int(round(w * scale)), int(round(h * scale))
    resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_LINEAR)
    canvas = np.full((HEIGHT, WIDTH, 3), PAD_GREY, dtype=np.uint8)
    canvas[oy:oy + nh, ox:ox + nw] = resized
    return canvas, (scale, ox, oy)


def letterbox_box(box: tuple, w: int, h: int) -> tuple:
    """A frame-fraction box (cx, cy, bw, bh) as fractions of the letterboxed canvas."""
    scale, ox, oy = letterbox_params(w, h)
    cx, cy, bw, bh = box
    return ((cx * w * scale + ox) / WIDTH, (cy * h * scale + oy) / HEIGHT, bw * w * scale / WIDTH, bh * h * scale / HEIGHT)


def letterbox_back(box: tuple, w: int, h: int) -> tuple:
    """The inverse: a canvas-fraction box back to fractions of the w×h frame."""
    scale, ox, oy = letterbox_params(w, h)
    cx, cy, bw, bh = box
    return ((cx * WIDTH - ox) / (w * scale), (cy * HEIGHT - oy) / (h * scale), bw * WIDTH / (w * scale), bh * HEIGHT / (h * scale))


def letterbox_corners(corners: tuple, w: int, h: int) -> tuple:
    """Frame-fraction points as fractions of the letterboxed canvas."""
    scale, ox, oy = letterbox_params(w, h)
    return tuple(((x * w * scale + ox) / WIDTH, (y * h * scale + oy) / HEIGHT) for x, y in corners)


def letterbox_corners_back(corners: tuple, w: int, h: int) -> tuple:
    """The inverse: canvas-fraction points back to fractions of the w×h frame."""
    scale, ox, oy = letterbox_params(w, h)
    return tuple(((x * WIDTH - ox) / (w * scale), (y * HEIGHT - oy) / (h * scale)) for x, y in corners)


def flat(corners: tuple) -> tuple:
    return tuple(v for p in corners for v in p)


def unflat(values) -> tuple:
    v = [float(x) for x in values]
    return tuple((v[i], v[i + 1]) for i in range(0, 8, 2))


def edges(box: tuple) -> tuple[float, float, float, float]:
    """(left, top, right, bottom) of a (cx, cy, w, h) box."""
    cx, cy, w, h = box
    return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)


def iou(a: tuple, b: tuple) -> float:
    al, at, ar, ab = edges(a)
    bl, bt, br, bb = edges(b)
    iw, ih = max(0.0, min(ar, br) - max(al, bl)), max(0.0, min(ab, bb) - max(at, bt))
    inter = iw * ih
    union = (ar - al) * (ab - at) + (br - bl) * (bb - bt) - inter
    return inter / union if union > 0 else 0.0


# ---------------------------------------------------------------------------
# Scores


def summarize(rows: list[dict], rng_seed: int = DRAW_SEED, draws: int = DRAWS) -> dict:
    """`rows`: one per val sample with keys video, group, surface, has_net, presence,
    pred (canvas corners, 4 × (x, y), or None), truth (the same or None), w, h (frame size)."""
    positives = [r for r in rows if r["has_net"]]
    negatives = [r for r in rows if not r["has_net"]]
    detected = [r for r in positives if r["presence"] >= PRESENCE_THRESHOLD]

    def errors(r: dict) -> dict:
        p, t = letterbox_corners_back(r["pred"], r["w"], r["h"]), letterbox_corners_back(r["truth"], r["w"], r["h"])
        pb, tb = corners_box(p), corners_box(t)
        pl, _, pr, _ = edges(pb)
        tl, _, tr, _ = edges(tb)
        # The top error is the two tape ends' vertical error (what the above-net gate reads along the tape).
        top = (abs(p[0][1] - t[0][1]) + abs(p[1][1] - t[1][1])) / 2
        corner = float(np.mean([((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5 for a, b in zip(p, t)]))
        return {"top": top, "left": abs(pl - tl), "right": abs(pr - tr), "corner": corner, "iou": iou(pb, tb)}

    errs = [errors(r) for r in detected]

    def stats(values: list[float]) -> dict:
        if not values:
            return {"median": None, "mean": None, "p90": None}
        a = np.array(values)
        return {"median": float(np.median(a)), "mean": float(a.mean()), "p90": float(np.percentile(a, 90))}

    def block(pos: list[dict], det: list[dict], det_errs: list[dict]) -> dict:
        misses = len(pos) - len(det)
        with_misses = ([e["top"] for e in det_errs] + [1.0] * misses)
        return {"frames": len(pos), "detected": len(det), "detect_rate": (len(det) / len(pos)) if pos else None,
                "top_error": stats([e["top"] for e in det_errs]), "left_error": stats([e["left"] for e in det_errs]),
                "right_error": stats([e["right"] for e in det_errs]), "corner_error": stats([e["corner"] for e in det_errs]),
                "iou_mean": float(np.mean([e["iou"] for e in det_errs])) if det_errs else None,
                "iou_at_50": (sum(e["iou"] >= 0.5 for e in det_errs) / len(det_errs)) if det_errs else None,
                "top_error_mean_with_misses": float(np.mean(with_misses)) if with_misses else None}

    result = block(positives, detected, errs)
    result["no_net_frames"] = len(negatives)
    result["no_net_correct"] = (sum(r["presence"] < PRESENCE_THRESHOLD for r in negatives) / len(negatives)) if negatives else None
    result["by_surface"] = {}
    for surface in sorted({r["surface"] for r in positives}):
        pos = [r for r in positives if r["surface"] == surface]
        det = [(r, e) for r, e in zip(detected, errs) if r["surface"] == surface]
        result["by_surface"][surface] = block(pos, [r for r, _ in det], [e for _, e in det])
    result["by_group"] = {}
    for group in sorted({r["group"] for r in positives}):
        pos = [r for r in positives if r["group"] == group]
        det = [(r, e) for r, e in zip(detected, errs) if r["group"] == group]
        b = block(pos, [r for r, _ in det], [e for _, e in det])
        result["by_group"][group] = {"frames": b["frames"], "detected": b["detected"], "top_median": b["top_error"]["median"],
                                    "top_error_mean_with_misses": b["top_error_mean_with_misses"],
                                    "videos": sorted({r["video"] for r in pos})}
    # A 90% range of the median top error from resampling whole groups (each draw takes every frame of a drawn group).
    groups = sorted({r["group"] for r in detected})
    if len(groups) >= 2:
        by_group = {g: [e["top"] for r, e in zip(detected, errs) if r["group"] == g] for g in groups}
        rng = np.random.default_rng(rng_seed)
        medians = []
        for _ in range(draws):
            pick = rng.choice(groups, size=len(groups), replace=True)
            vals = [v for g in pick for v in by_group[g]]
            medians.append(float(np.median(vals)))
        result["top_median_range90"] = {"low": float(np.percentile(medians, 5)), "high": float(np.percentile(medians, 95)),
                                        "groups": len(groups), "draws": draws, "seed": rng_seed}
    else:
        result["top_median_range90"] = None
    return result


def describe(m: dict) -> str:
    t = m["top_error"]
    rng = m.get("top_median_range90")
    return (f"detect {m['detect_rate']:.1%} ({m['detected']}/{m['frames']})  "
            + (f"top err median {t['median']:.4f} mean {t['mean']:.4f} p90 {t['p90']:.4f} H  " if t["median"] is not None else "top err —  ")
            + (f"sides median L {m['left_error']['median']:.4f} R {m['right_error']['median']:.4f} W  " if m["left_error"]["median"] is not None else "")
            + (f"corners median {m['corner_error']['median']:.4f}  " if m["corner_error"]["median"] is not None else "")
            + (f"IoU {m['iou_mean']:.3f}  " if m["iou_mean"] is not None else "")
            + (f"[90% median {rng['low']:.4f}–{rng['high']:.4f} over {rng['groups']} groups]  " if rng else "")
            + (f"no-net right {m['no_net_correct']:.1%}  " if m["no_net_correct"] is not None else "")
            + (f"best-by {m['top_error_mean_with_misses']:.4f}" if m["top_error_mean_with_misses"] is not None else "best-by —"))


# ---------------------------------------------------------------------------
# Torch side (imported lazily so the data and score code runs without it)


def torch_modules():
    try:
        import torch
        import torch.nn as nn
    except ImportError:
        fail("Missing torch. In the .venv: pip install torch (see train_ball_model.py)")
    return torch, nn


def build_model():
    """A small CNN from scratch: 6 stride-2 blocks over the letterboxed frame with two
    coordinate channels (where in the frame each pixel is — a corner regressor needs
    position), then the 4×6 map flattened into the nine outputs (logits; sigmoid
    makes them presence and the four corners' x, y)."""
    torch, nn = torch_modules()

    class NetBoxNet(nn.Module):
        def __init__(self):
            super().__init__()
            chans = [5, 16, 32, 64, 96, 128, 160]
            layers = []
            for cin, cout in zip(chans, chans[1:]):
                layers += [nn.Conv2d(cin, cout, 3, stride=2, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
                           nn.Conv2d(cout, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True)]
            self.features = nn.Sequential(*layers)
            self.head = nn.Sequential(nn.Flatten(), nn.Linear(160 * 4 * 6, 256), nn.ReLU(inplace=True), nn.Dropout(0.2), nn.Linear(256, 9))
            ys = torch.linspace(-1, 1, HEIGHT).view(1, 1, HEIGHT, 1).expand(1, 1, HEIGHT, WIDTH)
            xs = torch.linspace(-1, 1, WIDTH).view(1, 1, 1, WIDTH).expand(1, 1, HEIGHT, WIDTH)
            self.register_buffer("coords", torch.cat([xs, ys], dim=1))

        def forward(self, frame):
            x = torch.cat([frame, self.coords.expand(frame.shape[0], -1, -1, -1)], dim=1)
            return self.head(self.features(x))

    class Deploy(nn.Module):
        """What is exported: sigmoid on all nine, so the consumer reads presence and the corners directly."""
        def __init__(self, net):
            super().__init__()
            self.net = net

        def forward(self, frame):
            return torch.sigmoid(self.net(frame))

    return NetBoxNet, Deploy


class Frames:
    """A torch Dataset over samples: letterboxed RGB 0–1 tensors and targets
    (presence; the four corners' x, y in canvas fractions; whether the corners
    are known — an extra image has only a box, whose corners stand in so the
    box the prediction spans can be supervised). Training augments: a flip,
    a crop that keeps the net whole, brightness and contrast, a little noise —
    drawn from (seed, epoch, index), so a frame gets a fresh augmentation every
    epoch and the same one when the run is repeated. The training loop sets
    `epoch` before each pass; the loader's workers are not persistent, so they
    pick the dataset up again, epoch included."""

    def __init__(self, samples: list[Sample], train: bool, seed: int):
        self.samples, self.train, self.seed = samples, train, seed
        self.epoch = 0

    def __len__(self):
        return len(self.samples)

    def __getitem__(self, i: int):
        import cv2
        torch, _ = torch_modules()
        s = self.samples[i]
        img = cv2.imread(str(s.image), cv2.IMREAD_COLOR)
        if img is None:
            raise RuntimeError(f"{s.image}: cannot be read")
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        corners = s.corners if s.corners is not None else (rect_corners(s.box) if s.box is not None else None)
        known = s.corners is not None
        size = torch.tensor(img.shape[1::-1])   # (w, h) of the frame as read
        if self.train:
            rng = random.Random(f"{self.seed}/{self.epoch}/{i}")
            img, corners = augment(img, corners, rng)
        h, w = img.shape[:2]
        canvas, _ = letterbox_image(img)
        target = np.zeros(10, dtype=np.float32)
        if corners is not None:
            target[0] = 1.0
            target[1:9] = flat(letterbox_corners(corners, w, h))
            target[9] = 1.0 if known else 0.0
        x = torch.from_numpy(np.ascontiguousarray(canvas.transpose(2, 0, 1))).float() / 255.0
        return x, torch.from_numpy(target), i, size


def augment(img: np.ndarray, corners: Optional[tuple], rng: random.Random) -> tuple[np.ndarray, Optional[tuple]]:
    h, w = img.shape[:2]
    if rng.random() < 0.5:
        img = img[:, ::-1]
        if corners is not None:
            # Mirrored: the left corners become the right ones and vice versa.
            tl, tr, br, bl = ((1 - x, y) for x, y in corners)
            corners = (tr, tl, bl, br)
    # A crop of 80–100% that keeps the whole net (no crop when it doesn't fit).
    frac = rng.uniform(0.8, 1.0)
    cw, ch = int(w * frac), int(h * frac)
    if cw < w or ch < h:
        if corners is None:
            x0, y0 = rng.randint(0, w - cw), rng.randint(0, h - ch)
        else:
            # The crop starts no later than the net's left edge and ends no earlier than its
            # right one (whole pixels, rounded outwards), so every corner stays inside it.
            l, t, r, b = edges(corners_box(corners))
            lo_x, hi_x = max(0, int(np.ceil(r * w)) - cw), min(w - cw, int(np.floor(l * w)))
            lo_y, hi_y = max(0, int(np.ceil(b * h)) - ch), min(h - ch, int(np.floor(t * h)))
            if lo_x > hi_x or lo_y > hi_y:
                cw, ch, x0, y0 = w, h, 0, 0
            else:
                x0, y0 = rng.randint(lo_x, hi_x), rng.randint(lo_y, hi_y)
        if (cw, ch) != (w, h):
            img = img[y0:y0 + ch, x0:x0 + cw]
            if corners is not None:
                corners = tuple(((x * w - x0) / cw, (y * h - y0) / ch) for x, y in corners)
    img = np.ascontiguousarray(img).astype(np.float32)
    img = (img - 128) * rng.uniform(0.8, 1.2) + 128 + rng.uniform(-30, 30)
    if rng.random() < 0.3:
        img += np.random.default_rng(rng.getrandbits(32)).normal(0, 4, img.shape).astype(np.float32)
    return np.clip(img, 0, 255).astype(np.uint8), corners


def box_of(corners):
    """Edges (left, top, right, bottom) of the box that spans a [N, 4, 2] tensor of corners."""
    xs, ys = corners[..., 0], corners[..., 1]
    return xs.min(dim=1).values, ys.min(dim=1).values, xs.max(dim=1).values, ys.max(dim=1).values


def loss_fn(logits, target):
    """Presence: BCE on every frame. On frames with a net: L1 on the four corners where
    they are known (our labels; the top corners' y counted twice, the tape being what
    the above-net gate reads), and on every frame with a net the box the predicted
    corners span against the label's box — its top edge twice, the two sides once —
    which is all an extra image's box can teach."""
    torch, nn = torch_modules()
    presence = nn.functional.binary_cross_entropy_with_logits(logits[:, 0], target[:, 0])
    has = target[:, 0] > 0.5
    if not has.any():
        return presence, presence.detach(), torch.zeros((), device=logits.device)
    p = torch.sigmoid(logits[has, 1:9]).view(-1, 4, 2)
    t = target[has, 1:9].view(-1, 4, 2)
    known = target[has, 9] > 0.5
    corner = torch.zeros((), device=logits.device)
    if known.any():
        pk, tk = p[known], t[known]
        corner = (pk - tk).abs().mean() + (pk[:, :2, 1] - tk[:, :2, 1]).abs().mean()
    pl, pt, pr, pb = box_of(p)
    tl, tt, tr, tb = box_of(t)
    box = ((pl - tl).abs() + 2 * (pt - tt).abs() + (pr - tr).abs() + (pb - tb).abs()).mean()
    total = presence + 5 * (corner + box)
    return total, presence.detach(), (corner + box).detach()


def evaluate(model, samples: list[Sample], device, batch: int, workers: int) -> dict:
    """Score `samples` with `model`; the rows carry each frame's prediction so a
    `--score-only` run can be compared frame by frame with another."""
    torch, _ = torch_modules()
    loader = torch.utils.data.DataLoader(Frames(samples, False, 0), batch_size=batch, shuffle=False, num_workers=workers)
    rows: list[dict] = []
    model.eval()
    with torch.no_grad():
        for x, target, idx, size in loader:
            out = torch.sigmoid(model(x.to(device))).cpu().numpy()
            for o, t, i, (w, h) in zip(out, target.numpy(), idx.numpy(), size.numpy().tolist()):
                s = samples[int(i)]
                rows.append({"video": s.video, "group": s.group, "surface": s.surface, "has_net": bool(t[0] > 0.5),
                             "presence": float(o[0]), "pred": unflat(o[1:9]),
                             "truth": unflat(t[1:9]) if t[0] > 0.5 else None, "w": w, "h": h})
    m = summarize(rows)

    def tape(r: dict) -> list[float]:
        back = letterbox_corners_back(r["pred"], r["w"], r["h"])
        return [round(back[0][1], 4), round(back[1][1], 4)]

    m["per_frame"] = [{"video": r["video"], "presence": round(r["presence"], 4), "top": tape(r)} for r in rows]
    return m


def git_sha() -> Optional[str]:
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=HERE, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return None


def export_onnx(model, path: Path) -> None:
    torch, _ = torch_modules()
    _, Deploy = build_model()
    deploy = Deploy(model).cpu().eval()
    import inspect
    legacy = {"dynamo": False} if "dynamo" in inspect.signature(torch.onnx.export).parameters else {}
    torch.onnx.export(deploy, (torch.zeros(1, 3, HEIGHT, WIDTH),), str(path), opset_version=17,
                      input_names=["frame"], output_names=["net"], dynamic_axes={"frame": {0: "B"}, "net": {0: "B"}},
                      do_constant_folding=True, **legacy)


# ---------------------------------------------------------------------------


def main(argv: Optional[list[str]] = None) -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("dataset", type=Path, help="A RallyLab --export-net-dataset folder")
    p.add_argument("--manifest", type=Path, required=True, help="The project's manifests/manifest.json (identity, splits, groups)")
    p.add_argument("--extra", type=Path, action="append", default=[], help="A YOLO-format folder with provenance.json (train only)")
    p.add_argument("--epochs", type=int, default=40)
    p.add_argument("--batch", type=int, default=32)
    p.add_argument("--lr", type=float, default=2e-3)
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--val-fraction", type=float, default=0.25)
    p.add_argument("--split", type=Path, default=None, help="A split.json from another run: validate on the same groups")
    p.add_argument("--seed", type=int, default=0, help="Fixes the split (without --split), the initialisation and the augmentation")
    p.add_argument("--name", default="net_v1")
    p.add_argument("--score-only", type=Path, default=None, metavar="WEIGHTS", help="Score this checkpoint on the val frames and stop")
    p.add_argument("--runs", type=Path, default=HERE / "runs" / "net", help=argparse.SUPPRESS)
    p.add_argument("--bring-back", type=Path, default=HERE / "bring_back", help=argparse.SUPPRESS)
    args = p.parse_args(argv)

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch, _ = torch_modules()
    torch.manual_seed(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if device.type != "cuda" and not args.score_only:
        say("⚠️  No CUDA GPU found — training on the CPU (fine for a test, slow for a run).")
    if not args.score_only:
        try:
            import onnx  # noqa: F401  (the export at the end needs it; better to know now than after the last epoch)
        except ImportError:
            fail("Missing onnx. In the .venv: pip install onnx")

    if not args.manifest.exists():
        fail(f"{args.manifest}: no such manifest")
    manifest, rows = load_manifest(args.manifest)
    samples, export_info = read_rallylab_export(args.dataset, rows)
    group_samples(samples, args.manifest)
    extras_info = []
    for folder in args.extra:
        extra, info = read_extra_folder(folder)
        samples += extra
        extras_info.append(info)
        say(f"{info['images']} extra images from {folder.name} ({info['no_net_images']} without a net; "
            f"source: {info['provenance']['source']}, licence: {info['provenance']['license']})")
    ours = [s for s in samples if s.source == "rallylab"]
    say(f"{len(ours)} labeled frames from {len({s.group for s in ours})} recording groups "
        f"({', '.join(f'{k} {v}' for k, v in sorted(Counter(s.surface for s in ours).items()))})")

    val_groups = None
    if args.split:
        val_groups = set(json.loads(args.split.read_text())["val_groups"])
    train_s, val_s, val_groups_list = split_by_group(samples, args.val_fraction, random.Random(args.seed), val_groups)
    if not val_s:
        fail("No validation frames: the dataset has fewer than two recording groups on every surface")
    say(f"{len(train_s)} train · {len(val_s)} val frames; val groups: {len(val_groups_list)} "
        f"({', '.join(f'{k} {v}' for k, v in sorted(Counter(s.surface for s in val_s).items()))})")
    val_digest = dataset_digest(val_s)
    say(f"val frames digest {val_digest[:16]}… (frame bytes and boxes; two runs compare only when it is equal)")

    run = args.runs / args.name
    if run.exists():
        fail(f"{run} exists — pass a new --name (or delete it).")
    run.mkdir(parents=True)
    (run / "split.json").write_text(json.dumps({"val_groups": val_groups_list, "val_videos": sorted({s.video for s in val_s}),
                                                "val_fraction": args.val_fraction, "seed": args.seed,
                                                "from": str(args.split) if args.split else None}, indent=2))
    metrics = {"trainer": "train_net_model.py", "code_sha": git_sha(), "torch": torch.__version__, "input": [WIDTH, HEIGHT],
               "dataset": export_info, "extras": extras_info, "manifest_sha256": sha256_file(args.manifest),
               "manifest_createdAt": manifest.get("createdAt"), "seed": args.seed, "epochs": args.epochs, "batch": args.batch,
               "lr": args.lr, "train_frames": len(train_s), "train_digest": dataset_digest(train_s), "val_frames": len(val_s),
               "val_digest": val_digest, "val_groups": val_groups_list, "best": None, "best_epoch": None}

    NetBoxNet, _ = build_model()
    model = NetBoxNet().to(device)

    def finish(back_files: list[str]) -> None:
        (run / "metrics.json").write_text(json.dumps(metrics, indent=2))
        back = args.bring_back / args.name
        back.mkdir(parents=True, exist_ok=True)
        for name in back_files:
            shutil.copy(run / name, back / name)
        say(f"\n✅ Done. Copy {back} back to the Mac.")

    if args.score_only:
        saved = torch.load(args.score_only, map_location=device)
        model.load_state_dict(saved["state_dict"])
        metrics["scored"] = evaluate(model, val_s, device, args.batch, args.workers)
        metrics["scored_weights"] = {"path": str(args.score_only), "epoch": saved.get("epoch"), "sha256": sha256_file(args.score_only)}
        say(f"{args.score_only} on the val frames: {describe(metrics['scored'])}")
        finish(["metrics.json", "split.json"])
        return

    g = torch.Generator()
    g.manual_seed(args.seed)
    train_frames = Frames(train_s, True, args.seed)
    # Not persistent: each epoch's workers are started with the dataset as it is then (its epoch set below).
    loader = torch.utils.data.DataLoader(train_frames, batch_size=args.batch, shuffle=True, num_workers=args.workers,
                                         drop_last=len(train_s) > args.batch, generator=g, persistent_workers=False)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.OneCycleLR(optimizer, max_lr=args.lr, total_steps=max(1, args.epochs * len(loader)))
    best_key = None
    log = [["epoch", "loss", "presence_loss", "box_loss", "detect_rate", "top_median", "top_mean_with_misses", "seconds"]]
    started = time.time()
    for epoch in range(1, args.epochs + 1):
        train_frames.epoch = epoch
        model.train()
        sums = np.zeros(3)
        n = 0
        for x, target, _, _ in loader:
            x, target = x.to(device), target.to(device)
            total, pres, box = loss_fn(model(x), target)
            optimizer.zero_grad(set_to_none=True)
            total.backward()
            optimizer.step()
            scheduler.step()
            sums += (float(total), float(pres), float(box))
            n += 1
        m = evaluate(model, val_s, device, args.batch, args.workers)
        key = m["top_error_mean_with_misses"]
        avg = sums / max(1, n)
        say(f"epoch {epoch:3d}  loss {avg[0]:.4f} (presence {avg[1]:.4f}, box {avg[2]:.4f})  val: {describe(m)}  {time.time() - started:.0f}s")
        log.append([epoch, f"{avg[0]:.5f}", f"{avg[1]:.5f}", f"{avg[2]:.5f}", m["detect_rate"], m["top_error"]["median"], key,
                    f"{time.time() - started:.0f}"])
        if best_key is None or key < best_key:
            best_key = key
            metrics["best"], metrics["best_epoch"] = m, epoch
            torch.save({"state_dict": model.state_dict(), "epoch": epoch}, run / "best.pt")
        with open(run / "log.csv", "w", newline="") as f:
            csv.writer(f).writerows(log)

    best = torch.load(run / "best.pt", map_location=device)
    model.load_state_dict(best["state_dict"])
    say(f"Best (epoch {metrics['best_epoch']}): {describe(metrics['best'])}")
    metrics["best_sha256"] = sha256_file(run / "best.pt")
    export_onnx(model, run / "best.onnx")
    metrics["onnx_sha256"] = sha256_file(run / "best.onnx")
    finish(["best.pt", "best.onnx", "metrics.json", "log.csv", "split.json"])


if __name__ == "__main__":
    main()
