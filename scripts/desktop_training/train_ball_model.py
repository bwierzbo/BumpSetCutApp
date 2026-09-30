#!/usr/bin/env python3
"""
Train the BumpSetCut volleyball detector from a RallyLab training package.

    python train_ball_model.py path/to/Test1-XXXXXXXX-XXXX.zip

(or the unzipped folder). It will:

  1. check this machine: Python, PyTorch, and which GPU it can train on;
  2. unzip the package if you give it the zip;
  3. check every image and label, and write a cleaned copy to train on —
     unreadable images, malformed lines, boxes outside the frame, repeated
     boxes and videos in both train and val are fixed or reported, and the
     package itself is never changed;
  4. show how big the balls are at each training size;
  5. train one model per size (1280 and 960 by default), picking up where it
     left off if it was interrupted;
  6. score each on the held-out val videos — recall and precision at the
     app's confidence (0.60), and mAP — and put both best.pt files and a
     results table in bring_back/.

Bring bring_back/ to the laptop and use RallyLab's Models tab: Add Model… on
each best.pt (it runs at the size it was trained at), then Evaluate.

Options: --sizes 1280 960, --base yolo26s.pt (or your previous best.pt),
--epochs 150, --cache ram, --smoke (a 1-minute run to test the setup).
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import shutil
import sys
import time
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

APP_CONFIDENCE = 0.60   # the app's detectionConfidence, rounded
HERE = Path(__file__).resolve().parent


def say(msg: str = "") -> None:
    print(msg, flush=True)


def fail(msg: str) -> None:
    say(f"\n❌ {msg}")
    sys.exit(1)


# --------------------------------------------------------------------------
# 1. The machine
# --------------------------------------------------------------------------

def check_machine() -> str:
    say("== Machine")
    if sys.version_info < (3, 9):
        fail(f"Python {platform.python_version()} is too old; install Python 3.10–3.12.")
    say(f"   Python {platform.python_version()} on {platform.system()} {platform.machine()}")
    try:
        import torch  # noqa: F401
        import ultralytics  # noqa: F401
    except ImportError as e:
        fail(f"{e.name} isn't installed: pip install torch torchvision (CUDA build) then ultralytics.")
    import torch
    import ultralytics
    say(f"   PyTorch {torch.__version__}, Ultralytics {ultralytics.__version__}")
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        vram = torch.cuda.get_device_properties(0).total_memory / 2**30
        say(f"   GPU: {name} ({vram:.0f} GB) — training on CUDA")
        return "0"
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        if platform.machine() == "x86_64":
            fail("This Python is an Intel build running under Rosetta on Apple Silicon. Install the\n"
                 "   Apple Silicon (arm64) Python from python.org, reinstall the packages, run again.")
        major, minor = (int(x) for x in torch.__version__.split(".")[:2])
        if (major, minor) < (2, 5):
            fail(f"PyTorch {torch.__version__} is too old to train on the Apple GPU.\n"
                 "   Run: pip install -U torch torchvision  — then run again.")
        say("   GPU: Apple Silicon — training on MPS")
        return "mps"
    if platform.system() != "Darwin" and shutil.which("nvidia-smi"):
        fail("There's an NVIDIA GPU but this PyTorch can't use it (a CPU-only build).\n"
             "   Reinstall it: pip install --force-reinstall torch torchvision --index-url\n"
             "   https://download.pytorch.org/whl/cu128  — then run again.")
    say("   ⚠️  No GPU found: training on the CPU will take a very long time (days).")
    return "cpu"


# --------------------------------------------------------------------------
# 2. The package
# --------------------------------------------------------------------------

def open_package(path: Path) -> Path:
    say("\n== Package")
    if not path.exists():
        fail(f"{path} doesn't exist.")
    if path.suffix.lower() == ".zip":
        target = path.with_suffix("")
        if not (target / "data.yaml").exists():
            say(f"   Unzipping {path.name} (a few minutes for 2 GB)…")
            with zipfile.ZipFile(path) as z:
                bad = z.testzip()
                if bad:
                    fail(f"The zip is damaged ({bad}). Copy it over again.")
                z.extractall(path.parent)
        path = target
    if not (path / "data.yaml").exists():
        inner = [p for p in path.iterdir() if (p / "data.yaml").exists()] if path.is_dir() else []
        if len(inner) == 1:
            path = inner[0]
        else:
            fail(f"No data.yaml in {path}: point this at the package zip or its unzipped folder.")
    say(f"   {path}")
    return path


# --------------------------------------------------------------------------
# 3. Check and clean
# --------------------------------------------------------------------------

def environment_of(clip: str) -> str:
    return {"ind": "Indoor", "bch": "Beach", "grs": "Grass"}.get(clip[:3], "Other")


def prepare(package: Path, out: Path) -> tuple[Path, dict]:
    """Validate every image/label and write a cleaned dataset to `out`."""
    from PIL import Image

    say("\n== Checking images and labels")
    manifest = {}
    if (package / "manifest.csv").exists():
        with open(package / "manifest.csv", newline="") as f:
            for row in csv.DictReader(f):
                manifest[row["image"]] = row

    if out.exists():
        shutil.rmtree(out)
    problems = Counter()
    stats = {"train": Counter(), "val": Counter()}
    sizes = []                       # (split, box width px, box height px, image w, image h)
    clips = {"train": set(), "val": set()}
    per_env = defaultdict(Counter)

    for split in ("train", "val"):
        images = sorted((package / "images" / split).glob("*"))
        images = [p for p in images if p.suffix.lower() in (".jpg", ".jpeg", ".png")]
        (out / "images" / split).mkdir(parents=True)
        (out / "labels" / split).mkdir(parents=True)
        for img in images:
            try:
                with Image.open(img) as im:
                    im.verify()
                with Image.open(img) as im:
                    w, h = im.size
            except Exception:
                problems["unreadable image (skipped)"] += 1
                continue
            label = package / "labels" / split / (img.stem + ".txt")
            lines = label.read_text().splitlines() if label.exists() else []
            if not label.exists():
                problems["image without a label file (kept as no-ball)"] += 1

            boxes = []
            for line in lines:
                parts = line.split()
                if not parts:
                    continue
                try:
                    cls, cx, cy, bw, bh = int(float(parts[0])), *map(float, parts[1:5])
                except (ValueError, IndexError):
                    problems["malformed label line (dropped)"] += 1
                    continue
                if len(parts) != 5:
                    problems["label line with extra fields (trimmed)"] += 1
                if cls != 0:
                    problems[f"class {cls} (set to 0, volleyball)"] += 1
                # Clip to the frame.
                x1, y1 = max(0.0, cx - bw / 2), max(0.0, cy - bh / 2)
                x2, y2 = min(1.0, cx + bw / 2), min(1.0, cy + bh / 2)
                if (x1, y1, x2, y2) != (cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2):
                    problems["box past the frame edge (clipped)"] += 1
                if (x2 - x1) * w < 2 or (y2 - y1) * h < 2:
                    problems["box under 2 px (dropped)"] += 1
                    continue
                box = ((x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1)
                if any(max(abs(a - b) for a, b in zip(box, other)) < 1e-4 for other in boxes):
                    problems["repeated box (dropped)"] += 1
                    continue
                boxes.append(box)

            # Hard-link the image (no extra disk), copying if the drive can't.
            dest = out / "images" / split / img.name
            try:
                os.link(img, dest)
            except OSError:
                shutil.copy2(img, dest)
            (out / "labels" / split / (img.stem + ".txt")).write_text(
                "".join(f"0 {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}\n" for cx, cy, bw, bh in boxes))

            info = manifest.get(img.name, {})
            clip = info.get("clip", "?")
            clips[split].add(clip)
            env = environment_of(clip)
            stats[split]["images"] += 1
            stats[split]["boxes"] += len(boxes)
            stats[split]["no ball"] += 0 if boxes else 1
            per_env[env][f"{split} images"] += 1
            for _, _, bw, bh in boxes:
                sizes.append((split, bw * w, bh * h, w, h))

    leaked = clips["train"] & clips["val"] - {"?"}
    if leaked:
        problems[f"clips in both train and val: {', '.join(sorted(leaked))}"] += 1

    for split in ("train", "val"):
        s = stats[split]
        say(f"   {split:5}  {s['images']:5} images · {s['boxes']:5} boxes · {s['no ball']:4} with no ball "
            f"· {len(clips[split] - {'?'})} clips")
    for env in sorted(per_env):
        say(f"   {env:7} {per_env[env]['train images']:5} train · {per_env[env]['val images']:4} val")
    if problems:
        say("   Fixed or found:")
        for what, n in problems.most_common():
            say(f"     · {what}: {n}")
    else:
        say("   Every image and label is clean.")
    if stats["val"]["images"] == 0:
        fail("No val images: the package needs at least one val video.")

    (out / "data.yaml").write_text(
        f"path: {out.as_posix()}\ntrain: images/train\nval: images/val\nnames:\n  0: volleyball\n")
    return out / "data.yaml", {"stats": {k: dict(v) for k, v in stats.items()},
                               "problems": dict(problems), "sizes": sizes}


def report_ball_sizes(sizes: list, train_sizes: list[int]) -> None:
    """How many pixels a ball gets once a frame is shrunk to each size."""
    if not sizes:
        return
    say("\n== Ball size once shrunk to the training size (median / smallest 10%)")
    for s in train_sizes:
        px = sorted(max(bw, bh) * s / max(w, h) for _, bw, bh, w, h in sizes)
        tiny = sum(p < 8 for p in px) / len(px)
        say(f"   {s:5}: {px[len(px) // 2]:5.1f} px median · {px[len(px) // 10]:4.1f} px or less for the "
            f"smallest 10% · {tiny:.0%} under 8 px")


# --------------------------------------------------------------------------
# 5–6. Train and score
# --------------------------------------------------------------------------

def train_one(data_yaml: Path, size: int, args, device: str) -> Path:
    from ultralytics import YOLO

    name = f"ball{size}" + ("_smoke" if args.smoke else "")
    run = args.runs / name
    last = run / "weights" / "last.pt"
    best = run / "weights" / "best.pt"
    if (run / "done.json").exists() and best.exists():
        say(f"\n== {name}: already trained ({best}) — delete {run} to train it again")
        return best

    workers = 0 if args.smoke else min(8, os.cpu_count() or 2)
    if last.exists():
        say(f"\n== {name}: resuming an interrupted run")
        YOLO(str(last)).train(resume=True, workers=workers)
    else:
        say(f"\n== {name}: training at {size} from {args.base}")
        YOLO(args.base).train(
            data=str(data_yaml),
            imgsz=size,
            epochs=1 if args.smoke else args.epochs,
            fraction=0.03 if args.smoke else 1.0,
            patience=args.patience,
            batch=8 if args.smoke or device == "cpu" else -1,   # -1: as big as the GPU fits
            device=device,
            workers=workers,
            cache=args.cache if args.cache != "off" else False,
            single_cls=True,
            close_mosaic=15,       # finish on un-mosaicked frames, like the app sees
            flipud=0.0,            # sky stays up
            fliplr=0.5,
            seed=0,
            deterministic=True,
            project=str(args.runs),
            name=name,
            exist_ok=True,
            plots=not args.smoke,
            val=True,
        )
    if not best.exists():
        fail(f"{name} finished without a best.pt — see the output above.")
    (run / "done.json").write_text(json.dumps({"size": size, "finished": time.time()}))
    return best


def score(best: Path, data_yaml: Path, size: int, device: str) -> dict:
    from ultralytics import YOLO

    model = YOLO(str(best))
    full = model.val(data=str(data_yaml), imgsz=size, device=device, split="val",
                     plots=False, verbose=False)
    at_app = model.val(data=str(data_yaml), imgsz=size, device=device, split="val",
                       conf=APP_CONFIDENCE, plots=False, verbose=False)
    return {
        "size": size,
        "mAP50": round(float(full.box.map50), 4),
        "mAP50-95": round(float(full.box.map), 4),
        f"recall@{APP_CONFIDENCE}": round(float(at_app.box.mr), 4),
        f"precision@{APP_CONFIDENCE}": round(float(at_app.box.mp), 4),
    }


def main() -> None:
    # Windows sends piped output (e.g. into a log) through its legacy code
    # page, which can't encode ❌ or ·; write UTF-8 so a logged run can't crash.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("package", type=Path, help="the RallyLab package zip or its unzipped folder")
    p.add_argument("--sizes", type=int, nargs="+", default=[1280, 960])
    p.add_argument("--base", default="yolo26s.pt", help="starting weights: yolo26s.pt or your previous best.pt")
    p.add_argument("--epochs", type=int, default=150)
    p.add_argument("--patience", type=int, default=40, help="stop after this many epochs without improving")
    p.add_argument("--cache", choices=["off", "ram", "disk"], default="off",
                   help="ram is fastest if the machine has 32 GB+; disk trades space for speed")
    p.add_argument("--runs", type=Path, default=HERE / "runs")
    p.add_argument("--smoke", action="store_true", help="a 1-minute run to check the setup")
    p.add_argument("--device", help="override the GPU choice: 0 (NVIDIA), mps (Apple) or cpu")
    args = p.parse_args()
    args.runs = args.runs.resolve()

    device = args.device or check_machine()
    package = open_package(args.package.resolve())
    data_yaml, check = prepare(package, HERE / "prepared" / package.name)
    report_ball_sizes(check["sizes"], args.sizes)

    sizes = [320] if args.smoke else args.sizes
    results = []
    for size in sizes:
        best = train_one(data_yaml, size, args, device)
        say(f"\n== Scoring {best.parent.parent.name} on the val videos")
        r = score(best, data_yaml, size, device)
        results.append(r)
        out = HERE / "bring_back"
        out.mkdir(exist_ok=True)
        shutil.copy2(best, out / f"ball{size}{'_smoke' if args.smoke else ''}_best.pt")

    say("\n== Results on the val videos")
    keys = list(results[0].keys())
    say("   " + "  ".join(f"{k:>16}" for k in keys))
    for r in results:
        say("   " + "  ".join(f"{str(r[k]):>16}" for k in keys))
    (HERE / "bring_back" / "results.json").write_text(json.dumps(
        {"package": package.name, "base": args.base, "results": results, "data": check["stats"],
         "fixed": check["problems"]}, indent=2))
    say(f"\n✅ Done. Bring {HERE / 'bring_back'} to the laptop: RallyLab → Models → Add Model… on each "
        f"best.pt, then Evaluate.")


if __name__ == "__main__":   # required for data-loader workers on Windows
    main()
