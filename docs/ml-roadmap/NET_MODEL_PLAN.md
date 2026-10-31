---
name: net-model-plan
status: active
created: 2026-10-30T21:54:35Z
updated: 2026-10-31T03:44:39Z
decisions: D-002, D-017, D-018 (exclusions honoured); owner direction 2026-10-30 (verbatim: ../decisions/2026-10-30-net-model-direction.md)
---

# The net model: dataset, training and the Ultralytics removal

## 1. What the net is for

`VideoProcessor` samples the net once per video (eight frames over the middle 90 %, the median box) and uses it in two gates that are **on by default**: off-court rejection (`enableOffCourtRejection`, the court's x-range from the net box) and the above-net requirement (`enableAboveNetRequirement`, the net's top edge). RallyLab's Net and Phase 1 tabs and the Labeler's live tagger use the same detector. The box is `DetectedNet(box:confidence:)`, Vision-normalised; the model only has to find one stationary, large object.

The bundled `net.mlpackage` is an Ultralytics YOLO26n (trained 2026-06-19, 640×640, class `net`), so under the licensing decision of 2026-10-09 it cannot ship in the public app. The owner's direction of 2026-10-30: the replacement is **not** an Ultralytics model, and `net.mlpackage` leaves the code base.

**Removal timing (recommendation, for the owner).** Without a net model `detectedNet` is nil and both gates silently stop applying, on tuner settings that were tuned with them on. Remove `net.mlpackage`, `NetDetector`'s YOLO decode and the two pbxproj entries in the PR that lands the replacement, so production never runs without a net. (`YOLORawDecode` stays while RallyLab's ball YOLO models remain; those are a separate pre-launch removal.)

## 2. The dataset

One upright frame per recording, labeled by hand in RallyLab's **Net labels** tab (`NetLabelsView`, `NetLabelsModel`, `NetLabels.swift`):

