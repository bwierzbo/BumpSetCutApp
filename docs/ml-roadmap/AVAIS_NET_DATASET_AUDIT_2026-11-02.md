---
name: avais-net-dataset-audit-2026-11-02
status: closed — dataset rejected by the owner; local data and Roboflow fork deleted; nothing trained
created: 2026-11-02T23:12:56Z
updated: 2026-11-03T02:18:32Z
decisions: owner direction 2026-11-02 on PR #132 §F.4 ("We should not have any overlapping go ahead and use it"); owner, after viewing it: "this dataset wont do us any good it doesnt give us anything its the same annotated net for almost every single frame" (rejected; "delete the avais files"); D-002, D-017, D-018 honoured
roadmap_phase: net model replacement (NET_MODEL_PLAN.md)
---

# Avais Beach Volleyball: audited and rejected

On 2026-11-02 the Roboflow Universe dataset `avais-beach-volleyball/beach-volleyball-tt2vj` (CC BY 4.0, 636 images, classes Player / Volleyball / Volleyball Net) was audited as a candidate source of extra net boxes. The steps:
- forked to `bumpsetcut/beach-volleyball-tt2vj-zia7d`, source untouched;
- version 1 generated (auto-orient only, no augmentation);
- exported as YOLOv8 (zip SHA-256 `4100d851560f404e26888fdadd8d7bfdf7ac3faa4af68d91b6d83f27dc686c72`);
- packaged with the new `scripts/desktop_training/prepare_external_net_dataset.py`.

After looking at it, **the owner rejected it**, and the downloaded export and package were deleted from the Mac and the desktop staging share. **Nothing was trained.** On the owner's word ("go ahead and delete avais"), the Roboflow fork was deleted the same day; Roboflow keeps it in the workspace Trash for 30 days.

## Why it was rejected

- **One example, repeated.** 634 of 636 images are frames from one fixed ground-level camera behind an end line at one event: the FIVB World Tour Olsztyn Grand Slam centre court, identified from the boards (OLSZTYN GRAND SLAM, WARMIA MAZURY, ORLEN). The frames come from two videos, `2016_01_04-09_07-4797.mp4` (619) and `f.mp4` (15). The net box is the same in every frame: its robust SD is about 0.003 of the frame, at width 0.478 or 0.508 for the two framings. For a net detector that is one recording group's worth of geometry, not 636 examples.
- **The box is not our label.** Checked at full resolution on 12 seeded frames:
  - the top edge sits on the tape;
  - the left and right edges sit on the net's vertical side bands, about 0.035–0.04 of the frame width inside each post.

  Our corners run post to post, so these boxes could not teach the sides or corners.
- **The rest:**
  - two screen captures of other people's videos (a Gstaad Major TV broadcast, and a BVNE Santa Monica YouTube video in Chrome);
  - one frame (0157) with a second "net" box drawn on a player;
  - 40 frames as similar to a kept frame as a re-encoded copy.

## What the audit established (kept for the record)

- **Counts:** 637 net boxes, all axis-aligned. 0 negatives, 0 out-of-frame boxes, 0 exact duplicates. The Universe listing's "1,007 net annotations" counts annotations that are not on the dataset's images; the export has 637.
- **Duplicates against data we use:** none, exact or near. That covers the 547 `volleyball-ykkmn-grgwy` photos and our 129 confirmed net frames; the best match was 0.81 similarity, against 0.96 or more between any two frames of the Olsztyn camera.
- **Protected footage:** checked by metadata only, never opened. The suspected overlap with the withheld `bch_onl_sun_land_onl_03` (and `_v2`) is ruled out. That recording is a pick-up game at Alki Beach, Seattle, played on 2026-07-09; the Universe project was last updated on 2025-01-01. No withheld recording's title, uploader or venue names FIVB, Olsztyn, Poland or Gstaad.
- **Model exposure:** only Avais images were shown to a model (Claude, in this session). None of our recordings' frames were, so no exposure-ledger row was due.

## What carries over

- **`scripts/desktop_training/prepare_external_net_dataset.py`** (tests: `scripts/tests/test_prepare_external_net_dataset.py`, 16). It audits an external YOLO net export and writes a training-only, net-only package that `train_net_model.py --extra` reads. Its checks:
  - every image must belong to a declared source group;
  - per-image quarantine decisions;
  - label checks;
  - exact (file and pixel SHA-256) and near duplicates, by aligned thumbnail correlation with a threshold calibrated on synthetic copies;
  - duplicates against comparison folders, behind a withheld-name guard that refuses before any image is opened.

  The package is written atomically, `verify` re-checks every hash, and a rebuild is byte-identical on any platform.
- **Two lessons for the next external dataset:**
  - Count cameras and events, not images.
  - Check what the box covers against our corner rule before letting box-only data supervise sides or corners. The `volleyball-ykkmn-grgwy` polygons already in use have not had that check.
- **Candidates not yet inspected** (from the 2026-11-02 provenance audit, PR #132): `osloos/volleyball-court-and-net` (732 images, segmentation) and `volleyball-wpxi9/volleyball-uhflr` (1,018 images, segmentation). Masks give the net's outline; camera and event variety is the first thing to check.
