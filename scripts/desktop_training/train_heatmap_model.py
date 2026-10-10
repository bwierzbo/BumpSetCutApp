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
The F1 comes with a 90% range from resampling whole val videos: with few
val videos, two runs whose ranges overlap aren't told apart by this score.
A ball hidden between two sightings ("occluded" in the package) is neither
hit nor miss; dead-time windows (no rally on) score how often it fires.

Experiments (each off by default, to compare one at a time): --aug (phone
footage: shake, zoom, covered ball, look-alikes, compression), --occluded
(faint target on a hidden ball), --qfl (quality focal loss), --mine (hard
example mining), --seed N (the same randomness, or a second seed to see
the noise).

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
IN_PLAY, RESTING, OCCLUDED = 1, 0, 2   # a ball's kind
OCCLUDED_PEAK = 0.5    # --occluded: an occluded ball's target, fainter (and twice as wide) than a seen one's
OCCLUDED_TAU = 16      # px at 512: a peak this near an occluded ball is it (its place is a guess)
MINE_FROM, MINE_EVERY, MINE_WEIGHT = 3, 3, 3.0  # --mine: from epoch 3, every 3, hard windows drawn 3× as often
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
            w = init[f"{block}.0.weight"]
            if conv.weight.shape[1] == 3 * w.shape[1]:
                # A colour model from grey weights: each frame's grey filter
                # split over its R, G and B — the same response to a grey frame.
                w = w.repeat_interleave(3, dim=1) / 3
            conv.weight.copy_(w)
            bn.running_mean.zero_()
            bn.running_var.fill_(1 - bn.eps)
            bn.weight.fill_(1)
            bn.bias.copy_(init[f"{block}.0.bias"])
        for name in ("out_conv", "radius_conv"):
            getattr(model, name).weight.copy_(init[f"{name}.weight"])
            getattr(model, name).bias.copy_(init[f"{name}.bias"])


def color_model(base, size):
    """V4c on colour frames: 9 frames × RGB in (27 channels, frame by frame),
    and each channel's 8 differences between neighbouring frames (24) — the
    grey model's 9 + 8, three times over. The rest of the network is the same."""
    from model.vballnet_v4c import conv_bn_relu

    class VballNetV4cColor(base):
        def __init__(self):
            super().__init__(height=size[1], width=size[0], in_dim=SEQ, out_dim=SEQ)
            self.in_dim = SEQ * 3
            self.enc1 = conv_bn_relu(SEQ * 3 + (SEQ - 1) * 3, 32)

        def _features(self, frames):
            x = torch.cat((frames, frames[:, 3:] - frames[:, :-3]), dim=1)
            x1 = self.enc1_1(self.enc1(x))
            x2 = self.enc2(self.pool1(x1))
            x3 = self.enc3(self.pool2(x2))
            if self.context is not None:
                x3 = x3 + self.context(x3)
            x = self.dec1(torch.cat((self.up1(x3), x2), dim=1))
            return self.dec2(torch.cat((self.up2(x), x1), dim=1))

    return VballNetV4cColor()


# MARK: - Data

def environment(clip: str) -> str:
    return {"ind": "indoor", "bch": "beach", "grs": "grass"}.get(clip[:3], "other")


def load_windows(root: Path) -> tuple[list[dict], list[dict], list[dict]]:
    """Train, val, and dead-time windows (never trained on: scored only)."""
    windows = [json.loads(line) for line in (root / "windows.jsonl").read_text().splitlines() if line.strip()]
    dead = [w for w in windows if w.get("dead")]
    train = [w for w in windows if w["split"] == "train" and not w.get("dead")]
    val = [w for w in windows if w["split"] == "val" and not w.get("dead")]
    if not train or not val:
        fail("The package needs both train and val windows.")
    return train, val, dead


