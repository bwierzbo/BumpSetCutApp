---
id: EXP-20261031-net-model-v1
status: planned — not approved, not run (the dataset is not labeled yet)
created: 2026-10-31T03:44:39Z
updated: 2026-10-31T15:55:47Z
decision: owner direction 2026-10-30 (verbatim: ../../decisions/2026-10-30-net-model-direction.md); D-002, D-017, D-018 honoured; the decision that removes net.mlpackage is logged by the PR that removes it
roadmap_phase: net model replacement (licensing, 2026-10-09; plan: ../NET_MODEL_PLAN.md)
pr: feat/net-trainer (the trainer); the run's own PR carries the results
issue: n/a
---

# EXP-20261031-net-model-v1 — first net detector from scratch, no Ultralytics

**Status: planned.** Written before any run, as the template asks. Nothing here has been trained. The run needs, in order: PR #111 merged and the 138 eligible recordings labeled in RallyLab's Net labels tab; the export (`RallyLab --project Scratch --export-net-dataset <staging>/Scratch-net-<stamp>`) and its ledger rows; the Roboflow version exported with a `provenance.json`; the owner's approval of this record with the frozen inputs filled in. The frozen-input rows below are `to be filled on approval` until then — never a value that was not measured.

## Hypothesis

- **H1 (the gates' needs, our recordings).** On the grouped validation frames of our own recordings, the from-scratch model's **median top error — the two tape ends' vertical error, mean of the two — is at most 0.02 of the frame height** and the **median left- and right-edge errors of the box its corners span are at most 0.05 of the frame width** (the off-court gate's margin), with a **detect rate of at least 0.95** at presence 0.5. The label is the net's four corners (owner, 2026-10-31; plan §2) and the model predicts them; the top edge of the box they span is what the above-net gate reads with no margin (`aboveNetMarginY` 0); 0.02 H is about 22 px at 1080p, the thickness of the tape band the top corners are placed on. The corner error (mean distance of the four corners, frame fractions) is reported with no bar preregistered: the gates read only the box the corners span. If H1 fails on a surface, that surface's number is reported and the model is not a candidate for the gates until it passes.
- **H2 (exploratory: does the Roboflow data help?).** Two runs on the **same** `split.json`, one on our frames alone, one with `--extra` (the Roboflow net boxes, provenance recorded), compared frame by frame on the same val frames: the difference in median top error is reported with the per-group 90 % range from resampling. No direction is preregistered; an interval that includes zero means the two were not told apart on this many groups, not that they are equal.
- **Not a hypothesis here:** the comparison with the old `net.mlpackage` on the pipeline's gates. That is the replacement PR's diagnostic (the Swift side, both detectors on the same recordings, the gates' outcomes), and it decides whether `net.mlpackage` can leave; this record decides only whether the model is worth that diagnostic.

## Inputs (frozen)

| Input | Value |
|---|---|
| Code SHA | to be filled on approval (the merged head that holds `scripts/desktop_training/train_net_model.py`, `net_to_coreml.py`, `scripts/tests/test_train_net_model.py`) |
| Dataset | the `--export-net-dataset` folder: name, `net-dataset.json` SHA-256, labeled count, skipped (withheld / handheld / unidentified / unlabeled) counts — to be filled on approval |
| Dataset manifest SHA-256 | `manifests/manifest.json` of Scratch at export time — to be filled on approval (the trainer records it in `metrics.json` as `manifest_sha256`) |
| Split ID / version | the manifest's split definitions at export time; validation = whole recording groups per surface, `--val-fraction 0.25`, drawn with `--seed 0`, written to `runs/net/net_v1/split.json` and reused by every later run with `--split` |
| Label set version(s) | net boxes: one person-confirmed box per recording (`net-labels.json`; proposals from the old model are marked `proposed`, never a label without confirmation) — no versioned ID yet (D-009 work) |
| Withheld | the 21 withheld recordings (lineage holdout 16 + legacy holdout 5) and every alias: refused by the export and refused again by the trainer against the manifest (`split`, `reservedAs`, fingerprint); handheld (8) not labeled (plan §3) |
| Extra data (H2 only) | Roboflow `bumpsetcut/volleyball-ykkmn-grgwy`, the version exported in YOLO format, with `provenance.json` (source, licence, obtained, note) — version, image count, net-box count and licence to be filled on approval; train only, never val |
| Control model | none in H1 (a from-scratch model against the gates' thresholds); in H2 the run without `--extra` |
| Treatment model(s) | `net_v1` (our frames); `net_v1_extra` (our frames + Roboflow) — `best.pt` and `best.onnx` SHA-256s recorded by the trainer |
| Pipeline config SHA-256 | n/a (no pipeline run in this record) |
| Trainer / converter versions | `train_net_model.py` and `net_to_coreml.py` at the code SHA; torch (desktop .venv) and coremltools (Mac, `~/.venvs/heatconv`, 9.0) versions to be filled from `metrics.json` |
| Seeds | 0 for the split, initialisation and augmentation; a second seed only if authorised |
| Compute | the desktop GPU over SSH (`bens-desktop`); wall time to be filled |

## Procedure

Exactly as to be run (desktop paths as `desktop.sh` uses them; `desktop.sh` itself drives only the heat trainer, so the net trainer is started by hand the same way, detached, with its log beside it):

```
# on the desktop, in C:\BallTraining (the trainer and the dataset copied there first)
python train_net_model.py D:\RallyLabStaging\Scratch-net-<stamp> --manifest D:\RallyLabStaging\Scratch-net-<stamp>\manifest.json --seed 0 --name net_v1
python train_net_model.py D:\RallyLabStaging\Scratch-net-<stamp> --manifest ... --split runs\net\net_v1\split.json --extra D:\RallyLabStaging\roboflow-net-v<N> --seed 0 --name net_v1_extra
# on the Mac, in ~/.venvs/heatconv
python scripts/desktop_training/net_to_coreml.py bring_back/net_v1 <out>/net_v1.mlpackage
```

Outputs: `runs/net/<name>/` (best.pt, best.onnx, metrics.json, log.csv, split.json) and `bring_back/<name>/` on the desktop; copied back under `~/Movies/RallyLab/Reports/net-v1/` with their SHA-256s listed here. The manifest copied beside the dataset is the one hashed in `metrics.json`.

## Results

not measured (nothing has run)

| | detect rate | top error median / p90 (H) | left / right median (W) | corner error median | IoU | 90 % range of the median (groups) |
|---|---|---|---|---|---|---|
| net_v1, all val | not measured | not measured | not measured | not measured | not measured | not measured |
| by surface (beach / grass / indoor) | not measured | not measured | not measured | not measured | not measured | not measured |
| net_v1_extra, same frames (H2) | not measured | not measured | not measured | not measured | not measured | not measured |

## Decision

none yet (planned). On results: keep (the model goes to the replacement PR's Swift-side diagnostic against the old model), revert (change the recipe, new record), or need data (more labeled recordings on the failing surface).

## Test results

The trainer's own tests at the time of writing: `~/.venvs/heatconv/bin/python -m unittest scripts.tests.test_train_net_model` — **17 tests, 0 failures** (12 on the data rules: export checks, the corners being the label and the YOLO box their bounds, withheld refusal, fingerprint and image-hash refusal, YOLO lines, extra-folder provenance and net class, group split, letterbox of boxes and corners, corners under flip and crop, scores, YAML names; 5 on training: a run's record and `--score-only` reproducing it, augmentation fresh each epoch and repeatable, a withheld recording stopping the run before anything is written, a 30-epoch synthetic run whose kept epoch is the best seen, and the Core ML conversion matching PyTorch).
