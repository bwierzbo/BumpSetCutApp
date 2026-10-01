#!/usr/bin/env python3
"""
Download your original BumpSetCut dataset and indoor volleyball datasets from
Roboflow and clean them into extra training data for train_ball_model.py.

    set ROBOFLOW_API_KEY first (your own key, from app.roboflow.com → Settings → API Keys)
    python get_extra_datasets.py

For each dataset it:
  1. picks the cleanest version: not stretched into a square, no augmented
     copies, newest — and says which one it took and why;
  2. downloads it in YOLO format, and where the version has augmented
     copies (Roboflow's "outputs per training example"), keeps one per
     original image — near-copies would swamp the rest of the data;
  3. keeps only the ball class(es), as class 0 (players etc. are dropped);
  4. un-stretches images that were squashed into a square (back to 16:9),
     so balls are round again — boxes are fractions of the image, so they
     stay right;
  5. writes extra_datasets/<name>/images + labels, and CREDITS.txt (the
     datasets are CC BY 4.0: credit the authors if you share the data).

These go into TRAINING only (train_ball_model.py --extra); your own
held-out videos stay the benchmark.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# (folder name, workspace, project, licence, page): your original dataset
# (the one ball_v2_small was trained on), then the Universe shortlist's #1–3.
DATASETS = [
    ("bumpsetcut_original", "bumpsetcut", "bumpsetcutmore", "your own",
     "https://app.roboflow.com/bumpsetcut/bumpsetcutmore"),
    ("owens_rec_gym", "owens-workspace-aiu3d", "volleyball-ball-tracking-0eo7r", "CC BY 4.0",
     "https://universe.roboflow.com/owens-workspace-aiu3d/volleyball-ball-tracking-0eo7r"),
    ("volley_rec_gym", "volley-pjhnb", "volleyball-q7cun", "CC BY 4.0",
     "https://universe.roboflow.com/volley-pjhnb/volleyball-q7cun"),
    ("wenxuan_low_angle", "wenxuans-workspace", "volleyball-7yzmq", "CC BY 4.0",
     "https://universe.roboflow.com/wenxuans-workspace/volleyball-7yzmq"),
]

UNSTRETCH_ASPECT = 16 / 9


def say(msg: str = "") -> None:
    print(msg, flush=True)


def fail(msg: str) -> None:
    say(f"\n❌ {msg}")
    sys.exit(1)


def resize_of(version) -> dict:
    pre = getattr(version, "preprocessing", None) or {}
    r = pre.get("resize") or {}
    return r if r.get("enabled", True) and r else {}


def is_stretched_square(version) -> bool:
    r = resize_of(version)
    return bool(r) and "stretch" in str(r.get("format", "")).lower() and r.get("width") == r.get("height")


def has_augmentation(version) -> bool:
    aug = getattr(version, "augmentation", None) or {}
    return any(isinstance(v, dict) and v.get("enabled", True) for v in aug.values()) if isinstance(aug, dict) else bool(aug)


def pick_version(project):
    versions = project.versions()
    if not versions:
        return None
    def version_number(v) -> int:
        try:
            return int(str(v.version).split("/")[-1])
        except ValueError:
            return 0
    # Prefer: not stretched to a square, then no augmented copies, then newest.
    return sorted(versions, key=lambda v: (is_stretched_square(v), has_augmentation(v), -version_number(v)))[0]


def is_ball(name: str) -> bool:
    n = name.lower()
    return "ball" in n and "player" not in n


def read_names(data_yaml: Path) -> list[str]:
    import yaml
    data = yaml.safe_load(data_yaml.read_text())
    names = data.get("names", [])
    return [names[k] for k in sorted(names)] if isinstance(names, dict) else list(names)


def source_of(stem: str) -> str:
    """Roboflow names copies "<original>_jpg.rf.<hash>": the original's name."""
    return stem.split(".rf.")[0]


