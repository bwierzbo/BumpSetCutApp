#!/usr/bin/env python3
"""
Train a multi-frame heatmap ball detector (VballNetV4c) on a RallyLab
multi-frame package (Models tab → Export Multi-Frame Package).

The model sees 9 consecutive grayscale frames at 512×288 and outputs, for
each, a heatmap whose peak is the ball centre plus a radius map. It starts
from the VballNet author's published beach-trained weights (MIT licence,
github.com/asigatchov/fast-volleyball-tracking-inference) and is fine-tuned
on your windows. Each window has one labeled frame; only that frame's
heatmap is scored, and it's placed at a random position among the 9 so
every output learns.

    python train_heatmap_model.py Test1-multiframe-<stamp>.zip
    python train_heatmap_model.py <package> --epochs 60 --batch 16 --name heat1

It first scores the author's weights untouched on your val windows (how the
off-the-shelf model does on your footage), then trains, keeping the
checkpoint with the best val F1 for the labeled frame. Results:
    runs/heatmap/<name>/  best.pt  best.onnx  metrics.json  log.csv
    bring_back/<name>/    best.pt  best.onnx  metrics.json   ← copy this folder back

Hit = predicted peak within 4 px (at 512×288) of a labeled ball, as in the
WASB/TrackNet papers; 8 px is reported too. A window with no ball counts any
peak as a false positive.

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
WIDTH, HEIGHT = 512, 288
SIGMA = 3.0            # the author's heatmap sigma at 512×288
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
    """9 grayscale frames at 512×288 + the labeled frame's heatmap.

    Portrait windows are turned a quarter turn to landscape (frames and
    balls), so every input is 512×288 without squashing a portrait frame.
    """

    def __init__(self, root: Path, windows: list[dict], train: bool):
        self.root, self.windows, self.train = root, windows, train
        ys, xs = np.mgrid[0:HEIGHT, 0:WIDTH]
        self.ys, self.xs = ys.astype(np.float32), xs.astype(np.float32)

    def __len__(self):
        return len(self.windows)

    def __getitem__(self, i):
        w = self.windows[i]
        target = w["target"]
        last_start = len(w["frames"]) - SEQ
        # Train: the labeled frame anywhere among the 9. Val: in the middle.
        start = random.randint(max(0, target - SEQ + 1), min(target, last_start)) if self.train \
            else min(max(0, target - SEQ // 2), last_start)
        index = target - start
        portrait = w["size"][1] > w["size"][0]
        frames = []
        for path in w["frames"][start:start + SEQ]:
            img = cv2.imread(str(self.root / path), cv2.IMREAD_GRAYSCALE)
            if img is None:
                raise FileNotFoundError(self.root / path)
            if portrait:
                img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
            frames.append(cv2.resize(img, (WIDTH, HEIGHT), interpolation=cv2.INTER_AREA))
        clip = np.stack(frames).astype(np.float32) / 255.0
        # Balls as (x, y, radius) in 512×288 pixels.
        balls = []
        for cx, cy, bw, bh in w["balls"]:
            if portrait:  # quarter turn clockwise: (x, y) → (1 − y, x)
                cx, cy, bw, bh = 1 - cy, cx, bh, bw
            r = max(bw * WIDTH, bh * HEIGHT) / 2
            balls.append((cx * WIDTH, cy * HEIGHT, r))

        if self.train:
            if random.random() < 0.5:
                clip = clip[:, :, ::-1]
                balls = [(WIDTH - 1 - x, y, r) for x, y, r in balls]
            if random.random() < 0.2:  # a ball's flight played backwards is still a ball's flight
                clip = clip[::-1]
                index = SEQ - 1 - index
            gain, bias = random.uniform(0.7, 1.3), random.uniform(-0.1, 0.1)
            gamma = random.uniform(0.7, 1.4)
            clip = np.clip(clip * gain + bias, 0, 1) ** gamma
            if random.random() < 0.3:
                clip = np.clip(clip + np.random.normal(0, random.uniform(0.005, 0.03), clip.shape), 0, 1)
            clip = np.ascontiguousarray(clip, dtype=np.float32)

        heat = np.zeros((HEIGHT, WIDTH), np.float32)
        radius = np.zeros(2, np.float32)  # (radius as a fraction of width, has a ball)
        for x, y, r in balls:
            heat = np.maximum(heat, np.exp(-((self.xs - x) ** 2 + (self.ys - y) ** 2) / (2 * SIGMA ** 2)))
        if balls:
            radius[:] = (max(r for _, _, r in balls) / WIDTH, 1)
        centres = np.full((8, 2), -1, np.float32)
        for k, (x, y, _) in enumerate(balls[:8]):
            centres[k] = (x, y)
        return (torch.from_numpy(clip), torch.from_numpy(heat), index,
                torch.from_numpy(radius), torch.from_numpy(centres))



# MARK: - Scoring

def peaks(heat, threshold=0.5) -> list[tuple[float, float]]:
    """Centroids of the blobs above threshold, as the author's decoder does."""
    binary = (heat >= threshold).astype(np.uint8)
    n, _, stats, centroids = cv2.connectedComponentsWithStats(binary, connectivity=8)
    return [tuple(centroids[k]) for k in range(1, n) if stats[k, cv2.CC_STAT_AREA] >= 2]


