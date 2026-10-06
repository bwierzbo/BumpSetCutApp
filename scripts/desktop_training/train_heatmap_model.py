#!/usr/bin/env python3
"""
Train a multi-frame heatmap ball detector (VballNetV4c) on a RallyLab
multi-frame package (Models tab → Export Multi-Frame Package).

The model sees 9 consecutive grayscale frames (512×288, or 1024×576 with
--size 1024) and outputs, for each, a heatmap whose peak is the ball centre
plus a radius map. It starts
from the VballNet author's published beach-trained weights (MIT licence,
github.com/asigatchov/fast-volleyball-tracking-inference) and is fine-tuned
on your windows. A window from sampled frames has one labeled frame,
placed at a random position among the 9 so every output learns; one from
a tracked rally has every frame labeled. Only labeled frames are scored.

    python train_heatmap_model.py Test1-multiframe-<stamp>.zip
    python train_heatmap_model.py <package> --size 1024 --name heat1024

Balls in play vs resting balls: a motion model is for the ball in play.
Balls that sit still through the window (on the sideline, in a cart) are
boxed in sampled frames but aren't what it should learn to fire on, so in
training the area around a resting ball is ignored (neither "ball" nor "no
ball"), and scores count balls in play: recall is of moving balls, a peak on
a resting ball is neither a hit nor a false alarm, and resting-ball recall
is shown on its own. A ball is resting when the patch around it barely
changes over ±4 frames. Every ball in a tracked rally is the ball in play.

It first scores the author's weights untouched on your val windows (how the
off-the-shelf model does on your footage), then trains, keeping the
checkpoint with the best val F1 on balls in play — on the tracked rallies'
windows when the package has any (every frame labeled with the ball in
play, the trustworthy score), else on all windows. Results:
    runs/heatmap/<name>/  best.pt  best.onnx  metrics.json  log.csv
    bring_back/<name>/    best.pt  best.onnx  metrics.json   ← copy this folder back

Hit = predicted peak within 4 px (measured at 512×288 whatever --size) of a
labeled ball, as in the WASB/TrackNet papers; 8 px is reported too.

Needs: torch with CUDA (same .venv as train_ball_model.py), opencv-python, numpy, onnx.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import random
import shutil
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEQ = 9
SIZES = {512: (512, 288), 768: (768, 432), 1024: (1024, 576)}
BASE_WIDTH = 512        # scores are in pixels at this width, whatever the input size
SIGMA = 3.0            # the author's heatmap sigma at 512×288 (scaled with the input)
MOTION = 10            # mean grey-level change (0–255) around a ball over ±4 frames: in play
RADIUS_WEIGHT = 0.0005  # the author's scale-matching of log-radius L1 to WBCE
VBALLNET_COMMIT = "7d295c53fa733782a58dd85f772685044414f8d3"
VBALLNET_ZIP = f"https://codeload.github.com/asigatchov/vball-net-pytorch/zip/{VBALLNET_COMMIT}"
AUTHOR_WEIGHTS = ("https://github.com/asigatchov/fast-volleyball-tracking-inference/raw/master/models/"
                  "VballNetV4c_seq9_grayscale_20260908_213829.onnx")

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

try:
    import cv2
    import numpy as np
    import torch
except ImportError as e:
    print(f"\n❌ Missing {e.name}. In the .venv: pip install opencv-python numpy onnx  (torch as for train_ball_model.py)")
    sys.exit(1)


def say(msg: str = "") -> None:
    print(msg, flush=True)


def fail(msg: str) -> None:
    say(f"\n❌ {msg}")
    sys.exit(1)


# MARK: - Setup

def download(url: str) -> bytes:
    """With certifi's certificates when it's installed (python.org builds
    often have none of their own)."""
    import ssl
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        context = None
    return urllib.request.urlopen(url, timeout=120, context=context).read()


def unpack(package: Path) -> Path:
    if package.is_dir():
        return package
    if package.suffix != ".zip" or not package.exists():
        fail(f"{package} isn't a package folder or .zip.")
    target = HERE / "prepared" / package.stem
    if not (target / "windows.jsonl").exists():
        say(f"Unzipping {package.name} (a few GB, takes a minute)…")
        with zipfile.ZipFile(package) as z:
            z.extractall(HERE / "prepared")
    found = list((HERE / "prepared").glob(f"{package.stem}*/windows.jsonl"))
    if not found:
        fail(f"No windows.jsonl inside {package.name} — is it a multi-frame package?")
    return found[0].parent


def vballnet_source() -> Path:
    """The author's model code at a pinned commit, without needing git."""
    root = HERE / "vendor" / f"vball-net-pytorch-{VBALLNET_COMMIT}"
    if not (root / "src" / "model" / "vballnet_v4c.py").exists():
        say("Downloading VballNet model code (MIT)…")
        data = download(VBALLNET_ZIP)
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            z.extractall(HERE / "vendor")
    sys.path.insert(0, str(root / "src"))
    return root