def clean(raw: Path, out: Path, unstretch: bool, one_per_source: bool) -> dict:
    from PIL import Image

    names = read_names(raw / "data.yaml")
    keep = {i for i, n in enumerate(names) if is_ball(n)}
    say(f"   classes: {names} → keeping {[names[i] for i in sorted(keep)]} as volleyball")
    if not keep:
        fail(f"No ball class in {names} — check this dataset by hand.")
    (out / "images").mkdir(parents=True, exist_ok=True)
    (out / "labels").mkdir(parents=True, exist_ok=True)
    n = {"images": 0, "boxes": 0, "no ball": 0, "unreadable": 0, "copies dropped": 0}
    seen: set[str] = set()
    for split in ("train", "valid", "test"):
        img_dir, lbl_dir = raw / split / "images", raw / split / "labels"
        if not img_dir.exists():
            continue
        for img in sorted(img_dir.iterdir()):
            if img.name.startswith("._") or img.suffix.lower() not in (".jpg", ".jpeg", ".png"):
                continue
            if one_per_source:
                if source_of(img.stem) in seen:
                    n["copies dropped"] += 1
                    continue
                seen.add(source_of(img.stem))
            try:
                with Image.open(img) as im:
                    im = im.convert("RGB")
                    if unstretch and im.width == im.height:
                        im = im.resize((round(im.height * UNSTRETCH_ASPECT), im.height), Image.BICUBIC)
                    im.save(out / "images" / f"{split}_{img.stem}.jpg", quality=95)
            except Exception:
                n["unreadable"] += 1
                continue
            lines = []
            label = lbl_dir / (img.stem + ".txt")
            for line in (label.read_text().splitlines() if label.exists() else []):
                parts = line.split()
                if len(parts) == 5 and parts[0].isdigit() and int(parts[0]) in keep:
                    lines.append("0 " + " ".join(parts[1:]))
            (out / "labels" / f"{split}_{img.stem}.txt").write_text("".join(l + "\n" for l in lines))
            n["images"] += 1
            n["boxes"] += len(lines)
            n["no ball"] += 0 if lines else 1
    return n


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", type=Path, default=HERE / "extra_datasets")
    args = p.parse_args()

    if not os.environ.get("ROBOFLOW_API_KEY"):
        fail("Set ROBOFLOW_API_KEY first (Roboflow → Settings → API Keys), then run again.")
    try:
        import roboflow
    except ImportError:
        fail("pip install roboflow  (in the same .venv), then run again.")

    rf = roboflow.Roboflow()
    raw_root = args.out / "_downloads"
    credits = ["Extra training data from Roboflow:\n"]
    for name, workspace, project_id, licence, url in DATASETS:
        say(f"\n== {name}  ({url})")
        out = args.out / name
        if (out / "images").exists() and any((out / "images").iterdir()):
            say(f"   already here ({sum(1 for _ in (out / 'images').iterdir())} images) — delete {out} to fetch again")
            credits.append(f"- {name}: {url} ({licence})")
            continue
        project = rf.workspace(workspace).project(project_id)
        version = pick_version(project)
        if version is None:
            fail(f"{name} has no downloadable version.")
        stretched = is_stretched_square(version)
        r = resize_of(version)
        say(f"   version {version.version}: resize {r or 'none'} · augmentation {'yes' if has_augmentation(version) else 'no'}")
        raw = raw_root / name
        if raw.exists():
            shutil.rmtree(raw)
        version.download("yolov8", location=str(raw), overwrite=True)
        if stretched:
            say(f"   ⚠️  squashed into {r.get('width')}×{r.get('height')} squares: un-stretching to 16:9")
        augmented = has_augmentation(version)
        counts = clean(raw, out, unstretch=stretched, one_per_source=augmented)
        say(f"   {counts['images']} images · {counts['boxes']} ball boxes · {counts['no ball']} with no ball"
            + (f" · {counts['copies dropped']} augmented copies dropped" if counts["copies dropped"] else "")
            + (f" · {counts['unreadable']} unreadable (skipped)" if counts["unreadable"] else ""))
        credits.append(f"- {name}: {url} ({licence}), version {version.version}")
    shutil.rmtree(raw_root, ignore_errors=True)
    (args.out / "CREDITS.txt").write_text("\n".join(credits) + "\n")
    say(f"\n✅ Extra datasets in {args.out}. Train with:\n"
        f"   python train_ball_model.py <package>.zip --extra {' '.join(str(args.out / d[0]) for d in DATASETS)}")


if __name__ == "__main__":
    main()