class Windows(torch.utils.data.Dataset):
    """9 grayscale frames + a heatmap and a loss weight for each frame.

    Windows from sampled frames have one labeled frame (the target);
    windows from tracked rallies have a label on (nearly) every frame.
    Unlabeled frames and the area around resting balls weigh nothing.
    Portrait windows are turned a quarter turn to landscape (frames and
    balls), so every input is landscape without squashing a portrait frame.

    Balls are (x, y, radius, kind) in input pixels: kind IN_PLAY, RESTING,
    or OCCLUDED (hidden between two sightings, where it must be). Without
    `occluded` an occluded ball's frame trains as "no ball", as it always
    did; with it, it's a faint, wider target — there, but not seen.

    `aug` adds what phone footage does to the picture: a hand-held camera
    (each frame shifted a little from the last), the ball nearer or farther
    (zoomed in or out), a ball covered for a frame or two (by a player, the
    net) with its label kept, look-alike blobs elsewhere, and heavy video
    compression.
    """

    def __init__(self, root: Path, windows: list[dict], train: bool, size: tuple[int, int], color: bool = False,
                 aug: bool = False, occluded: bool = False):
        self.root, self.windows, self.train, self.color = root, windows, train, color
        self.aug, self.occluded = aug and train, occluded
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

    def rgb(self, path: str):
        img = cv2.imread(str(self.root / path), cv2.IMREAD_COLOR)
        if img is None:
            raise FileNotFoundError(self.root / path)
        return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

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

    def labels(self, w: dict, start: int, index: int) -> list:
        """Per frame: a list of (ball, kind), or None where there's no label."""
        if w.get("dead"):
            return [None] * SEQ
        if "labels" not in w:
            labels = [None] * SEQ
            labels[index] = [(b, IN_PLAY if m else RESTING) for b, m in zip(w["balls"], self.moving(w))]
            return labels
        labels = [None if l is None else [(b, IN_PLAY) for b in l] for l in w["labels"][start:start + SEQ]]
        for f, b in enumerate((w.get("occluded") or [None] * len(w["frames"]))[start:start + SEQ]):
            if b is not None and labels[f] is not None:
                labels[f] = labels[f] + [(b, OCCLUDED)]
        return labels

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
        labels = self.labels(w, start, index)

        # Zoom: the frame scaled by `s` and cut (or padded) back to W×H at (ox, oy).
        s = math.exp(random.uniform(math.log(0.75), math.log(1.5))) if self.aug and random.random() < 0.5 else 1.0
        Ws, Hs = round(W * s), round(H * s)
        ox = random.randint(0, Ws - W) if Ws > W else -random.randint(0, W - Ws)
        oy = random.randint(0, Hs - H) if Hs > H else -random.randint(0, H - Hs)
        # Hand-held: each frame a little off from the last (a random walk).
        shake = np.zeros((SEQ, 2), np.float32)
        if self.aug and random.random() < 0.5:
            step = random.uniform(0.3, 2.0) * W / BASE_WIDTH
            shake = np.cumsum(np.random.normal(0, step, (SEQ, 2)), axis=0).astype(np.float32)
            shake -= shake[index]
        quality = random.randint(20, 60) if self.aug and random.random() < 0.3 else None

        frames = []
        for f, path in enumerate(w["frames"][start:start + SEQ]):
            img = self.rgb(path) if self.color else self.gray(path)
            if portrait:
                img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
            img = cv2.resize(img, (Ws, Hs), interpolation=cv2.INTER_AREA)
            if s >= 1:
                img = img[oy:oy + H, ox:ox + W]
            else:
                canvas = np.empty((H, W) + img.shape[2:], img.dtype)
                canvas[...] = img.mean(axis=(0, 1)).astype(img.dtype)
                canvas[-oy:-oy + Hs, -ox:-ox + Ws] = img
                img = canvas
            if shake[f].any():
                img = cv2.warpAffine(img, np.float32([[1, 0, shake[f][0]], [0, 1, shake[f][1]]]), (W, H),
                                     flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            if quality:
                img = cv2.imdecode(cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])[1],
                                   cv2.IMREAD_UNCHANGED)
            frames.append(img)
        clip = np.stack(frames).astype(np.float32) / 255.0

        def to_pixels(f, ball, kind):
            cx, cy, bw, bh = ball
            if portrait:  # quarter turn clockwise: (x, y) → (1 − y, x)
                cx, cy, bw, bh = 1 - cy, cx, bh, bw
            return cx * Ws - ox + shake[f][0], cy * Hs - oy + shake[f][1], max(bw * Ws, bh * Hs) / 2, kind
        # A ball zoomed out of the picture isn't in it.
        per_frame = [None if l is None else [p for p in (to_pixels(f, b, k) for b, k in l) if 0 <= p[0] < W and 0 <= p[1] < H]
                     for f, l in enumerate(labels)]

        if self.train:
            if random.random() < 0.5:
                clip = clip[:, :, ::-1]
                per_frame = [None if f is None else [(W - 1 - x, y, r, k) for x, y, r, k in f] for f in per_frame]
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
            if self.color:
                # Balls come in every colour: shuffle the channels (yellow/blue
                # becomes cyan/red, …) and vary the saturation, the same on all
                # 9 frames, so the model can't lean on one ball's colours.
                if random.random() < 0.5:
                    clip = clip[..., np.random.permutation(3)]
                grey = clip.mean(axis=-1, keepdims=True)
                clip = np.clip(grey + random.uniform(0.4, 1.4) * (clip - grey), 0, 1)
            if self.aug:
                clip = np.ascontiguousarray(clip)
                if random.random() < 0.3:
                    # The ball covered for a frame or two, its label kept: the
                    # frames around it say where it is.
                    seen = [(f, x, y, r) for f, balls in enumerate(per_frame) for x, y, r, k in balls or [] if k == IN_PLAY]
                    for f, x, y, r in random.sample(seen, min(len(seen), random.randint(1, 2))):
                        cover(clip[f], x, y, max(r, 2) * random.uniform(1.2, 2.5), max(r, 2) * random.uniform(1.2, 2.5))
                if random.random() < 0.3:
                    # Look-alike blobs where there's no ball.
                    for _ in range(random.randint(1, 3)):
                        cover(clip[random.randrange(SEQ)], random.uniform(0, W), random.uniform(0, H),
                              random.uniform(2, 8) * W / BASE_WIDTH, random.uniform(2, 8) * W / BASE_WIDTH)
        if self.color:
            # Frame by frame, R G B: (9, H, W, 3) → (27, H, W).
            clip = clip.transpose(0, 3, 1, 2).reshape(SEQ * 3, H, W)
        clip = np.ascontiguousarray(clip, dtype=np.float32)

        heat = np.zeros((SEQ, H, W), np.float32)
        weight = np.zeros((SEQ, H, W), np.float32)
        radius = np.zeros((SEQ, 2), np.float32)  # (radius as a fraction of width, has a ball)
        for f, balls in enumerate(per_frame):
            if balls is None:
                continue
            weight[f] = 1
            for x, y, r, kind in balls:
                d2 = (self.xs - x) ** 2 + (self.ys - y) ** 2
                if kind == IN_PLAY:
                    heat[f] = np.maximum(heat[f], np.exp(-d2 / (2 * self.sigma ** 2)))
                elif kind == RESTING:
                    weight[f][d2 <= max(3 * self.sigma, 1.5 * r + 2) ** 2] = 0
                elif self.occluded:
                    heat[f] = np.maximum(heat[f], OCCLUDED_PEAK * np.exp(-d2 / (2 * (2 * self.sigma) ** 2)))
            in_play = [r for _, _, r, k in balls if k == IN_PLAY]
            if in_play:
                radius[f] = (max(in_play) / W, 1)
        # Scoring looks at the target frame's balls: (x, y, kind).
        centres = np.full((8, 3), -1, np.float32)
        for k, (x, y, _, kind) in enumerate((per_frame[index] or [])[:8]):
            centres[k] = (x, y, kind)
        return (torch.from_numpy(clip), torch.from_numpy(heat), torch.from_numpy(weight), index,
                torch.from_numpy(radius), torch.from_numpy(centres), i)


