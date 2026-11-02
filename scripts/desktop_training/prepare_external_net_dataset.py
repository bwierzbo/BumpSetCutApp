"""Audit an external YOLO-format net dataset and write a training-only, net-only package.

    python prepare_external_net_dataset.py build <export> <package> --config <config.json>
        [--compare NAME=DIR ...] [--manifest <split manifest.json>]
    python prepare_external_net_dataset.py verify <package>

`build` reads an untouched Roboflow YOLO export (it is never written to), takes every
image through the rules below and writes `<package>`, which must not exist yet: the
eligible images byte for byte, their net boxes as class 0 `net`, `data.yaml`,
`provenance.json` (what `train_net_model.py --extra` requires), `manifest.json` (every
source image with its status, reason, evidence and hashes), `exclusions.json` (the images
left out and why, drawn from the manifest) and `audit.json` (the inventory and the
duplicate checks). The package is written beside its destination and
moved into place only after `verify` passes on it. No wall-clock time and no machine path
is written, and files are written as bytes, so a second build from the same inputs produces
identical files on any machine.

Rules, each recorded per image in the manifest:
- Every image belongs to exactly one source group from the config (a pattern on the file
  name); an image no group claims stops the build — an unknown source is never accepted
  silently. A group the config marks `quarantined` or `excluded` contributes nothing.
- Per-image decisions from the config (an exact file name) quarantine or exclude it, with
  the reason, evidence type and confidence; a decision naming a file that is not in the
  export stops the build.
- Net labels: only axis-aligned `class cx cy w h` lines of the configured net class, inside
  the frame with a positive size. A polygon net line, a net box outside the frame, more
  than one net box, or no net box at all (negative meaning not trusted unless the config
  says so) quarantines the image. Other classes are dropped, never edited.
- Exact duplicates (same file SHA-256 or same decoded pixels) and near duplicates (the
  aligned thumbnail correlation at or above the configured threshold, which must catch
  every synthetic copy in the calibration) are clustered; the cluster keeps its first file
  by name and excludes the rest.
- `--compare` folders (other eligible training sources) are checked for exact and near
  duplicates against the export; a match excludes the export image. With `--manifest`, a
  compare image named after a withheld recording (the split manifest's withheld splits or
  reservations, closed over alias groups) stops the build before any image is opened.

Boxes are boxes: the package says so (`label_kind`), and nothing here makes corners.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import random
import re
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image

WITHHELD_SPLITS = {"lineage_holdout", "legacy_holdout", "final_test_candidate", "final_test"}
IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png")
THUMB = (96, 54)                       # grayscale thumbnail for the duplicate checks (16:9)
CROP_FRACTIONS = (0.95, 0.9, 0.85)     # crops searched for a cropped copy, each at a 3x3 grid of positions
PROVENANCE_FIELDS = ("source", "license", "obtained", "note")
STATUSES = ("eligible", "quarantined", "excluded")
SPLIT_DIRS = ("train", "valid", "test")
EDGE_TOLERANCE = 1e-6


class PrepError(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def canonical(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, indent=1, ensure_ascii=False).encode() + b"\n"


# ---------------------------------------------------------------- withheld guard

def withheld_names(manifest_path: Path) -> set[str]:
    """Every recording the split manifest withholds, closed over alias groups. An
    unreadable manifest is an error, never an empty set."""
    try:
        m = json.loads(manifest_path.read_text())
        videos = m["videos"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise PrepError(f"{manifest_path}: unreadable split manifest ({e})") from None
    seed_groups = {v["aliasGroup"] for v in videos if v.get("split") in WITHHELD_SPLITS or v.get("reservedAs")}
    names = {v["video"] for v in videos if v["aliasGroup"] in seed_groups}
    names |= {v["clipId"] for v in videos if v["aliasGroup"] in seed_groups and v.get("clipId")}
    return names


def refuse_withheld(paths: list[Path], names: set[str]) -> None:
    for p in paths:
        stem = p.stem
        for n in names:
            if stem == n or stem.startswith(n + "_") or stem.startswith(n + "."):
                raise PrepError(f"{p}: named after the withheld recording {n} — not opened; "
                                "pass a folder without withheld footage")


# ---------------------------------------------------------------- reading the export

def read_names(yaml_path: Path) -> list[str]:
    for line in yaml_path.read_text().splitlines():
        s = line.strip()
        if s.startswith("names:"):
            rest = s[len("names:"):].strip()
            if rest.startswith("["):
                return [x.strip().strip("'\"") for x in rest.strip("[]").split(",") if x.strip()]
    raise PrepError(f"{yaml_path}: no `names: [...]` line")


def read_export(root: Path) -> tuple[list[str], list[dict]]:
    yaml_path = root / "data.yaml"
    if not yaml_path.exists():
        raise PrepError(f"{root}: no data.yaml")
    names = read_names(yaml_path)
    records = []
    for split in SPLIT_DIRS:
        image_dir = root / split / "images"
        if not image_dir.is_dir():
            continue
        for image in sorted(image_dir.iterdir()):
            if image.suffix.lower() not in IMAGE_SUFFIXES:
                continue
            label = root / split / "labels" / f"{image.stem}.txt"
            records.append({"file": image.name, "split": split, "image": image,
                            "label": label if label.exists() else None})
    if not records:
        raise PrepError(f"{root}: no images under {', '.join(SPLIT_DIRS)}")
    files = [r["file"] for r in records]
    if len(set(files)) != len(files):
        dup = sorted({f for f in files if files.count(f) > 1})
        raise PrepError(f"{root}: the same file name in two splits: {dup[:5]}")
    return names, records


def parse_label(text: str) -> list[dict]:
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        parts = raw.split()
        if not parts:
            continue
        try:
            cls = int(parts[0])
            vals = [float(p) for p in parts[1:]]
        except ValueError:
            lines.append({"line": n, "class": None, "kind": "unparseable", "raw": raw})
            continue
        kind = "box" if len(vals) == 4 else ("polygon" if len(vals) >= 6 and len(vals) % 2 == 0 else "malformed")
        lines.append({"line": n, "class": cls, "kind": kind, "values": vals, "text": parts[1:]})
    return lines


def box_valid(v: list[float]) -> bool:
    cx, cy, w, h = v
    return (w > 0 and h > 0 and cx - w / 2 >= -EDGE_TOLERANCE and cx + w / 2 <= 1 + EDGE_TOLERANCE
            and cy - h / 2 >= -EDGE_TOLERANCE and cy + h / 2 <= 1 + EDGE_TOLERANCE)


# ---------------------------------------------------------------- image features

def gray_thumb(img: Image.Image) -> np.ndarray:
    a = np.asarray(img.resize(THUMB, Image.BILINEAR), dtype=np.float64).ravel()
    a = a - a.mean()
    n = np.linalg.norm(a)
    return a / n if n > 0 else a


def crop_thumbs(img: Image.Image) -> list[np.ndarray]:
    """The full frame, then centred-grid crops: a crop of one image matches the other's full
    frame when one is a cropped copy of the other."""
    w, h = img.size
    out = [gray_thumb(img)]
    for f in CROP_FRACTIONS:
        cw, ch = round(w * f), round(h * f)
        for fy in (0.0, 0.5, 1.0):
            for fx in (0.0, 0.5, 1.0):
                x0, y0 = round((w - cw) * fx), round((h - ch) * fy)
                out.append(gray_thumb(img.crop((x0, y0, x0 + cw, y0 + ch))))
    return out


def image_features(path: Path) -> dict:
    with Image.open(path) as im:
        im.load()
        fmt = im.format
        rgb = im.convert("RGB")
    gray = rgb.convert("L")
    return {"width": rgb.size[0], "height": rgb.size[1], "format": fmt,
            "pixel_sha256": sha256_bytes(rgb.tobytes()), "thumbs": np.stack(crop_thumbs(gray))}


def compare_thumbs(path: Path) -> np.ndarray:
    try:
        with Image.open(path) as im:
            gray = im.convert("RGB").convert("L")
    except Exception as e:  # noqa: BLE001 — any decoder error
        raise PrepError(f"{path}: cannot be decoded ({e})") from None
    return np.stack(crop_thumbs(gray))


def aligned_similarity(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """a: (n, k, d), b: (m, k, d) crop thumbnails → (n, m): the best correlation between one
    image's full frame and any crop of the other, in either direction."""
    n, k, d = a.shape
    m = b.shape[0]
    ab = (a[:, 0, :] @ b.reshape(m * k, d).T).reshape(n, m, k).max(-1)      # a's full frame vs b's crops (b ⊃ a)
    ba = (b[:, 0, :] @ a.reshape(n * k, d).T).reshape(m, n, k).max(-1).T    # b's full frame vs a's crops (a ⊃ b)
    return np.maximum(ab, ba)


