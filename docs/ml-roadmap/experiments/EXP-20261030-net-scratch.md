---
id: EXP-20261030-net-scratch
lineage: net (N1, first non-Ultralytics net model)
status: proposed
created: 2026-10-30T02:30:00Z
updated: 2026-10-30T02:30:00Z
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

## 2. What the model predicts — owner decision

| Option | Output | For | Against |
|---|---|---|---|
| **A. Four corners (recommended)** | Heatmaps for the net's 4 corners: tape at the left and right post, mesh bottom at the left and right post | Heatmaps learn well from few recordings (same approach as `ball_heat`); a tilted net is still described; the box the rules use is the corners' extent, so `NetDetector`'s API is unchanged | 4 clicks per label instead of one drag |
| B. Box | One box (x, y, w, h) + presence score | One drag per label; matches today's output exactly | Direct box regression from scratch needs more data to be accurate; no tilt |

## 3. Data and labeling

- **Source:** frames from the Scratch project's recordings on the Mac. No existing person-made net label exists: every stored net box (`SessionMeta.netBox`, the Labeler's live-tag net) came from the YOLO net model, so none is used, not even as a starting box to adjust.
- **Labeling:** RallyLab's Net tab gains a "Mark the net" mode: one frame per recording, four clicks (or one drag for option B), saved on the session with the labeler and date, plus a "camera moved" flag. The net is fixed for a tripod recording, so one label covers the whole video; the tab checks it against a frame near the end and asks again if the net has moved.
- **Effort:** about 140 eligible recordings at roughly 20 seconds each: about 45 minutes, in one or several sittings.
- **Split:** the existing split manifest. dev_val + tune for validation and selection. **Withheld** (`ReservedVideos.reservedNames`): the 16 `lineageHoldout` recordings and the 5 `legacy_holdout`, so the pipeline's holdout evaluation stays clean of a model that saw them. The withholding is enforced in the packager itself (guards live in the shared function), with an exposure-ledger row per recording at export.
- **Package:** `RallyLab --project Scratch --package-net` writes K = 20 frames per labeled recording, spread over the middle 90%, as JPEG at 1280 px, with `labels.json` (corners in Vision-normalised coordinates), the split, and `net-manifest.json` with the SHA-256 of every file and a preflight (every withheld recording absent, every label person-made). About 2,800 frames, well under 1 GB.

## 4. Model

- A small U-Net written in this repo (`scripts/desktop_training/net_model.py`): 4 down / 4 up stages, 16→128 channels, about 1–2 M parameters, 512×288 RGB in, 4 heatmaps out at 128×72 (option A) or a box head (option B). Random init. Its only dependency is PyTorch (BSD-3).
- Portrait frames are turned a quarter turn first, as the ball model does.

## 5. Training (Windows desktop, RTX 3060)

- `scripts/desktop_training/train_net_model.py <package>`: Gaussian targets (sigma 2 px at 128×72), focal loss; augmentation: colour jitter, blur, JPEG, ±10% scale and shift, small rotation, horizontal flip with left and right swapped. 60 epochs, batch 32, AdamW, cosine schedule, seed 20261030, one run. Checkpoint selection on dev_val + tune only, by the H1 pass rate.
- Expected time: under an hour on the 3060. It waits until the L2 ball run (`l2_scratch_768_color_s20261021`) is no longer using the GPU.
- Outputs follow the ball trainer: `runs/net/<name>/` and `bring_back/<name>/` (best.pt, metrics.json with per-recording errors, log.csv).

## 6. Core ML export and integration

- `scripts/desktop_training/net_to_coreml.py` (Mac): FP16 ML program, input `image` [1, 3, 288, 512], output `maps`; metadata `kind = net-corners`, the package digest and the scores. Checked against PyTorch (max heatmap difference ≤ 0.05) before use.
- The new package is `net_corners.mlpackage`, a member of BumpSetCut, RallyLab and the Labeler. `NetDetector` decodes the four peaks into the same `(rect, confidence)` it returns today (confidence = mean peak), so `VideoProcessor`, `BallNetSampler`, `LiveTagger` and the gates don't change. Its YOLO decoding path goes; `net.mlpackage` stays in RallyLab only for the H2 comparison and is then removed.
- Before merge: build both targets, RallyLabTests, H1/H2 results in the PR, and one beach and one grass video on the iPhone showing the net band in Debug Processing.

## 7. Open owner decisions

1. Output: four corners (A) or a box (B).
2. Approval of this record before the package goes to the trainer (D-014 PR review applies to the model and the code).