def cover(frame, x: float, y: float, rx: float, ry: float) -> None:
    """Paint an ellipse over (x, y) in the colour around it, a little noisy."""
    H, W = frame.shape[:2]
    x0, x1 = int(max(0, x - 2 * rx)), int(min(W, x + 2 * rx + 1))
    y0, y1 = int(max(0, y - 2 * ry)), int(min(H, y + 2 * ry + 1))
    if x1 <= x0 or y1 <= y0:
        return
    patch = frame[y0:y1, x0:x1]
    ys, xs = np.mgrid[y0:y1, x0:x1]
    inside = ((xs - x) / rx) ** 2 + ((ys - y) / ry) ** 2 <= 1
    if not inside.any() or inside.all():
        return
    fill = patch[~inside].mean(axis=0)
    patch[inside] = np.clip(fill + np.random.normal(0, 0.02, patch[inside].shape), 0, 1)


def seed_worker(_):
    np.random.seed(torch.initial_seed() % 2 ** 32)


# MARK: - Scoring

def peaks(heat, threshold=0.5) -> list[tuple[float, float]]:
    """Centroids of the blobs above threshold, as the author's decoder does."""
    binary = (heat >= threshold).astype(np.uint8)
    n, _, stats, centroids = cv2.connectedComponentsWithStats(binary, connectivity=8)
    return [tuple(centroids[k]) for k in range(1, n) if stats[k, cv2.CC_STAT_AREA] >= 2]