- **Frame:** the middle of the recording's first marked rally at least 2 s long (the court in play, nobody standing in front of the net), else the middle of the video. ← / → move a second either way if that frame is poor.
- **Box:** where the old model finds the net its box is pre-drawn as a *proposal* (dashed); the person confirms it, moves or resizes it, or draws one. The label records whether it started as a proposal and whether it was adjusted. Only a person's confirmation makes a label, and only for the frame on screen: while a stepped frame is still decoding, confirming is refused, and the saved time is the decoded frame's.
- **Exposure:** the proposal is a model run on the recording, so it is a use. Before the old model runs, the tab writes a `net_proposal` row to the exposure ledger (ref "Net labels tab", the frame's time in the note); if the row can't be written, the model does not run and the person draws the box. The row stays whether or not a label is confirmed, so a visit that is abandoned is still on record. `net_proposal` is a **new ledger kind** (`ExposureRecord.Kind`), added in PR #111 beside `event_review`; like that one it marks an annotation use, not training or scoring. It is identified here as a protocol addition for the owner's approval with the PR.
- **Identity:** every label carries the recording's file fingerprint (`ReservedVideos.effectiveFingerprint`). A label whose fingerprint is not the file's — a video removed and another added under the same id — is shown as *stale*, not as a label, and the export refuses it. A recording with no fingerprint is skipped as *unidentified*.
- **Skipped, never opened:** the 21 withheld recordings (lineage holdout 16 + legacy holdout 5, by `ReservedVideos.lineageWithheldNames`, fail-closed) — a net model trained on them would change the pipeline on exactly the recordings kept for evaluation — and the 8 handheld recordings (camera "Handheld / …"), whose net moves. Selecting one names the reason; its file is not read, decoded or shown to the old model (a test holds this).
- **Stored** in `<project>/net-labels.json` (video id → label), apart from the sessions the open app re-saves from memory. An unreadable file blocks the tab rather than reading as empty.
- **Exported** with `RallyLab --project Scratch --export-net-dataset <dir>`: `images/<video>.jpg` (the frame decoded again at the label's time; it must come back at the labeled size), `labels/<video>.txt` (YOLO `0 cx cy w h`, top-down), `data.yaml`, `net-dataset.json` (every entry with its box, origin flags, image SHA-256; every skipped recording with its reason). The export is written beside the destination, the exposure-ledger rows (`training_package`, ref = the folder name) are recorded, and only then is the folder moved into place: a use that can't be recorded leaves nothing behind. A withheld recording is refused even if someone labeled it.

Scratch on 2026-10-30: 167 recordings; the 21 withheld and the 8 handheld (disjoint sets) leave **138 to label**. The footage lives on the desktop (`D:\RallyLabFootage\Scratch\footage`); the Mac reads it through the footage share (`scripts/footage_share/mount_shares.sh`, `link_footage.py`), so the tab needs the share mounted.

**The public Roboflow dataset** (`bumpsetcut/volleyball-ykkmn-grgwy`: 547 images at 640×640, classes ball 481 / net 586, no version generated) is a second source. Its images are stretched to square with generic names, so their provenance is unknown; they are kept apart from ours in training (their own folder, their own split), and a model is reported on our frames alone as well as on both.

**Split:** by recording group (clip card / alias / session / venue / uploader, as the split manifest defines them), never by frame — `_v2` copies of a recording share a net.

## 3. Handheld recordings and the training data (asked 2026-10-30)

Question: does handheld footage in the ball detector's training data hurt more than it helps?

Evidence from the first L2 run ([EXP-20261021-l2-scratch-prereg](experiments/EXP-20261021-l2-scratch-prereg.md) §11):

| | |
|---|---|
| Handheld recordings in the L2 train split | 7 of 89 packaged recordings, about 1,190 of 27,069 train windows (4.4 %); three of them contribute no windows |
| The one handheld val recording | `grs_hnd_shade_port_self_02`, 303 balls: F1 **0.927** with L2 (the 12-video mean is 0.914) and 0.900 with L1 |
| Not measured | whether training without them scores higher on fixed-camera footage — that is a second run (about two days of GPU) for a 4 % slice |

Reading: the *detector* copes with camera motion; windows whose background moves are plausibly useful hard examples, and the labels are the owner's own reviewed tracks, so they are not noise. What breaks on handheld footage is after the detector — the tracker's and the physics gates' still-camera assumption, the serve and net geometry — which is why the product can state handheld is unsupported.

Recommendation, pending the owner: keep them in training; report the fixed-camera-only validation number next to the overall one so they can neither flatter nor drag the headline; leave them out of the net dataset (above). No ablation.

## 4. Training (trainer written; no run yet)

The trainer is `scripts/desktop_training/train_net_model.py` (plain PyTorch, no Ultralytics import, like `train_heatmap_model.py`), its converter `net_to_coreml.py`, its tests `scripts/tests/test_train_net_model.py` (17, on a synthetic dataset; the training and conversion ones run on the CPU). The experiment record is [EXP-20261031-net-model-v1](experiments/EXP-20261031-net-model-v1.md), **planned, not approved, not run**.

- **Model:** a small from-scratch CNN (six stride-2 blocks with two coordinate channels, about 1.5 M parameters) on one upright RGB frame letterboxed to 384×216 (scaled to fit, centred, grey borders — portrait recordings keep their shape); nine outputs: presence, and the net's four corners (top-left, top-right, bottom-right, bottom-left; x, y as fractions of the letterboxed frame, y downwards — the label is the corners, §2). The box a consumer needs is the corners' bounds. Core ML through `coremltools` (image input, FP16) as the heat model is; the converter checks the Core ML output against PyTorch before writing.
- **What is scored:** the pipeline reads three things off the box — its top edge (`aboveNetMarginY` is 0, so the top edge is used as is) and its left and right edges (`offCourtMarginX` 0.05 of the frame width). The scores are the top error (the two tape ends' vertical error, mean of the two, in frame heights: median, mean, 90th percentile), the side errors of the corners' box in frame widths, the corner error (mean distance of the four corners, frame fractions), IoU of the boxes, the detect rate at 0.5, by surface and by recording group, with a 90 % range of the median top error from resampling whole groups. The checkpoint kept is the one with the lowest mean top error counting an undetected net as an error of 1. The loss is L1 on the corners where they are known (ours; the tape ends' y twice) plus, on every frame with a net, the box the predicted corners span against the label's box (top edge twice) — which is all an extra image's box can teach.
- **Data and refusals (D-002 in the trainer, again):** the RallyLab export's every entry is checked against the split manifest — present, not withheld (lineage or legacy holdout, final test or candidate, reserved alias), the export's fingerprint the manifest's, every image's SHA-256 the one the export recorded; its four corners must be there (a box-only label from before corners were marked stops the run naming the recording) and the YOLO box must be their bounds; a failure stops the run naming the recording. Validation is whole recording groups per surface (`paired_compare.py`'s grouping), about a quarter of each surface's frames, drawn from the seed and written to `split.json`; `--split` pins another run to the same frames.
- **The Roboflow boxes** go in through `--extra <YOLO folder>`: `net` class only, an image without a net line is a no-net example, and the folder must carry `provenance.json` (source, licence, obtained, note) or it is refused; the provenance is written into `metrics.json`. Extra images have no recording identity, so they only train, never validate. "On our frames alone as well as on both" (§2) is two runs on the same `--split`, with and without `--extra`, compared frame by frame on the same val frames (`per_frame` in each `metrics.json`).
- **Record:** `metrics.json` carries the code SHA, torch version, dataset and manifest digests, the val-frame digest (two runs compare only when it is equal), the seed, the split, the best epoch and its scores, the checkpoint and ONNX SHA-256s; `--score-only` scores a checkpoint on a pinned split without training.
- **Not in this trainer:** running it on the desktop through `desktop.sh` (which drives `train_heatmap_model.py` only; the command is in the record), the new `NetDetector` in Swift, and the removal of `net.mlpackage` — each its own PR, the last only with the tested replacement in hand.
