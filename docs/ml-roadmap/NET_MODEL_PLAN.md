---
name: net-model-plan
status: active
created: 2026-10-30T21:54:35Z
updated: 2026-10-30T22:30:00Z
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

## 4. Training (not started)

A plain-PyTorch trainer in `scripts/desktop_training/` (no Ultralytics import, like `train_heatmap_model.py`): a small from-scratch CNN on a single RGB frame at 384×216 that regresses the net box (centre, size, presence), trained on our frames plus the Roboflow net boxes in separate folders; Core ML through `coremltools` as the heat model is. Validation by recording group; the number that matters is the net's top-edge error in frame heights, since that is what the above-net gate reads. Its own experiment record before it runs.
