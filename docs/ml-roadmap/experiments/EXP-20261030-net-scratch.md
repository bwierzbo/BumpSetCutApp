---
id: EXP-20261030-net-scratch
lineage: net (N1, first non-Ultralytics net model)
status: proposed
created: 2026-10-30T02:30:00Z
updated: 2026-10-30T15:45:00Z
approved_by: not yet
decision: D-012 (no Ultralytics weights ship); a new decision entry records the owner's choices below
pr: n/a (plan only; code follows on this branch)
---

# EXP-20261030-net-scratch — a from-scratch net model for the court-geometry rules

## 0. Why

`net.mlpackage` is YOLO26n (AGPL-3.0) and leaves the public app with PR #108 (D-012). Without it the iPhone skips three rules that RallyLab still applies: off-court rejection (net post span, before tracking), under-net rejection (net bottom) and the above-net requirement (net top), and loses `netCenterX` for side-on serve scoring. The owner chose on 2026-10-30 to train our own net model instead of turning the rules off.

## 1. Objective and hypotheses

Replace `net.mlpackage` with a model whose code and weights are ours: random initialisation, no Ultralytics code, no pretrained backbone, labels drawn by a person.

- **H1 (geometry).** On the val recordings, the new model's per-video net (median over 12 sampled frames, as `VideoProcessor.sampleNetAcrossVideo` does now) is within 2% of frame width on each post and 2% of frame height on top and bottom edges of the person-drawn net on at least 90% of recordings. False if fewer than 80% pass, or any surface (beach / grass / indoor) is under 70%.
- **H2 (pipeline parity).** RallyLab rally scoring on dev_val + tune with the new net is no worse than with `net.mlpackage` (same config, paired by recording). The YOLO net is used here only as an internal comparison, which D-012 allows.
- **Not claimed:** generalisation to venues outside the project's footage. The net rules stay off for corner and sideline cameras, as today (`CameraSetup` zone).

## 2. What the model predicts — set by the labels

The owner has a large set of labeled nets on Roboflow (2026-10-30) and will train on it. Its label kind decides the output; `get_net_dataset.py` reports it (`labelKinds` in `manifest.json`):

| Labels | Output | Notes |
|---|---|---|
| Polygons (outlines) | Heatmaps for the net's 4 corners, taken from each outline's extreme points | Tilt-aware; the rules' box is the corners' extent |
| Boxes | Heatmaps for the box's 4 corners (same network and head) | No tilt, which today's YOLO net doesn't give either |
| Mixed | Corners from outlines where drawn, from boxes elsewhere | |

Either way `NetDetector` returns the same `(rect, confidence)`, so the rules and their callers don't change.

## 3. Data

- **Training data: the owner's Roboflow net dataset**, exported as **COCO JSON** (not the "YOLO" format, to keep Ultralytics out of every step; the format itself isn't licensed code). `scripts/desktop_training/get_net_dataset.py` fetches it with the owner's own `ROBOFLOW_API_KEY` on the desktop, or reads a COCO zip he exported from the website, then keeps only the net class, keeps one image per original (Roboflow's augmented copies dropped, across splits too), un-stretches square exports to 16:9, and writes `labels.json` plus `manifest.json` with the origin, licence, counts and the SHA-256 of every file. It uses the standard library, Pillow and, for the download only, the `roboflow` package (Apache-2.0).
- **To confirm before training (owner):** the project is his own (not a Universe copy; if it includes Universe images, each one's licence is recorded, as `get_extra_datasets.py` does for the ball sets), and the nets were drawn by a person, not auto-labeled by a model (D-023's people-only rule, applied here too).
- **Withheld recordings:** if any image was cut from the Scratch project's recordings, the 16 `lineageHoldout` and 5 `legacy_holdout` recordings are left out with `--exclude <names.txt>` (matched against each image's original file name), so the pipeline's holdout evaluation stays clean. The count left out is in the manifest.
- **Validation on our own footage:** Roboflow's images may not look like an endline phone recording, so H1 is scored on the Scratch project's dev_val + tune recordings (13) with a net drawn by a person on one frame of each in RallyLab's Net tab: about 5 minutes. No stored net box is used: every one came from the YOLO net model. The 140-recording labeling pass is dropped unless the val score shows the Roboflow set doesn't cover our footage.

## 4. Model

- A small U-Net written in this repo (`scripts/desktop_training/net_model.py`): 4 down / 4 up stages, 16→128 channels, about 1–2 M parameters, 512×288 RGB in, 4 heatmaps out at 128×72 (option A) or a box head (option B). Random init. Its only dependency is PyTorch (BSD-3).
- Portrait frames are turned a quarter turn first, as the ball model does.

## 5. Training (Windows desktop, RTX 3060)

- `scripts/desktop_training/train_net_model.py <net_dataset folder>`: Gaussian targets (sigma 2 px at 128×72), focal loss; augmentation: colour jitter, blur, JPEG, ±10% scale and shift, small rotation, horizontal flip with left and right swapped. 60 epochs, batch 32, AdamW, cosine schedule, seed 20261030, one run. Checkpoint selection by the H1 pass rate on the 13 drawn val recordings (frames sampled from each), never the holdouts; Roboflow's own valid split is reported too.
- Expected time: under an hour on the 3060. It waits until the L2 ball run (`l2_scratch_768_color_s20261021`) is no longer using the GPU.
- Outputs follow the ball trainer: `runs/net/<name>/` and `bring_back/<name>/` (best.pt, metrics.json with per-recording errors, log.csv).

## 6. Core ML export and integration

- `scripts/desktop_training/net_to_coreml.py` (Mac): FP16 ML program, input `image` [1, 3, 288, 512], output `maps`; metadata `kind = net-corners`, the package digest and the scores. Checked against PyTorch (max heatmap difference ≤ 0.05) before use.
- The new package is `net_corners.mlpackage`, a member of BumpSetCut, RallyLab and the Labeler. `NetDetector` decodes the four peaks into the same `(rect, confidence)` it returns today (confidence = mean peak), so `VideoProcessor`, `BallNetSampler`, `LiveTagger` and the gates don't change. Its YOLO decoding path goes; `net.mlpackage` stays in RallyLab only for the H2 comparison and is then removed.
- Before merge: build both targets, RallyLabTests, H1/H2 results in the PR, and one beach and one grass video on the iPhone showing the net band in Debug Processing.

## 7. Open owner decisions

1. The Roboflow workspace, project and version, and whether its nets were drawn by a person.
2. Approval of this record before the dataset goes to the trainer (D-014 PR review applies to the model and the code).
