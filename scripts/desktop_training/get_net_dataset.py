#!/usr/bin/env python3
"""
Fetch a labeled net dataset from Roboflow in COCO JSON and clean it into
net_dataset/<name>/ for the from-scratch net model (EXP-20261030-net-scratch).
Nothing here uses Ultralytics: the export is COCO JSON, read with the
standard library.

Two ways in:

    # A. download (your own key, from app.roboflow.com → Settings → API Keys)
    set ROBOFLOW_API_KEY=...
    python get_net_dataset.py --workspace bumpsetcut --project <project> [--version N]

    # B. an export you downloaded yourself (Roboflow → Versions → Export → COCO → zip)
    python get_net_dataset.py --from-export <export>.zip --name <name>

With no --version it picks the cleanest version, as get_extra_datasets.py
does: not stretched into a square, no augmented copies, newest.

It keeps only the net class(es), keeps one image per original (Roboflow's
augmented copies are dropped, across splits too), un-stretches images squashed into a square back to 16:9, and
leaves out any image whose original file name contains a name listed in
--exclude (one recording name per line, e.g. the lineage and legacy holdouts
from RallyLab), so a withheld recording never reaches training. It writes:

    net_dataset/<name>/images/<split>_<original>.jpg
    net_dataset/<name>/labels.json    per image: size, split, source, nets
                                      (box as fractions [x, y, w, h], top-left
                                      origin; polygon fractions when drawn)
    net_dataset/<name>/manifest.json  where it came from, licence, counts,
                                      label kinds, and the SHA-256 of every file

Label kinds decide what the model can learn: "box" only, or "polygon" (an
outline, which gives the net's four corners). The summary says which.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import get_extra_datasets as extra  # noqa: E402  (version choice, un-stretching, copy names)

SPLITS = ("train", "valid", "test")
COCO_FILE = "_annotations.coco.json"


def is_net(name: str) -> bool:
    return "net" in name.lower()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_exclusions(path: Path | None) -> list[str]:
    if path is None:
        return []
    names = [line.strip() for line in path.read_text().splitlines()]
    return [n for n in names if n and not n.startswith("#")]


def polygon_fractions(segmentation, width: int, height: int) -> list[list[float]] | None:
    """The largest drawn outline as [[x, y], ...] fractions, or None for a box-only label."""
    if not isinstance(segmentation, list) or not segmentation:
        return None
    rings = [r for r in segmentation if isinstance(r, list) and len(r) >= 6]
    if not rings:
        return None
    ring = max(rings, key=len)
    return [[ring[i] / width, ring[i + 1] / height] for i in range(0, len(ring) - 1, 2)]


def clean(raw: Path, out: Path, unstretch: bool, exclude: list[str]) -> dict:
    from PIL import Image

    (out / "images").mkdir(parents=True, exist_ok=True)
    labels: dict[str, dict] = {}
    n = {"images": 0, "nets": 0, "no net": 0, "box only": 0, "polygon": 0,
         "excluded": 0, "copies dropped": 0, "unreadable": 0}
    classes: set[str] = set()
    excluded_sources: set[str] = set()
    seen: set[str] = set()
    found_split = False
    for split in SPLITS:
        coco_path = raw / split / COCO_FILE
        if not coco_path.exists():
            continue
        found_split = True
        coco = json.loads(coco_path.read_text())
        categories = {c["id"]: c["name"] for c in coco.get("categories", [])}
        classes.update(categories.values())
        keep = {cid for cid, name in categories.items() if is_net(name)}
        if not keep:
            extra.fail(f"No net class in {sorted(set(categories.values()))} ({split}) — check this dataset by hand.")
        by_image: dict[int, list[dict]] = {}
        for a in coco.get("annotations", []):
            if a.get("category_id") in keep:
                by_image.setdefault(a["image_id"], []).append(a)
        for image in sorted(coco.get("images", []), key=lambda i: i["file_name"]):
            stem = Path(image["file_name"]).stem
            source = image.get("extra", {}).get("name") or extra.source_of(stem)
            if any(name in source for name in exclude):
                n["excluded"] += 1
                excluded_sources.add(source)
                continue
            # One image per original, across splits too: an augmented copy is a
            # near-duplicate, and one in valid would score a frame trained on.
            if extra.source_of(stem) in seen:
                n["copies dropped"] += 1
                continue
            seen.add(extra.source_of(stem))
            src = raw / split / image["file_name"]
            name = f"{split}_{stem}.jpg"
            try:
                with Image.open(src) as im:
                    im = im.convert("RGB")
                    stretched = unstretch and im.width == im.height
                    if stretched:
                        im = im.resize((round(im.height * extra.UNSTRETCH_ASPECT), im.height), Image.BICUBIC)
                    size = (im.width, im.height)
                    im.save(out / "images" / name, quality=95)
            except Exception:
                n["unreadable"] += 1
                continue
            # COCO boxes and outlines are in the exported image's pixels; fractions
            # of that size stay right after un-stretching.
            w, h = image["width"], image["height"]
            nets = []
            for a in by_image.get(image["id"], []):
                x, y, bw, bh = a["bbox"]
                polygon = polygon_fractions(a.get("segmentation"), w, h)
                nets.append({"box": [x / w, y / h, bw / w, bh / h], "polygon": polygon})
                n["polygon" if polygon else "box only"] += 1
            labels[name] = {"split": split, "source": source, "size": list(size), "nets": nets}
            n["images"] += 1
            n["nets"] += len(nets)
            n["no net"] += 0 if nets else 1
    if not found_split:
        extra.fail(f"No {COCO_FILE} under {raw}/{{train,valid,test}} — is this a COCO JSON export?")
    (out / "labels.json").write_text(json.dumps(labels, indent=1, sort_keys=True) + "\n")
    n["classes"] = sorted(classes)
    n["excluded sources"] = sorted(excluded_sources)
    return n


def write_manifest(out: Path, origin: dict, counts: dict) -> None:
    files = sorted(p for p in out.rglob("*") if p.is_file() and p.name != "manifest.json")
    manifest = {
        "kind": "net-dataset",
        "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "origin": origin,
        "counts": counts,
        "labelKinds": ("polygon" if counts["polygon"] and not counts["box only"]
                       else "box" if counts["box only"] and not counts["polygon"]
                       else "mixed" if counts["nets"] else "none"),
        "files": {str(p.relative_to(out)): sha256(p) for p in files},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")


def unpack(export: Path, into: Path) -> Path:
    if export.is_dir():
        return export
    with zipfile.ZipFile(export) as z:
        z.extractall(into)
    return into


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--workspace", help="Roboflow workspace (download mode)")
    p.add_argument("--project", help="Roboflow project (download mode)")
    p.add_argument("--version", type=int, default=None, help="Version number; default: the cleanest")
    p.add_argument("--from-export", type=Path, default=None, metavar="ZIP_OR_FOLDER",
                   help="A COCO JSON export you downloaded yourself, instead of the API")
    p.add_argument("--name", default=None, help="Folder name under --out (default: the project)")
    p.add_argument("--licence", default="your own",
                   help='Licence to record, e.g. "your own" or "CC BY 4.0" for a Universe dataset')
    p.add_argument("--exclude", type=Path, default=None,
                   help="Recording names to leave out (one per line): the withheld holdouts")
    p.add_argument("--out", type=Path, default=HERE / "net_dataset")
    args = p.parse_args()

    exclude = read_exclusions(args.exclude)
    work = Path(tempfile.mkdtemp(prefix="net_dataset_"))
    try:
        if args.from_export is not None:
            if not args.name:
                extra.fail("--name is needed with --from-export")
            raw = unpack(args.from_export, work / "export")
            origin = {"export": args.from_export.name, "sha256": sha256(args.from_export)
                      if args.from_export.is_file() else None, "licence": args.licence}
            stretched = None
        else:
            if not (args.workspace and args.project):
                extra.fail("Give --workspace and --project, or --from-export.")
            if not os.environ.get("ROBOFLOW_API_KEY"):
                extra.fail("Set ROBOFLOW_API_KEY first (Roboflow → Settings → API Keys), then run again.")
            try:
                import roboflow
            except ImportError:
                extra.fail("pip install roboflow  (in the same .venv), then run again.")
            project = roboflow.Roboflow().workspace(args.workspace).project(args.project)
            version = project.version(args.version) if args.version else extra.pick_version(project)
            if version is None:
                extra.fail(f"{args.project} has no downloadable version.")
            stretched = extra.is_stretched_square(version)
            extra.say(f"version {version.version}: resize {extra.resize_of(version) or 'none'} · "
                      f"augmentation {'yes' if extra.has_augmentation(version) else 'no'}")
            raw = work / "download"
            version.download("coco", location=str(raw), overwrite=True)
            origin = {"workspace": args.workspace, "project": args.project,
                      "version": str(version.version), "licence": args.licence,
                      "page": f"https://app.roboflow.com/{args.workspace}/{args.project}"}
        name = args.name or args.project
        out = args.out / name
        if out.exists():
            extra.fail(f"{out} exists — delete it to fetch again.")
        # An export's preprocessing isn't known: un-stretch any square image.
        counts = clean(raw, out, unstretch=stretched is not False, exclude=exclude)
        write_manifest(out, origin, counts)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    extra.say(f"\n{counts['images']} images · {counts['nets']} nets ({counts['polygon']} outlined, "
              f"{counts['box only']} box only) · {counts['no net']} with no net"
              + (f" · {counts['copies dropped']} augmented copies dropped" if counts["copies dropped"] else "")
              + (f" · {counts['excluded']} from withheld recordings left out" if counts["excluded"] else "")
              + (f" · {counts['unreadable']} unreadable (skipped)" if counts["unreadable"] else ""))
    extra.say(f"classes in the export: {counts['classes']}")
    extra.say(f"✅ {out}  (manifest.json lists every file's SHA-256)")


if __name__ == "__main__":
    main()