def calibrate(paths: list[Path], count: int, seed: int) -> dict:
    """Synthetic copies of a seeded sample: re-encoded, resized, cropped, shifted, brightened.
    Returns the lowest aligned similarity of each copy kind to its original."""
    def jpeg(im, q):
        b = io.BytesIO()
        im.save(b, "JPEG", quality=q)
        return Image.open(io.BytesIO(b.getvalue()))
    kinds = {
        "jpeg_q30": lambda im: jpeg(im, 30),
        "resize_half": lambda im: im.resize((im.width // 2, im.height // 2)),
        "resize_quarter_up": lambda im: im.resize((im.width // 4, im.height // 4)).resize(im.size),
        "crop_5pct": lambda im: im.crop((round(im.width * .05), round(im.height * .05), im.width, im.height)),
        "crop_10pct_centre": lambda im: im.crop((round(im.width * .05), round(im.height * .05),
                                                 round(im.width * .95), round(im.height * .95))),
        "shift_0.5pct": lambda im: im.crop((round(im.width * .005), 0, im.width, im.height)),
        "brighten_10pct": lambda im: Image.eval(im, lambda v: min(255, int(v * 1.1))),
    }
    rng = random.Random(seed)
    sample = rng.sample(sorted(paths), min(count, len(paths)))
    worst = {k: 1.0 for k in kinds}
    for p in sample:
        with Image.open(p) as im:
            g = im.convert("RGB").convert("L")
        base = np.stack(crop_thumbs(g))[None]
        for k, fn in kinds.items():
            copy = np.stack(crop_thumbs(fn(g).convert("L")))[None]
            worst[k] = min(worst[k], float(aligned_similarity(base, copy)[0, 0]))
    return {"sample": [p.name for p in sample], "seed": seed, "min_similarity_by_copy_kind":
            {k: round(v, 5) for k, v in worst.items()}}


# ---------------------------------------------------------------- clustering

def clusters(pairs: list[tuple[int, int]], n: int) -> list[list[int]]:
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for a, b in pairs:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)
    groups: dict[int, list[int]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    return [sorted(g) for g in groups.values() if len(g) > 1]


# ---------------------------------------------------------------- the build

def load_config(path: Path) -> dict:
    cfg = json.loads(path.read_text())
    for key in ("dataset_id", "net_class", "groups", "near_duplicate", "provenance", "source"):
        if key not in cfg:
            raise PrepError(f"{path}: missing `{key}`")
    missing = [f for f in PROVENANCE_FIELDS if not str(cfg["provenance"].get(f, "")).strip()]
    if missing:
        raise PrepError(f"{path}: provenance missing {missing}")
    for g in cfg["groups"]:
        if g.get("status", "eligible") not in STATUSES:
            raise PrepError(f"{path}: group {g.get('id')}: status must be one of {STATUSES}")
        missing = [k for k in ("id", "match", "evidence_type", "confidence") +
                   (("reason",) if g.get("status", "eligible") != "eligible" else ()) if not g.get(k)]
        if missing:
            raise PrepError(f"{path}: group {g.get('id')}: missing {missing}")
    for d in cfg.get("decisions", []):
        if d.get("status") not in ("quarantined", "excluded"):
            raise PrepError(f"{path}: decision for {d.get('file')}: status must be quarantined or excluded")
        missing = [k for k in ("file", "reason", "evidence_type", "confidence") if not d.get(k)]
        if missing:
            raise PrepError(f"{path}: decision for {d.get('file')}: missing {missing}")
    return cfg


def audit_and_decide(export: Path, cfg: dict, compare: dict[str, Path], manifest: Path | None) -> tuple[list[dict], dict]:
    names, records = read_export(export)
    if cfg["net_class"] not in names:
        raise PrepError(f"{export}/data.yaml: no class `{cfg['net_class']}` in {names}")
    net_id = names.index(cfg["net_class"])

    # Compare folders: the withheld guard runs before any of their images is opened.
    compare_paths: dict[str, list[Path]] = {}
    for name, folder in compare.items():
        ps = sorted(p for p in folder.rglob("*") if p.suffix.lower() in IMAGE_SUFFIXES)
        if not ps:
            raise PrepError(f"--compare {name}={folder}: no images")
        compare_paths[name] = ps
    if compare and manifest is None:
        raise PrepError("--compare needs --manifest, so no withheld recording's frame is opened")
    if manifest is not None:
        held = withheld_names(manifest)
        for ps in compare_paths.values():
            refuse_withheld(ps, held)

    # Groups and per-image decisions.
    groups = cfg["groups"]
    for r in records:
        hits = [g for g in groups if re.search(g["match"], r["file"])]
        if len(hits) != 1:
            raise PrepError(f"{r['file']}: matched by {len(hits)} source groups ({[g['id'] for g in hits]}); "
                            "every image needs exactly one — an unknown source is not accepted silently")
        r["group"] = hits[0]
    by_file = {r["file"]: r for r in records}
    for d in cfg.get("decisions", []):
        if d["file"] not in by_file:
            raise PrepError(f"decision for {d['file']}: no such image in the export")
        by_file[d["file"]]["decision"] = d

    # Labels.
    class_counts = {n: 0 for n in names}
    kinds_by_class: dict[str, dict[str, int]] = {n: {} for n in names}
    for r in records:
        r["label_sha256"] = sha256_file(r["label"]) if r["label"] else None
        lines = parse_label(r["label"].read_text()) if r["label"] else []
        r["lines"] = lines
        for ln in lines:
            cname = names[ln["class"]] if ln["class"] is not None and 0 <= ln["class"] < len(names) else f"?{ln['class']}"
            class_counts[cname] = class_counts.get(cname, 0) + 1
            kinds_by_class.setdefault(cname, {})
            kinds_by_class[cname][ln["kind"]] = kinds_by_class[cname].get(ln["kind"], 0) + 1
        r["net_lines"] = [ln for ln in lines if ln["class"] == net_id]
        r["bad_lines"] = [ln for ln in lines if ln["class"] is None or not 0 <= ln["class"] < len(names)
                          or ln["kind"] in ("unparseable", "malformed")]

    # Images: decodability, size, hashes, thumbnails.
    for r in records:
        try:
            f = image_features(r["image"])
        except Exception as e:  # noqa: BLE001 — any decoder error makes the image unusable
            raise PrepError(f"{r['image']}: cannot be decoded ({e})") from None
        r.update(f, file_sha256=sha256_file(r["image"]))

    # Exact and near duplicates within the export.
    n = len(records)
    thr = float(cfg["near_duplicate"]["threshold"])
    cal = calibrate([r["image"] for r in records], int(cfg["near_duplicate"].get("calibration_images", 20)),
                    int(cfg["near_duplicate"].get("calibration_seed", 0)))
    missed = {k: v for k, v in cal["min_similarity_by_copy_kind"].items() if v < thr}
    if missed:
        raise PrepError(f"near-duplicate threshold {thr} misses synthetic copies {missed} — lower it")
    exact_pairs = []
    for key in ("file_sha256", "pixel_sha256"):
        seen: dict[str, int] = {}
        for i, r in enumerate(records):
            if r[key] in seen:
                exact_pairs.append((seen[r[key]], i))
            else:
                seen[r[key]] = i
    T = np.stack([r["thumbs"] for r in records])
    sim = aligned_similarity(T, T)
    np.fill_diagonal(sim, -1)
    near_pairs = [(int(i), int(j)) for i, j in zip(*np.nonzero(np.triu(sim >= thr, 1)))]
    nn = sim.max(1)
    exact_clusters = clusters(exact_pairs, n)
    near_clusters = clusters(exact_pairs + near_pairs, n)

    # Cross-source duplicates.
    cross = {}
    for name, ps in compare_paths.items():
        C = np.stack([compare_thumbs(p) for p in ps])
        csha = {sha256_file(p): p for p in ps}
        s = aligned_similarity(T, C)
        best = s.argmax(1)
        matches = []
        for i, r in enumerate(records):
            exact = r["file_sha256"] in csha
            if exact or s[i, best[i]] >= thr:
                r.setdefault("cross_matches", []).append({"source": name, "file": ps[best[i]].name,
                                                          "similarity": round(float(s[i, best[i]]), 5), "exact": exact})
                matches.append(r["file"])
        top = np.argsort(-s.max(1))[:5]
        cross[name] = {"folder": compare[name].name, "images": len(ps), "matches": matches,
                       "max_similarity": round(float(s.max()), 5),
                       "median_best_similarity": round(float(np.median(s.max(1))), 5),
                       "closest": [{"export": records[i]["file"], "other": ps[best[i]].name,
                                    "similarity": round(float(s[i, best[i]]), 5)} for i in top]}

    # Status per image, in a fixed order of precedence.
    rank = {r["file"]: i for i, r in enumerate(sorted(records, key=lambda r: r["file"]))}
    in_cluster = {i: c for c in near_clusters for i in c}
    for i, r in enumerate(records):
        g, d = r["group"], r.get("decision")
        def set_(status, reason, evidence, confidence):
            r["status"], r["reason"], r["evidence_type"], r["confidence"] = status, reason, evidence, confidence
        if g.get("status", "eligible") != "eligible":
            set_(g["status"], g["reason"], g["evidence_type"], g["confidence"])
        elif d:
            set_(d["status"], d["reason"], d["evidence_type"], d["confidence"])
        elif r["bad_lines"]:
            set_("quarantined", f"unparseable or malformed label lines {[ln['line'] for ln in r['bad_lines']]}",
                 "label_check", "certain")
        elif not r["net_lines"] and not cfg.get("negatives_trusted", False):
            set_("quarantined", "no net annotation; whether the image truly has no net is not established",
                 "label_check", "certain")
        elif any(ln["kind"] != "box" for ln in r["net_lines"]):
            set_("quarantined", "net annotation is not an axis-aligned box", "label_check", "certain")
        elif any(not box_valid(ln["values"]) for ln in r["net_lines"]):
            set_("quarantined", "net box outside the frame or empty", "label_check", "certain")
        elif len(r["net_lines"]) > 1:
            set_("quarantined", f"{len(r['net_lines'])} net boxes; which one is the net is not established",
                 "label_check", "certain")
        elif r.get("cross_matches"):
            m = r["cross_matches"][0]
            set_("excluded", f"duplicate of {m['source']}/{m['file']} (similarity {m['similarity']})",
                 "exact_hash" if m["exact"] else "near_duplicate", "certain" if m["exact"] else "high")
        else:
            set_("eligible", "", "", "")
    # Duplicates last: a cluster keeps its largest still-eligible member (an original over a
    # downsized copy), the first by name among equals.
    for c in near_clusters:
        members = sorted(c, key=lambda i: (-records[i]["width"] * records[i]["height"], rank[records[i]["file"]]))
        keep = next((i for i in members if records[i]["status"] == "eligible"), None)
        if keep is None:
            continue
        exact_c = any(set(c) <= set(e) for e in exact_clusters)
        for i in members:
            if i != keep and records[i]["status"] == "eligible":
                r = records[i]
                r["status"] = "excluded"
                r["reason"] = f"duplicate of {records[keep]['file']}"
                r["evidence_type"] = "exact_hash" if exact_c else "near_duplicate"
                r["confidence"] = "certain" if exact_c else "high"

    nets = np.array([ln["values"] for r in records for ln in r["net_lines"] if ln["kind"] == "box"]) \
        if any(ln["kind"] == "box" for r in records for ln in r["net_lines"]) else np.zeros((0, 4))
    eligible = [r for r in records if r["status"] == "eligible"]
    audit = {
        "dataset_id": cfg["dataset_id"], "export": export.name, "classes": names, "net_class": cfg["net_class"],
        "net_class_id": net_id,
        "images": n, "by_split": {s: sum(r["split"] == s for r in records) for s in SPLIT_DIRS},
        "annotations_by_class": class_counts, "annotation_kinds_by_class": kinds_by_class,
        "images_with_a_net": sum(bool(r["net_lines"]) for r in records),
        "images_without_a_net": sum(not r["net_lines"] for r in records),
        "images_with_more_than_one_net": sum(len(r["net_lines"]) > 1 for r in records),
        "net_annotations": sum(len(r["net_lines"]) for r in records),
        "label_files_missing": sum(r["label"] is None for r in records),
        "malformed_label_lines": sum(len(r["bad_lines"]) for r in records),
        "net_boxes_outside_frame": int(sum(not box_valid(v) for v in nets)),
        "dimensions": _count([f"{r['width']}x{r['height']}" for r in records]),
        "formats": _count([r["format"] for r in records]),
        "net_box_stats": {k: {"min": round(float(nets[:, i].min()), 4), "median": round(float(np.median(nets[:, i])), 4),
                              "max": round(float(nets[:, i].max()), 4)} for i, k in enumerate(("cx", "cy", "w", "h"))}
        if len(nets) else {},
        "augmentation": cfg["source"].get("augmentation", "unknown"),
        "exact_duplicate_clusters": [[records[i]["file"] for i in c] for c in exact_clusters],
        "near_duplicate": {
            "method": f"z-normalised {THUMB[0]}x{THUMB[1]} grayscale thumbnails; similarity = best correlation of one "
                      f"image's full frame with the other's full frame or any of its crops {list(CROP_FRACTIONS)} on a "
                      "3x3 grid of positions, in either direction",
            "threshold": thr, "calibration": cal,
            "clusters": len(near_clusters), "images_in_clusters": sum(len(c) for c in near_clusters),
            "largest_cluster": max((len(c) for c in near_clusters), default=0),
            "nearest_neighbour_similarity": {"min": round(float(nn.min()), 5), "median": round(float(np.median(nn)), 5),
                                             "p95": round(float(np.percentile(nn, 95)), 5), "max": round(float(nn.max()), 5)},
        },
        "cross_source": cross,
        "status_counts": _count([r["status"] for r in records]),
        "by_group": {g["id"]: _count([r["status"] for r in records if r["group"] is g]) for g in groups},
        "eligible_images": len(eligible),
        "eligible_net_annotations": sum(len(r["net_lines"]) for r in eligible),
    }
    return records, audit


def _count(items) -> dict:
    out: dict = {}
    for x in items:
        out[x] = out.get(x, 0) + 1
    return dict(sorted(out.items()))


def write_package(out: Path, export: Path, cfg: dict, records: list[dict], audit: dict, config_path: Path) -> None:
    out = out.resolve()
    if out.exists():
        raise PrepError(f"{out}: already exists — a package is never overwritten")
    tmp = out.parent / f".{out.name}.partial"
    if tmp.exists():
        shutil.rmtree(tmp)
    (tmp / "images").mkdir(parents=True)
    (tmp / "labels").mkdir()
    entries = []
    for r in sorted(records, key=lambda r: r["file"]):
        e = {"file": r["file"], "source_split": r["split"], "group": r["group"]["id"], "status": r["status"],
             "reason": r["reason"], "evidence_type": r["evidence_type"], "confidence": r["confidence"],
             "width": r["width"], "height": r["height"], "source_image_sha256": r["file_sha256"],
             "source_label_sha256": r["label_sha256"], "net_boxes": len(r["net_lines"])}
        if r.get("cross_matches"):
            e["cross_matches"] = r["cross_matches"]
        d = r.get("decision")
        if d and d.get("proposed_correction"):
            e["proposed_correction"] = d["proposed_correction"]
        if r["status"] == "eligible":
            shutil.copyfile(r["image"], tmp / "images" / r["file"])
            stem = Path(r["file"]).stem
            data = "".join("0 " + " ".join(ln["text"]) + "\n" for ln in r["net_lines"]).encode()
            (tmp / "labels" / f"{stem}.txt").write_bytes(data)   # bytes: no CRLF on Windows, so the hash holds
            e["package_image"] = f"images/{r['file']}"
            e["package_image_sha256"] = sha256_file(tmp / "images" / r["file"])
            e["package_label"] = f"labels/{stem}.txt"
            e["package_label_sha256"] = sha256_bytes(data)
        entries.append(e)
    (tmp / "data.yaml").write_bytes(b"train: images\nnc: 1\nnames: ['net']\n")
    prov = dict(cfg["provenance"])
    (tmp / "provenance.json").write_bytes(canonical(prov))
    manifest = {
        "dataset_id": cfg["dataset_id"], "schema": 1, "tool": "scripts/desktop_training/prepare_external_net_dataset.py",
        "tool_sha256": sha256_file(Path(__file__)), "config_sha256": sha256_file(config_path), "source": cfg["source"],
        "groups": [{k: v for k, v in g.items()} for g in cfg["groups"]],
        "use": "training only: never validation, model selection, hyper-parameter choice or a test",
        "label_kind": "axis-aligned net box (YOLO cx cy w h, frame fractions, y down); NOT four corners",
        "label_semantics": cfg.get("label_semantics", ""),
        "class_mapping": {"source_class": cfg["net_class"], "source_class_id": audit["net_class_id"],
                          "package_class": "net", "package_class_id": 0, "other_classes": "dropped"},
        "near_duplicate_threshold": audit["near_duplicate"]["threshold"],
        "counts": {"source_images": audit["images"], **audit["status_counts"],
                   "eligible_net_annotations": audit["eligible_net_annotations"]},
        "files": {"data.yaml": sha256_file(tmp / "data.yaml"), "provenance.json": sha256_file(tmp / "provenance.json")},
        "entries": entries,
    }
    manifest["digest"] = sha256_bytes(canonical(manifest))
    (tmp / "manifest.json").write_bytes(canonical(manifest))
    (tmp / "exclusions.json").write_bytes(canonical(exclusions(manifest)))
    (tmp / "audit.json").write_bytes(canonical(audit))
    problems = verify(tmp)
    if problems:
        shutil.rmtree(tmp)
        raise PrepError("the package failed verification:\n  " + "\n  ".join(problems[:20]))
    tmp.rename(out)


def exclusions(manifest: dict) -> dict:
    """Every image the package leaves out, with why: the record that travels with the repo."""
    keys = ("file", "group", "status", "reason", "evidence_type", "confidence", "source_split",
            "source_image_sha256", "source_label_sha256", "cross_matches", "proposed_correction")
    groups = {g["id"]: g for g in manifest["groups"]}
    return {"dataset_id": manifest["dataset_id"], "package_manifest_digest": manifest["digest"],
            "counts": manifest["counts"],
            "excluded_groups": [{k: groups[i].get(k) for k in ("id", "status", "event", "reason", "evidence_type",
                                                              "evidence", "confidence")}
                                for i in sorted(groups) if groups[i].get("status", "eligible") != "eligible"],
            "entries": [{k: e[k] for k in keys if k in e} for e in manifest["entries"] if e["status"] != "eligible"]}


# ---------------------------------------------------------------- verification

def verify(pkg: Path) -> list[str]:
    """Everything the manifest claims, checked against the files. Returns the problems."""
    problems: list[str] = []
    try:
        manifest = json.loads((pkg / "manifest.json").read_text())
    except (OSError, ValueError) as e:
        return [f"manifest.json unreadable: {e}"]
    claimed = manifest.pop("digest", None)
    if claimed != sha256_bytes(canonical(manifest)):
        problems.append("manifest digest does not match its contents")
    manifest["digest"] = claimed
    try:
        if (pkg / "exclusions.json").read_bytes() != canonical(exclusions(manifest)):
            problems.append("exclusions.json does not match the manifest")
    except (OSError, KeyError) as e:
        problems.append(f"exclusions.json unreadable: {e}")
    manifest.pop("digest")
    for name, h in manifest.get("files", {}).items():
        if not (pkg / name).exists() or sha256_file(pkg / name) != h:
            problems.append(f"{name}: missing or changed")
    try:
        names = read_names(pkg / "data.yaml")
        if names != ["net"]:
            problems.append(f"data.yaml names {names}, expected ['net']")
    except (OSError, PrepError) as e:
        problems.append(str(e))
    try:
        prov = json.loads((pkg / "provenance.json").read_text())
        missing = [f for f in PROVENANCE_FIELDS if not str(prov.get(f, "")).strip()]
        if missing:
            problems.append(f"provenance.json missing {missing}")
    except (OSError, ValueError) as e:
        problems.append(f"provenance.json unreadable: {e}")
    listed_images, listed_labels = set(), set()
    for e in manifest.get("entries", []):
        if e["status"] not in STATUSES:
            problems.append(f"{e['file']}: unknown status {e['status']}")
        if e["status"] != "eligible":
            if "package_image" in e:
                problems.append(f"{e['file']}: {e['status']} but packaged")
            continue
        img, lab = pkg / e["package_image"], pkg / e["package_label"]
        listed_images.add(img.name)
        listed_labels.add(lab.name)
        if not img.exists() or sha256_file(img) != e["package_image_sha256"]:
            problems.append(f"{e['package_image']}: missing or changed")
            continue
        if e["package_image_sha256"] != e["source_image_sha256"]:
            problems.append(f"{e['package_image']}: not the source file")
        try:
            with Image.open(img) as im:
                im.load()
                if im.size != (e["width"], e["height"]):
                    problems.append(f"{e['package_image']}: {im.size}, manifest says {e['width']}x{e['height']}")
        except Exception as ex:  # noqa: BLE001
            problems.append(f"{e['package_image']}: cannot be decoded ({ex})")
        if not lab.exists() or sha256_file(lab) != e["package_label_sha256"]:
            problems.append(f"{e['package_label']}: missing or changed")
            continue
        lines = parse_label(lab.read_text())
        if not lines:
            problems.append(f"{e['package_label']}: no net box")
        for ln in lines:
            if ln["class"] != 0 or ln["kind"] != "box" or not box_valid(ln["values"]):
                problems.append(f"{e['package_label']} line {ln['line']}: not a valid class-0 box inside the frame")
    on_disk_images = {p.name for p in (pkg / "images").iterdir()} if (pkg / "images").is_dir() else set()
    on_disk_labels = {p.name for p in (pkg / "labels").iterdir()} if (pkg / "labels").is_dir() else set()
    for extra in sorted(on_disk_images - listed_images):
        problems.append(f"images/{extra}: not in the manifest")
    for extra in sorted(on_disk_labels - listed_labels):
        problems.append(f"labels/{extra}: not in the manifest")
    eligible_groups = {g["id"] for g in manifest.get("groups", []) if g.get("status", "eligible") == "eligible"}
    for e in manifest.get("entries", []):
        if e["status"] == "eligible" and e["group"] not in eligible_groups:
            problems.append(f"{e['file']}: eligible but its group {e['group']} is not")
    return problems


# ---------------------------------------------------------------- CLI

def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("export", type=Path)
    b.add_argument("package", type=Path)
    b.add_argument("--config", type=Path, required=True)
    b.add_argument("--compare", action="append", default=[], metavar="NAME=DIR")
    b.add_argument("--manifest", type=Path, help="split manifest: compare images named after withheld recordings stop the build")
    v = sub.add_parser("verify")
    v.add_argument("package", type=Path)
    a = p.parse_args(argv)
    try:
        if a.cmd == "verify":
            problems = verify(a.package)
            for x in problems:
                print(f"❌ {x}")
            if not problems:
                m = json.loads((a.package / "manifest.json").read_text())
                print(f"✅ {a.package}: {m['counts']}; digest {m['digest']}")
            return 1 if problems else 0
        cfg = load_config(a.config)
        compare = {}
        for item in a.compare:
            if "=" not in item:
                raise PrepError(f"--compare {item}: expected NAME=DIR")
            k, d = item.split("=", 1)
            compare[k] = Path(d)
        records, audit = audit_and_decide(a.export, cfg, compare, a.manifest)
        write_package(a.package, a.export, cfg, records, audit, a.config)
        m = json.loads((a.package / "manifest.json").read_text())
        print(f"✅ {a.package}: {m['counts']}; digest {m['digest']}")
        return 0
    except PrepError as e:
        print(f"❌ {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