def load_author_weights(model) -> None:
    """The published ONNX has each BatchNorm folded into its convolution;
    put the folded weights in the conv and make the BatchNorm pass through
    plus the folded bias. Same function as the author's model, ready to fine-tune."""
    import onnx
    from onnx import numpy_helper
    path = HERE / "vendor" / Path(AUTHOR_WEIGHTS).name
    if not path.exists():
        say("Downloading the author's beach-trained V4c weights (MIT)…")
        path.write_bytes(download(AUTHOR_WEIGHTS))
    init = {i.name: torch.from_numpy(numpy_helper.to_array(i).copy()) for i in onnx.load(str(path)).graph.initializer}
    with torch.no_grad():
        for block in ("enc1", "enc1_1", "enc2", "enc3", "dec1", "dec2"):
            conv, bn = getattr(model, block)[0], getattr(model, block)[1]
            conv.weight.copy_(init[f"{block}.0.weight"])
            bn.running_mean.zero_()
            bn.running_var.fill_(1 - bn.eps)
            bn.weight.fill_(1)
            bn.bias.copy_(init[f"{block}.0.bias"])
        for name in ("out_conv", "radius_conv"):
            getattr(model, name).weight.copy_(init[f"{name}.weight"])
            getattr(model, name).bias.copy_(init[f"{name}.bias"])


# MARK: - Data

def environment(clip: str) -> str:
    return {"ind": "indoor", "bch": "beach", "grs": "grass"}.get(clip[:3], "other")


def load_windows(root: Path) -> tuple[list[dict], list[dict]]:
    windows = [json.loads(line) for line in (root / "windows.jsonl").read_text().splitlines() if line.strip()]
    train = [w for w in windows if w["split"] == "train"]
    val = [w for w in windows if w["split"] == "val"]
    if not train or not val:
        fail("The package needs both train and val windows.")
    return train, val