def predictions(model, loader, device):
    """(window, peaks, balls) per window of `loader`, on its target frame;
    balls are (x, y, kind)."""
    model.eval()
    with torch.no_grad():
        for clip, _, _, index, _, centres, ids in loader:
            out = model(clip.to(device, non_blocking=True))
            heat = out[torch.arange(len(index)), index.to(device)].float().cpu().numpy()
            for b in range(len(index)):
                yield int(ids[b]), peaks(heat[b]), [(c[0], c[1], int(c[2])) for c in centres[b].numpy() if c[0] >= 0]


def match(found, truth, tau: float, scale: float) -> dict[str, int]:
    """Balls in play: hits, misses, false alarms. A peak on a resting ball, or
    near an occluded one (where it must be, roughly), is neither."""
    t = dict.fromkeys(("tp", "fp", "fn", "resting_hit", "resting_missed", "occluded_hit", "occluded_missed"), 0)
    unmatched = [u for u in truth if u[2] != OCCLUDED]
    occluded = [u for u in truth if u[2] == OCCLUDED]
    for p in found:
        hit = min(unmatched, key=lambda u: math.dist(p, u[:2]), default=None)
        if hit and math.dist(p, hit[:2]) * scale <= tau:
            unmatched.remove(hit)
            t["tp" if hit[2] == IN_PLAY else "resting_hit"] += 1
            continue
        near = min(occluded, key=lambda u: math.dist(p, u[:2]), default=None)
        if near and math.dist(p, near[:2]) * scale <= OCCLUDED_TAU:
            occluded.remove(near)
            t["occluded_hit"] += 1
        else:
            t["fp"] += 1
    for u in unmatched:
        t["fn" if u[2] == IN_PLAY else "resting_missed"] += 1
    t["occluded_missed"] += len(occluded)
    return t


def rates(t: dict[str, int]) -> dict:
    p = t["tp"] / max(1, t["tp"] + t["fp"])
    r = t["tp"] / max(1, t["tp"] + t["fn"])
    return {"precision": round(p, 4), "recall": round(r, 4), "f1": round(2 * p * r / max(1e-9, p + r), 4),
            "resting_recall": round(t["resting_hit"] / max(1, t["resting_hit"] + t["resting_missed"]), 4),
            "occluded_recall": round(t["occluded_hit"] / max(1, t["occluded_hit"] + t["occluded_missed"]), 4), **t}