def score(model, loader, val_windows, device) -> dict:
    model.eval()
    tallies: dict[str, dict[str, int]] = {}
    order = 0
    with torch.no_grad():
        for clip, _, index, _, centres in loader:
            out = model(clip.to(device, non_blocking=True))
            heat = out[torch.arange(len(index)), index.to(device)].float().cpu().numpy()
            for b in range(len(index)):
                env = environment(val_windows[order]["clip"])
                order += 1
                truth = [tuple(c) for c in centres[b].numpy() if c[0] >= 0]
                found = peaks(heat[b])
                for tau in (4, 8):
                    t = tallies.setdefault(f"{env}@{tau}", {"tp": 0, "fp": 0, "fn": 0})
                    a = tallies.setdefault(f"all@{tau}", {"tp": 0, "fp": 0, "fn": 0})
                    unmatched = list(truth)
                    for p in found:
                        hit = next((u for u in unmatched if math.dist(p, u) <= tau), None)
                        key = "tp" if hit else "fp"
                        t[key] += 1; a[key] += 1
                        if hit:
                            unmatched.remove(hit)
                    t["fn"] += len(unmatched); a["fn"] += len(unmatched)
    result = {}
    for key, t in sorted(tallies.items()):
        p = t["tp"] / max(1, t["tp"] + t["fp"])
        r = t["tp"] / max(1, t["tp"] + t["fn"])
        result[key] = {"precision": round(p, 4), "recall": round(r, 4),
                       "f1": round(2 * p * r / max(1e-9, p + r), 4), **t}
    return result


def show(title: str, metrics: dict) -> None:
    say(f"\n{title}")
    say(f"   {'':12} {'recall':>7} {'precision':>9} {'F1':>6}   (within 4 px · within 8 px)")
    for env in ("all", "beach", "grass", "indoor"):
        a, b = metrics.get(f"{env}@4"), metrics.get(f"{env}@8")
        if a:
            say(f"   {env:12} {a['recall']:7.1%} {a['precision']:9.1%} {a['f1']:6.3f}   · {b['recall']:.1%} / {b['precision']:.1%}")


# MARK: - Main

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("package", type=Path, help="Multi-frame package .zip or unzipped folder")
    p.add_argument("--epochs", type=int, default=60)
    p.add_argument("--batch", type=int, default=16)
    p.add_argument("--lr", type=float, default=5e-4, help="Fine-tuning rate (the author's from-scratch rate is 1e-3)")
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

    train_w, val_w = load_windows(root)
    say(f"{len(train_w)} train · {len(val_w)} val windows "
        f"({sum(1 for w in val_w if w['balls'])} val with a ball) from {root.name}")
    loader = lambda ws, train: torch.utils.data.DataLoader(
        Windows(root, ws, train), batch_size=args.batch, shuffle=train, num_workers=args.workers,
        pin_memory=device.type == "cuda", drop_last=train, persistent_workers=args.workers > 0)
    train_loader, val_loader = loader(train_w, True), loader(val_w, False)

    model = VballNetV4c(height=HEIGHT, width=WIDTH, in_dim=SEQ, out_dim=SEQ)
    if not args.from_scratch:
        load_author_weights(model)
    model.to(device)

    run = HERE / "runs" / "heatmap" / args.name
    if run.exists():
        fail(f"{run} exists — pass a new --name (or delete it).")
    run.mkdir(parents=True)
    metrics = {"package": root.name, "baseline": None, "best": None, "best_epoch": None}

    if not args.from_scratch:
        metrics["baseline"] = score(model, val_loader, val_w, device)
        show("The author's weights, untouched, on your val windows:", metrics["baseline"])

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    # torch.amp.GradScaler is torch ≥ 2.3; older builds have the cuda one.
    scaler = (torch.amp.GradScaler("cuda", enabled=device.type == "cuda") if hasattr(torch.amp, "GradScaler")
              else torch.cuda.amp.GradScaler(enabled=device.type == "cuda"))
    best_f1 = -1.0
    log = [["epoch", "loss", "recall4", "precision4", "f1_4", "recall8", "f1_8", "seconds"]]
    for epoch in range(1, args.epochs + 1):
        model.train()
        started, total, batches = time.time(), 0.0, 0
        for clip, heat, index, radius, _ in train_loader:
            clip, heat = clip.to(device, non_blocking=True), heat.to(device, non_blocking=True)
            index, radius = index.to(device), radius.to(device)
            with torch.autocast(device_type=device.type, enabled=device.type == "cuda"):
                out = model(clip)
            rows = torch.arange(len(index), device=device)
            pred = out[rows, index].float().clamp(1e-7, 1 - 1e-7)
            # The author's weighted BCE, on the labeled frame only.
            loss = -((1 - pred) ** 2 * heat * torch.log(pred) + pred ** 2 * (1 - heat) * torch.log(1 - pred)).mean()
            has_ball = radius[:, 1] > 0
            if has_ball.any():
                peak = heat.flatten(1).argmax(1)
                r_pred = out[rows, SEQ + index].float().flatten(1).gather(1, peak[:, None])[:, 0]
                loss = loss + RADIUS_WEIGHT * (torch.log(r_pred[has_ball]) - torch.log(radius[has_ball, 0])).abs().mean()
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            total += float(loss); batches += 1
        scheduler.step()
        m = score(model, val_loader, val_w, device)
        a4, a8 = m["all@4"], m["all@8"]
        log.append([epoch, round(total / max(1, batches), 6), a4["recall"], a4["precision"], a4["f1"],
                    a8["recall"], a8["f1"], round(time.time() - started)])
        say(f"epoch {epoch:3}/{args.epochs}  loss {total / max(1, batches):.5f}  "
            f"val F1 {a4['f1']:.3f} (recall {a4['recall']:.1%}, precision {a4['precision']:.1%})  "
            f"@8px {a8['f1']:.3f}  {time.time() - started:.0f}s")
        torch.save({"state_dict": model.state_dict(), "epoch": epoch}, run / "last.pt")
        if a4["f1"] > best_f1:
            best_f1 = a4["f1"]
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
    torch.onnx.export(model, (torch.zeros(1, SEQ, HEIGHT, WIDTH),), str(run / "best.onnx"), opset_version=17,
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