class Windows(torch.utils.data.Dataset):
    """9 grayscale frames + a heatmap and a loss weight for each frame.

    Windows from sampled frames have one labeled frame (the target);
    windows from tracked rallies have a label on (nearly) every frame.
    Unlabeled frames and the area around resting balls weigh nothing.
    Portrait windows are turned a quarter turn to landscape (frames and
    balls), so every input is landscape without squashing a portrait frame.
    """

    def __init__(self, root: Path, windows: list[dict], train: bool, size: tuple[int, int]):
        self.root, self.windows, self.train = root, windows, train
        self.width, self.height = size
        self.sigma = SIGMA * self.width / BASE_WIDTH
        ys, xs = np.mgrid[0:self.height, 0:self.width]
        self.ys, self.xs = ys.astype(np.float32), xs.astype(np.float32)

    def __len__(self):
        return len(self.windows)

    def gray(self, path: str):
        img = cv2.imread(str(self.root / path), cv2.IMREAD_GRAYSCALE)
        if img is None:
            raise FileNotFoundError(self.root / path)
        return img

    def moving(self, w: dict) -> list[bool]:
        """Per target-frame ball: does it move over ±4 frames?"""
        if "labels" in w:
            return [True] * len(w["balls"])   # a tracked rally's ball is the ball in play
        t = w["target"]
        if not w["balls"] or t < 4 or t + 4 >= len(w["frames"]):
            return [True] * len(w["balls"])
        before, now, after = (self.gray(w["frames"][t + k]).astype(np.int16) for k in (-4, 0, 4))
        h, wd = now.shape
        tags = []
        for cx, cy, bw, bh in w["balls"]:
            s = max(bw * wd, bh * h) * 0.75 + 2
            x0, x1 = int(max(0, cx * wd - s)), int(min(wd, cx * wd + s))
            y0, y1 = int(max(0, cy * h - s)), int(min(h, cy * h + s))
            patch = now[y0:y1, x0:x1]
            change = max(np.abs(patch - before[y0:y1, x0:x1]).mean(), np.abs(patch - after[y0:y1, x0:x1]).mean()) \
                if patch.size else MOTION + 1
            tags.append(bool(change > MOTION))
        return tags

    def __getitem__(self, i):
        w = self.windows[i]
        W, H = self.width, self.height
        target = w["target"]
        last_start = len(w["frames"]) - SEQ
        # Train: the target frame anywhere among the 9. Val: in the middle.
        start = random.randint(max(0, target - SEQ + 1), min(target, last_start)) if self.train \
            else min(max(0, target - SEQ // 2), last_start)
        index = target - start
        portrait = w["size"][1] > w["size"][0]
        frames = []
        for path in w["frames"][start:start + SEQ]:
            img = self.gray(path)
            if portrait:
                img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
            frames.append(cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA))
        clip = np.stack(frames).astype(np.float32) / 255.0

        # Per frame: a list of (ball, moving), or None where there's no label.
        if "labels" in w:
            labels = [None if l is None else [(b, True) for b in l] for l in w["labels"][start:start + SEQ]]
        else:
            labels = [None] * SEQ
            labels[index] = list(zip(w["balls"], self.moving(w)))
        # Balls as (x, y, radius, moving) in input pixels.
        def to_pixels(ball, moving):
            cx, cy, bw, bh = ball
            if portrait:  # quarter turn clockwise: (x, y) → (1 − y, x)
                cx, cy, bw, bh = 1 - cy, cx, bh, bw
            return cx * W, cy * H, max(bw * W, bh * H) / 2, moving
        per_frame = [None if l is None else [to_pixels(b, m) for b, m in l] for l in labels]

        if self.train:
            if random.random() < 0.5:
                clip = clip[:, :, ::-1]
                per_frame = [None if f is None else [(W - 1 - x, y, r, m) for x, y, r, m in f] for f in per_frame]
            if random.random() < 0.2:  # a ball's flight played backwards is still a ball's flight
                clip = clip[::-1]
                per_frame = per_frame[::-1]
                index = SEQ - 1 - index
            gain, bias = random.uniform(0.7, 1.3), random.uniform(-0.1, 0.1)
            gamma = random.uniform(0.7, 1.4)
            clip = np.clip(clip * gain + bias, 0, 1) ** gamma
            if random.random() < 0.25:
                # iPhones record HDR by default; seen without tone mapping it's
                # washed out: blacks lifted, midtones brightened. Same on all 9.
                lift = random.uniform(0.03, 0.15)
                clip = lift + (1 - lift) * clip ** random.uniform(0.6, 0.9)
            if random.random() < 0.3:
                clip = np.clip(clip + np.random.normal(0, random.uniform(0.005, 0.03), clip.shape), 0, 1)
            clip = np.ascontiguousarray(clip, dtype=np.float32)

        heat = np.zeros((SEQ, H, W), np.float32)
        weight = np.zeros((SEQ, H, W), np.float32)
        radius = np.zeros((SEQ, 2), np.float32)  # (radius as a fraction of width, has a ball)
        for f, balls in enumerate(per_frame):
            if balls is None:
                continue
            weight[f] = 1
            for x, y, r, moving in balls:
                d2 = (self.xs - x) ** 2 + (self.ys - y) ** 2
                if moving:
                    heat[f] = np.maximum(heat[f], np.exp(-d2 / (2 * self.sigma ** 2)))
                else:
                    weight[f][d2 <= max(3 * self.sigma, 1.5 * r + 2) ** 2] = 0
            in_play = [r for _, _, r, m in balls if m]
            if in_play:
                radius[f] = (max(in_play) / W, 1)
        # Scoring looks at the target frame's balls: (x, y, moving).
        centres = np.full((8, 3), -1, np.float32)
        for k, (x, y, _, moving) in enumerate((per_frame[index] or [])[:8]):
            centres[k] = (x, y, float(moving))
        return (torch.from_numpy(clip), torch.from_numpy(heat), torch.from_numpy(weight), index,
                torch.from_numpy(radius), torch.from_numpy(centres))


# MARK: - Scoring

def peaks(heat, threshold=0.5) -> list[tuple[float, float]]:
    """Centroids of the blobs above threshold, as the author's decoder does."""
    binary = (heat >= threshold).astype(np.uint8)
    n, _, stats, centroids = cv2.connectedComponentsWithStats(binary, connectivity=8)
    return [tuple(centroids[k]) for k in range(1, n) if stats[k, cv2.CC_STAT_AREA] >= 2]


def score(model, loader, val_windows, device, width: int) -> dict:
    """Balls in play: recall, precision, F1. A peak on a resting ball is
    neither a hit nor a false alarm; resting-ball recall is kept apart."""
    model.eval()
    tallies: dict[str, dict[str, int]] = {}
    order = 0
    scale = BASE_WIDTH / width
    with torch.no_grad():
        for clip, _, _, index, _, centres in loader:
            out = model(clip.to(device, non_blocking=True))
            heat = out[torch.arange(len(index)), index.to(device)].float().cpu().numpy()
            for b in range(len(index)):
                env = environment(val_windows[order]["clip"])
                kind = "tracked" if "labels" in val_windows[order] else "sampled"
                order += 1
                truth = [(c[0], c[1], c[2] > 0.5) for c in centres[b].numpy() if c[0] >= 0]
                found = peaks(heat[b])
                for tau in (4, 8):
                    for key in (f"{env}@{tau}", f"all@{tau}", f"{kind}@{tau}"):
                        t = tallies.setdefault(key, {"tp": 0, "fp": 0, "fn": 0, "resting_hit": 0, "resting_missed": 0})
                        unmatched = list(truth)
                        for p in found:
                            hit = min(unmatched, key=lambda u: math.dist(p, u[:2]), default=None)
                            if hit and math.dist(p, hit[:2]) * scale <= tau:
                                unmatched.remove(hit)
                                t["tp" if hit[2] else "resting_hit"] += 1
                            else:
                                t["fp"] += 1
                        for u in unmatched:
                            t["fn" if u[2] else "resting_missed"] += 1
    result = {}
    for key, t in sorted(tallies.items()):
        p = t["tp"] / max(1, t["tp"] + t["fp"])
        r = t["tp"] / max(1, t["tp"] + t["fn"])
        resting = t["resting_hit"] / max(1, t["resting_hit"] + t["resting_missed"])
        result[key] = {"precision": round(p, 4), "recall": round(r, 4),
                       "f1": round(2 * p * r / max(1e-9, p + r), 4), "resting_recall": round(resting, 4), **t}
    return result


def show(title: str, metrics: dict) -> None:
    say(f"\n{title}")
    say(f"   {'':10} {'in play: recall':>15} {'precision':>9} {'F1':>6}  {'resting recall':>14}   (4 px · 8 px recall/precision)")
    for env in ("all", "beach", "grass", "indoor", "tracked", "sampled"):
        a, b = metrics.get(f"{env}@4"), metrics.get(f"{env}@8")
        if a:
            say(f"   {env:10} {a['recall']:15.1%} {a['precision']:9.1%} {a['f1']:6.3f}  {a['resting_recall']:14.1%}"
                f"   · {b['recall']:.1%} / {b['precision']:.1%}")


# MARK: - Main

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("package", type=Path, help="Multi-frame package .zip or unzipped folder")
    p.add_argument("--epochs", type=int, default=60)
    p.add_argument("--size", type=int, choices=sorted(SIZES), default=512,
                   help="Input width: 512 (512×288, the author's), 768 (768×432, ~2.25× the work) or 1024 (1024×576 — far balls twice the pixels, ~4× the work)")
    p.add_argument("--batch", type=int, default=None, help="Default 16 at 512, 8 at 768, 4 at 1024")
    p.add_argument("--lr", type=float, default=None,
                   help="Default 5e-4 fine-tuning, 1e-3 from scratch (the author's from-scratch rate)")
    p.add_argument("--workers", type=int, default=6)
    p.add_argument("--name", default="heat_v4c")
    p.add_argument("--from-scratch", action="store_true", help="Don't start from the author's weights")
    args = p.parse_args()

    try:
        import onnx  # noqa: F401
    except ImportError:
        fail("Missing onnx. In the .venv: pip install onnx")
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if device.type != "cuda":
        say("⚠️  No CUDA GPU found — this will be very slow. Check the torch install (see train_ball_model.py).")

    root = unpack(args.package)
    vballnet_source()
    from model.vballnet_v4c import VballNetV4c

    size = SIZES[args.size]
    batch = args.batch or {512: 16, 768: 8}.get(args.size, 4)
    lr = args.lr or (1e-3 if args.from_scratch else 5e-4)
    train_w, val_w = load_windows(root)
    say(f"{len(train_w)} train · {len(val_w)} val windows "
        f"({sum(1 for w in val_w if w['balls'])} val with a ball) from {root.name}")
    tracked = sum(1 for w in train_w + val_w if "labels" in w)
    say(f"{tracked} windows from tracked rallies"
        + ("" if tracked else " — none: is this an old package? Track rallies and re-export to use them."))
    loader = lambda ws, train: torch.utils.data.DataLoader(
        Windows(root, ws, train, size), batch_size=batch, shuffle=train, num_workers=args.workers,
        pin_memory=device.type == "cuda", drop_last=train, persistent_workers=args.workers > 0)
    train_loader, val_loader = loader(train_w, True), loader(val_w, False)

    say(f"Input {size[0]}×{size[1]}, batch {batch}.")
    model = VballNetV4c(height=size[1], width=size[0], in_dim=SEQ, out_dim=SEQ)
    if not args.from_scratch:
        load_author_weights(model)
    model.to(device)

    run = HERE / "runs" / "heatmap" / args.name
    if run.exists():
        fail(f"{run} exists — pass a new --name (or delete it).")
    run.mkdir(parents=True)
    metrics = {"package": root.name, "size": list(size), "from_scratch": args.from_scratch,
               "baseline": None, "best": None, "best_epoch": None}

    if not args.from_scratch:
        metrics["baseline"] = score(model, val_loader, val_w, device, size[0])
        show("The author's weights, untouched, on your val windows:", metrics["baseline"])

    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    # torch.amp.GradScaler is torch ≥ 2.3; older builds have the cuda one.
    scaler = (torch.amp.GradScaler("cuda", enabled=device.type == "cuda") if hasattr(torch.amp, "GradScaler")
              else torch.cuda.amp.GradScaler(enabled=device.type == "cuda"))
    best_f1 = -1.0
    log = [["epoch", "loss", "recall4", "precision4", "f1_4", "recall8", "f1_8", "resting_recall4", "seconds"]]
    for epoch in range(1, args.epochs + 1):
        model.train()
        started, total, batches = time.time(), 0.0, 0
        for clip, heat, weight, _, radius, _ in train_loader:
            clip, heat = clip.to(device, non_blocking=True), heat.to(device, non_blocking=True)
            weight, radius = weight.to(device, non_blocking=True), radius.to(device)
            with torch.autocast(device_type=device.type, enabled=device.type == "cuda"):
                out = model(clip)
            pred = out[:, :SEQ].float().clamp(1e-7, 1 - 1e-7)
            # The author's weighted BCE, per frame, over the pixels that count
            # (labeled frames, minus the area around resting balls).
            wbce = -((1 - pred) ** 2 * heat * torch.log(pred) + pred ** 2 * (1 - heat) * torch.log(1 - pred))
            counted = weight.sum(dim=(2, 3))
            per_frame = (wbce * weight).sum(dim=(2, 3)) / counted.clamp(min=1)
            labeled = (counted > 0).float()
            loss = (per_frame * labeled).sum() / labeled.sum().clamp(min=1)
            has_ball = radius[..., 1] > 0
            if has_ball.any():
                peak = heat.flatten(2).argmax(2)
                r_pred = out[:, SEQ:].float().flatten(2).gather(2, peak[..., None])[..., 0]
                loss = loss + RADIUS_WEIGHT * (torch.log(r_pred[has_ball]) - torch.log(radius[..., 0][has_ball])).abs().mean()
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            total += loss.item(); batches += 1
        scheduler.step()
        m = score(model, val_loader, val_w, device, size[0])
        a4, a8 = m["all@4"], m["all@8"]
        # Tracked rallies label the ball in play on every frame, so they're the
        # trustworthy score; sampled frames' in-play tags guess from motion.
        judged = m.get("tracked@4", a4)
        log.append([epoch, round(total / max(1, batches), 6), a4["recall"], a4["precision"], a4["f1"],
                    a8["recall"], a8["f1"], a4["resting_recall"], round(time.time() - started)])
        say(f"epoch {epoch:3}/{args.epochs}  loss {total / max(1, batches):.5f}  "
            f"in play: F1 {a4['f1']:.3f} (recall {a4['recall']:.1%}, precision {a4['precision']:.1%})  "
            f"@8px {a8['f1']:.3f}"
            + (f"  · tracked F1 {judged['f1']:.3f} (recall {judged['recall']:.1%})" if "tracked@4" in m else "")
            + f"  {time.time() - started:.0f}s")
        torch.save({"state_dict": model.state_dict(), "epoch": epoch}, run / "last.pt")
        if judged["f1"] > best_f1:
            best_f1 = judged["f1"]
            metrics["best"], metrics["best_epoch"] = m, epoch
            torch.save({"state_dict": model.state_dict(), "epoch": epoch}, run / "best.pt")
        with open(run / "log.csv", "w", newline="") as f:
            csv.writer(f).writerows(log)

    model.load_state_dict(torch.load(run / "best.pt", map_location=device)["state_dict"])
    show(f"Best (epoch {metrics['best_epoch']}):", metrics["best"])
    model.cpu().eval()
    # The classic exporter, as the author's models are exported; newer torch defaults to dynamo.
    import inspect
    legacy = {"dynamo": False} if "dynamo" in inspect.signature(torch.onnx.export).parameters else {}
    torch.onnx.export(model, (torch.zeros(1, SEQ, size[1], size[0]),), str(run / "best.onnx"), opset_version=17,
                      input_names=["clip"], output_names=["maps"], dynamic_axes={"clip": {0: "B"}, "maps": {0: "B"}},
                      do_constant_folding=True, **legacy)
    (run / "metrics.json").write_text(json.dumps(metrics, indent=2))

    back = HERE / "bring_back" / args.name
    back.mkdir(parents=True, exist_ok=True)
    for name in ("best.pt", "best.onnx", "metrics.json", "log.csv"):
        shutil.copy(run / name, back / name)
    (back / "CREDITS.txt").write_text(
        "VballNetV4c architecture and starting weights: Alexander Sigatchov, MIT licence —\n"
        "https://github.com/asigatchov/vball-net-pytorch, "
        "https://github.com/asigatchov/fast-volleyball-tracking-inference\n")
    say(f"\n✅ Done. Copy {back} back to the Mac.")


if __name__ == "__main__":
    main()