def score(model, loader, val_windows, device, width: int, dead_loader=None) -> dict:
    """Balls in play: recall, precision, F1 (overall, per surface, tracked
    vs sampled), with a 90% range from resampling whole videos — how much
    the score could move with different val videos. With `dead_loader`,
    how often it fires when no rally is on."""
    tallies: dict[str, dict[str, int]] = {}
    per_clip: dict[tuple[str, str], dict[str, int]] = {}
    scale = BASE_WIDTH / width
    for i, found, truth in predictions(model, loader, device):
        w = val_windows[i]
        kind = "tracked" if "labels" in w else "sampled"
        for tau in (4, 8):
            m = match(found, truth, tau, scale)
            keys = [f"{environment(w['clip'])}@{tau}", f"all@{tau}", f"{kind}@{tau}"]
            for key in keys:
                t = tallies.setdefault(key, dict.fromkeys(m, 0))
                for k, v in m.items():
                    t[k] += v
            if tau == 4:
                for group in ("all", kind):
                    t = per_clip.setdefault((group, w["clip"]), dict.fromkeys(m, 0))
                    for k, v in m.items():
                        t[k] += v
    result = {key: rates(t) for key, t in sorted(tallies.items())}
    rng = np.random.default_rng(0)
    for group in ("all", "tracked", "sampled"):
        clips = [t for (g, _), t in per_clip.items() if g == group]
        if len(clips) < 2 or f"{group}@4" not in result:
            continue
        f1s = []
        for _ in range(1000):
            pick = [clips[k] for k in rng.integers(0, len(clips), len(clips))]
            f1s.append(rates({k: sum(c[k] for c in pick) for k in pick[0]})["f1"])
        result[f"{group}@4"]["f1_range"] = [round(float(np.percentile(f1s, 5)), 4), round(float(np.percentile(f1s, 95)), 4)]
        result[f"{group}@4"]["videos"] = len(clips)
    if dead_loader is not None:
        fires = [len(found) for _, found, _ in predictions(model, dead_loader, device)]
        result["dead"] = {"windows": len(fires), "fires_per_window": round(sum(fires) / max(1, len(fires)), 4),
                          "windows_with_a_fire": round(sum(1 for f in fires if f) / max(1, len(fires)), 4)}
    return result


def show(title: str, metrics: dict) -> None:
    say(f"\n{title}")
    say(f"   {'':10} {'in play: recall':>15} {'precision':>9} {'F1':>6}  {'90% range (videos)':>20}  {'resting':>8} {'occluded':>8}"
        f"   (4 px · 8 px recall/precision)")
    for env in ("all", "beach", "grass", "indoor", "tracked", "sampled"):
        a, b = metrics.get(f"{env}@4"), metrics.get(f"{env}@8")
        if a:
            spread = f"{a['f1_range'][0]:.3f}–{a['f1_range'][1]:.3f} ({a['videos']})" if "f1_range" in a else ""
            say(f"   {env:10} {a['recall']:15.1%} {a['precision']:9.1%} {a['f1']:6.3f}  {spread:>20}  "
                f"{a['resting_recall']:8.1%} {a['occluded_recall']:8.1%}   · {b['recall']:.1%} / {b['precision']:.1%}")
    if "dead" in metrics:
        d = metrics["dead"]
        say(f"   no rally on: fires on {d['windows_with_a_fire']:.1%} of {d['windows']} frames ({d['fires_per_window']:.2f} peaks each)")


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
    p.add_argument("--color", action="store_true",
                   help="Colour frames (27 channels: 9 frames × RGB) instead of grey; channel shuffles and "
                        "saturation changes in training so it can't learn one ball's colours")
    p.add_argument("--aug", action="store_true",
                   help="Phone-footage augmentation: hand-held shake, zoom in/out, a ball covered for a frame or two, "
                        "look-alike blobs, heavy compression")
    p.add_argument("--occluded", action="store_true",
                   help="A ball hidden between two sightings is a faint target where it must be, not \"no ball\" "
                        "(needs a package with \"occluded\")")
    p.add_argument("--qfl", action="store_true",
                   help="Quality focal loss (WASB): each pixel weighed by how far it is from its target, not by the "
                        "prediction alone — matters on the soft edge of the ball's blob")
    p.add_argument("--mine", action="store_true",
                   help="Hard example mining: every few epochs, find the train windows it gets wrong and draw "
                        "them more often")
    p.add_argument("--seed", type=int, default=None, help="Fix the randomness (to compare runs fairly, or see the noise)")
    args = p.parse_args()
    if args.seed is not None:
        random.seed(args.seed)
        np.random.seed(args.seed)
        torch.manual_seed(args.seed)

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
    train_w, val_w, dead_w = load_windows(root)
    say(f"{len(train_w)} train · {len(val_w)} val windows "
        f"({sum(1 for w in val_w if w['balls'])} val with a ball) from {root.name}")
    tracked = sum(1 for w in train_w + val_w if "labels" in w)
    rallies = len({(w["clip"], w["split"]) for w in train_w + val_w if "labels" in w})
    say(f"{tracked} windows from tracked rallies in {rallies} videos"
        + ("" if tracked else " — none: is this an old package? Track rallies and re-export to use them."))
    occluded = sum(1 for w in train_w for b in w.get("occluded") or [] if b is not None)
    say(f"{occluded} occluded-ball frames in train windows" + ("" if occluded or not args.occluded else
        " — none: --occluded does nothing (re-export the package)"))
    say(f"{len(dead_w)} dead-time windows (scored, not trained on)" if dead_w else
        "No dead-time windows: mark every rally in a few videos (Track → Rally times → Whole video marked) to score "
        "how often it fires when no rally is on.")
    say("Options: " + (", ".join(k for k in ("aug", "occluded", "qfl", "mine") if getattr(args, k)) or "none")
        + (f", seed {args.seed}" if args.seed is not None else ""))
    sampler = torch.utils.data.WeightedRandomSampler(torch.ones(len(train_w), dtype=torch.double), len(train_w)) \
        if args.mine else None
    loader = lambda ws, train, aug=False: torch.utils.data.DataLoader(
        Windows(root, ws, train, size, color=args.color, aug=aug, occluded=args.occluded), batch_size=batch,
        shuffle=train and sampler is None, sampler=sampler if train else None, num_workers=args.workers,
        pin_memory=device.type == "cuda", drop_last=train, persistent_workers=args.workers > 0, worker_init_fn=seed_worker)
    train_loader, val_loader = loader(train_w, True, args.aug), loader(val_w, False)
    dead_loader = loader(dead_w, False) if dead_w else None
    # The train windows as val sees them (no augmentation, the target mid-window): for mining.
    mine_loader = loader(train_w, False) if args.mine else None

    say(f"Input {size[0]}×{size[1]}, batch {batch}.")
    channels = SEQ * 3 if args.color else SEQ
    say("Colour frames (9 × RGB)." if args.color else "Grey frames.")
    model = color_model(VballNetV4c, size) if args.color else VballNetV4c(height=size[1], width=size[0], in_dim=SEQ, out_dim=SEQ)
    if not args.from_scratch:
        load_author_weights(model)
    model.to(device)

    run = HERE / "runs" / "heatmap" / args.name
    if run.exists():
        fail(f"{run} exists — pass a new --name (or delete it).")
    run.mkdir(parents=True)
    metrics = {"package": root.name, "size": list(size), "from_scratch": args.from_scratch, "color": args.color,
               "aug": args.aug, "occluded": args.occluded, "qfl": args.qfl, "mine": args.mine, "seed": args.seed,
               "baseline": None, "best": None, "best_epoch": None}

    if not args.from_scratch:
        metrics["baseline"] = score(model, val_loader, val_w, device, size[0], dead_loader)
        show("The author's weights, untouched, on your val windows:", metrics["baseline"])

    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    # torch.amp.GradScaler is torch ≥ 2.3; older builds have the cuda one.
    scaler = (torch.amp.GradScaler("cuda", enabled=device.type == "cuda") if hasattr(torch.amp, "GradScaler")
              else torch.cuda.amp.GradScaler(enabled=device.type == "cuda"))
    best_f1 = -1.0
    log = [["epoch", "loss", "recall4", "precision4", "f1_4", "f1_4_low", "f1_4_high", "recall8", "f1_8",
            "resting_recall4", "occluded_recall4", "dead_fire_rate", "hard_windows", "seconds"]]
    hard = 0
    for epoch in range(1, args.epochs + 1):
        started, total, batches = time.time(), 0.0, 0
        if args.mine and epoch >= MINE_FROM and (epoch - MINE_FROM) % MINE_EVERY == 0:
            # A window is hard when its target frame's ball in play is missed
            # or something else fires.
            weights = torch.ones(len(train_w), dtype=torch.double)
            for i, found, truth in predictions(model, mine_loader, device):
                m = match(found, truth, 4, BASE_WIDTH / size[0])
                if m["fn"] or m["fp"]:
                    weights[i] = MINE_WEIGHT
            sampler.weights = weights
            hard = int((weights > 1).sum())
            say(f"   mining: {hard} of {len(train_w)} train windows are hard — drawn {MINE_WEIGHT:g}× as often")
        model.train()
        for clip, heat, weight, _, radius, _, _ in train_loader:
            clip, heat = clip.to(device, non_blocking=True), heat.to(device, non_blocking=True)
            weight, radius = weight.to(device, non_blocking=True), radius.to(device)
            with torch.autocast(device_type=device.type, enabled=device.type == "cuda"):
                out = model(clip)
            pred = out[:, :SEQ].float().clamp(1e-7, 1 - 1e-7)
            # The author's weighted BCE, per frame, over the pixels that count
            # (labeled frames, minus the area around resting balls). Quality
            # focal loss weighs each pixel by how far it is from its target —
            # the same on 0/1 targets, different on the Gaussian's slopes.
            if args.qfl:
                wbce = -(heat - pred).abs() ** 2 * (heat * torch.log(pred) + (1 - heat) * torch.log(1 - pred))
            else:
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
        m = score(model, val_loader, val_w, device, size[0], dead_loader)
        a4, a8 = m["all@4"], m["all@8"]
        # Tracked rallies label the ball in play on every frame, so they're the
        # trustworthy score; sampled frames' in-play tags guess from motion.
        judged = m.get("tracked@4", a4)
        low, high = a4.get("f1_range", [None, None])
        log.append([epoch, round(total / max(1, batches), 6), a4["recall"], a4["precision"], a4["f1"], low, high,
                    a8["recall"], a8["f1"], a4["resting_recall"], a4["occluded_recall"],
                    m.get("dead", {}).get("windows_with_a_fire"), hard, round(time.time() - started)])
        say(f"epoch {epoch:3}/{args.epochs}  loss {total / max(1, batches):.5f}  "
            f"in play: F1 {a4['f1']:.3f} (recall {a4['recall']:.1%}, precision {a4['precision']:.1%})  "
            f"@8px {a8['f1']:.3f}"
            + (f"  · tracked F1 {judged['f1']:.3f} (recall {judged['recall']:.1%})" if "tracked@4" in m else "")
            + (f"  · occluded {a4['occluded_recall']:.1%}" if a4["occluded_hit"] + a4["occluded_missed"] else "")
            + (f"  · no rally: fires {m['dead']['windows_with_a_fire']:.1%}" if "dead" in m else "")
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
    torch.onnx.export(model, (torch.zeros(1, channels, size[1], size[0]),), str(run / "best.onnx"), opset_version=17,
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
