---
id: EXP-20261031-net-model-v1
status: run — results in, decision pending (owner)
created: 2026-10-31T03:44:39Z
updated: 2026-11-02T09:03:15Z
decision: owner direction 2026-10-30 (verbatim: ../../decisions/2026-10-30-net-model-direction.md); D-002, D-017, D-018 honoured; the decision that removes net.mlpackage is logged by the PR that removes it
roadmap_phase: net model replacement (licensing, 2026-10-09; plan: ../NET_MODEL_PLAN.md)
pr: feat/net-trainer (the trainer); the run's own PR carries the results
issue: n/a
---

# EXP-20261031-net-model-v1 — first net detector from scratch, no Ultralytics

**Status: run 2026-11-02, results below; decision pending the owner.** The owner approved this record on 2026-11-01 ("approve start that up and yes approve the roboflow export its public images we can wait until im back on the home network"). Written before any run, as the template asks; the hypotheses and bars below are unchanged by the approval and by the results. H1 is **not met** (detection passes; the top and side errors are about twice the bars); H2 does not tell the two runs apart. Deviations from the procedure are listed under Results.

## Hypothesis

- **H1 (the gates' needs, our recordings).** On the grouped validation frames of our own recordings, the from-scratch model's **median top error — the two tape ends' vertical error, mean of the two — is at most 0.02 of the frame height** and the **median left- and right-edge errors of the box its corners span are at most 0.05 of the frame width** (the off-court gate's margin), with a **detect rate of at least 0.95** at presence 0.5. The label is the net's four corners (owner, 2026-10-31; plan §2) and the model predicts them; the top edge of the box they span is what the above-net gate reads with no margin (`aboveNetMarginY` 0); 0.02 H is about 22 px at 1080p, the thickness of the tape band the top corners are placed on. The corner error (mean distance of the four corners, frame fractions) is reported with no bar preregistered: the gates read only the box the corners span. If H1 fails on a surface, that surface's number is reported and the model is not a candidate for the gates until it passes.
- **H2 (exploratory: does the Roboflow data help?).** Two runs on the **same** `split.json`, one on our frames alone, one with `--extra` (the Roboflow net boxes, provenance recorded), compared frame by frame on the same val frames: the difference in median top error is reported with the per-group 90 % range from resampling. No direction is preregistered; an interval that includes zero means the two were not told apart on this many groups, not that they are equal.
- **Not a hypothesis here:** the comparison with the old `net.mlpackage` on the pipeline's gates. That is the replacement PR's diagnostic (the Swift side, both detectors on the same recordings, the gates' outcomes), and it decides whether `net.mlpackage` can leave; this record decides only whether the model is worth that diagnostic.

## Inputs (frozen)

| Input | Value |
|---|---|
| Code SHA | `3babef9` (origin/main, PR #126 head). `train_net_model.py` SHA-256 `80c3426ee00ca8b03d6e61cb256e384fbd786985dddc73cc2ee3909286459cfc` and `paired_compare.py` `5d13097912dedc279231f0c526528a52c5bb875c921112d4614e48d3e1916531` on the desktop, checked equal to that commit. `metrics.json` records `code_sha: null` (no git on the desktop) |
| Dataset | `D:\RallyLabStaging\Scratch-net-20261102-0140` (`--export-net-dataset`, 2026-11-02T08:46:05Z), `net-dataset.json` SHA-256 `67d60f666397237dd59bf6fbf7e702db732574a931e204da636d17386c98eedc`; **129 labeled frames** from 74 recording groups (beach 51, grass 50, indoor 28); skipped 38: withheld 21, handheld 8, side view 6, box-only 2, unlabeled 1. 129 `training_package` ledger rows (ref `Scratch-net-20261102-0140`) |
| Dataset manifest SHA-256 | `493dd89ff8e18479d68667a4d62582d5cd1d7fb32711d15d963cd40f78b3abb9` (Scratch `manifests/manifest.json` at export, copied beside the dataset; equal to `manifest_sha256` in both runs' `metrics.json`) |
| Split ID / version | the manifest's split definitions at export time; validation = whole recording groups per surface, `--val-fraction 0.25`, drawn with `--seed 0`, written to `runs/net/net_v1/split.json` and reused by every later run with `--split` |
| Label set version(s) | four corners per recording, each confirmed by the owner in the Net labels tab (`net-labels.json`). Where the corners started is recorded per label (`proposalSource`): on 2026-11-01, of 129 corner labels, 93 started from a Claude (`claude-opus-5-5`) proposal the owner confirmed or fixed (AI-assisted pilot, PR #122), 27 from the old model's box, 9 drawn by hand; 2 box-only labels have no corners and are not exported. A proposal is never a label without the owner's Confirm. No versioned label-set ID yet (D-009 work); the count at export is filled below |
| Withheld | the 21 withheld recordings (lineage holdout 16 + legacy holdout 5) and every alias: refused by the export and refused again by the trainer against the manifest (`split`, `reservedAs`, fingerprint); handheld (8) not labeled (plan §3) |
| Extra data (H2 only) | Roboflow `bumpsetcut/volleyball-ykkmn-grgwy` **version 1** (generated 2026-11-01, auto-orient only, no resize or augmentation: the trainer letterboxes and augments), 547 images, 586 net boxes (+481 ball boxes, dropped by the trainer), exported as YOLOv8 (zip SHA-256 `7c9851639f7944839fe3bed2355a414f3e23ee117d67808c9bd0dc1e1f569ecc`) to `~/Movies/RallyLab/Datasets/roboflow-net-v1/`. Licence **CC BY 4.0** (Roboflow's project licence; the owner: public images): attribution to the Roboflow project is required wherever a model trained with it is described. Almost every label is a polygon (580 of 586 net, 472 of 481 ball), which the trainer refuses, so `--extra` is the derived copy `roboflow-net-v1-boxes/` — each polygon replaced by its bounding box, recorded in its `provenance.json`; the trainer reads it as 547 images, 21 without a net, 47 with more than one. Train only, never val |
| Control model | none in H1 (a from-scratch model against the gates' thresholds); in H2 the run without `--extra` |
| Treatment model(s) | `net_v1` (our frames); `net_v1_extra` (our frames + Roboflow) — `best.pt` and `best.onnx` SHA-256s recorded by the trainer |
| Pipeline config SHA-256 | n/a (no pipeline run in this record) |
| Trainer / converter versions | torch 2.11.0+cu128 (desktop .venv); coremltools 9.0 (Mac, `~/.venvs/heatconv`); trainer and converter at the code SHA |
| Seeds | 0 for the split, initialisation and augmentation; a second seed only if authorised |
| Compute | the desktop GPU (RTX 3060) over SSH: net_v1 279 s (40 epochs), net_v1_extra 545 s |

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

Run 2026-11-02 (MST). Both runs: seed 0, 40 epochs, batch 32, lr 0.002, the same 36 val frames from 15 recording groups (val digest `050294b6f5a4eb9ca49d5dfb75d1ad132b15971c5548901b468c1e521ddef65b`, equal in both runs). Kept checkpoint = lowest mean top error with misses counted as 1 (net_v1 epoch 29, net_v1_extra epoch 26). Errors are medians over the val frames; top in frame heights (H), sides and corners in frame widths/fractions (W).

| | detect rate | top error median / p90 (H) | left / right median (W) | corner error median | IoU mean | 90 % range of the median top error (groups) |
|---|---|---|---|---|---|---|
| **bar (H1)** | ≥ 0.95 | ≤ 0.02 | ≤ 0.05 / ≤ 0.05 | — | — | — |
| net_v1, all val (36) | **1.00** ✅ | **0.0425** ❌ / 0.102 | **0.080 / 0.092** ❌ | 0.090 | 0.39 | 0.022–0.055 |
| net_v1 beach (13) | 1.00 | 0.046 | 0.076 / 0.056 | 0.090 | | |
| net_v1 grass (16) | 1.00 | 0.051 | 0.059 / 0.097 | 0.101 | | |
| net_v1 indoor (7) | 1.00 | 0.015 | 0.103 / 0.119 | 0.104 | | |
| net_v1_extra, same frames (H2) | 1.00 | 0.0330 / 0.078 | 0.058 / 0.065 | 0.093 | 0.47 | 0.026–0.043 |
| net_v1_extra beach / grass / indoor | 1.00 | 0.028 / 0.034 / 0.043 | 0.085·0.073 / 0.039·0.057 / 0.055·0.038 | 0.107 / 0.071 / 0.097 | | |

- **H1: not met.** The net is found on every val frame, but the median top error (0.043 H) is about twice the 0.02 H bar and the side errors (0.080 / 0.092 W) exceed 0.05 W. No surface passes both: indoor's top error (0.015, 7 frames) is under the bar but its sides are not. The model is not a candidate for the gates.
- **H2: not told apart.** Paired on the same 36 frames, net_v1_extra − net_v1 median top error = **−0.0096 H**, 90 % range **−0.019 to +0.013** (10,000 resamples of the 15 val groups, seed 0; per-frame errors from each run's `metrics.json` `per_frame` against `net-dataset.json`, which reproduce both runs' reported medians). The extra run is better on 22 of 36 frames. The range includes zero.
- Outputs, copied to `~/Movies/RallyLab/Reports/net-v1/` (bring_back folders + Core ML):

| | best.pt | best.onnx | metrics.json | split.json | Core ML vs PyTorch |
|---|---|---|---|---|---|
| net_v1 | `e8ad86dd7c522bad73815a2d40e90d850225416fe55bfba9144349f5a8227cce` | `665f320057ec18489512e4440f04816535266863dde37ca028bf631585d1e8be` | `0dc713e3bbc26021a44924390f6512bc62c854658e22cac606665ffca25f231a` | `d5b665502d6f8330b69e63f7b99bff6eba0991971d3b5c90ea1d10a866122846` | max diff 0.0006 |
| net_v1_extra | `eb75eaa41f59cc5902e95817dfca5f04e7be8e1e4d0989ee1e7464ef9c848a41` | `ae60808129e74c345d7e780c673238ddaa564c399a1913391e3d1928f230ffb9` | `a6b3394fc69454082aa85c0746c659eec5def4f7d24f9096ab7ae08e9f2ded45` | `c7be716f39f944832496dc711adedd5c2e88e57fc9533f6a04cefd9ed02f4f13` | max diff 0.0007 |

**Deviations from the procedure (all before any result was seen):**
1. The first export (`Scratch-net-20261102-0129`) was refused by the trainer before anything was written: `grs_gnd_shade_land_self_02_v2`, an old-model box the owner had confirmed unchanged, had all four corners up to 0.0098 W outside the frame. On the owner's instruction ("can you just snap it back onto the frame") that one label's corners were clamped to the frame (x −0.0098 → 0, 1.0008 → 1; y unchanged), its box recomputed and `adjusted` set true; nothing else in `net-labels.json` changed (backup `net-labels.json.bak-20261102T084029Z`). The data was re-exported as `-0140` and the `-0129` folder deleted; its 129 ledger rows remain (rows are never dropped). Follow-up: the Net labels tab should not let a box outside the frame be confirmed as is.
2. The trainer's first start on `-0140` stopped at import (`paired_compare.py` was not yet on the desktop); copied from the code SHA, restarted. No output had been written.
3. net_v1 finished and wrote all outputs, then raised on printing its final "✅" line (Windows cp1252 console), which stopped the chained net_v1_extra start. net_v1_extra was started by hand with `PYTHONIOENCODING=utf-8`, the same arguments as the procedure.

## Decision

pending — the owner's call. On these results the record's options are: **need data** (more labeled recordings; 93 training frames is the constraint), **revert** (change the recipe — e.g. higher input resolution or longer training — under a new record), or keep neither model. Neither model is a candidate for the gates (H1 not met), so `net.mlpackage` stays until a model passes.

## Test results

The trainer's own tests at the time of writing: `~/.venvs/heatconv/bin/python -m unittest scripts.tests.test_train_net_model` — **19 tests, 0 failures** (14 on the data rules: export checks, an entry as the Swift export writes it, the corners being the label and the YOLO box their bounds, withheld refusal, fingerprint and image-hash refusal, YOLO lines, extra-folder provenance and net class, group split and a cross-surface group never emptying a surface from training, letterbox of boxes and corners, corners under flip and crop, scores, YAML names; 5 on training: a run's record and `--score-only` reproducing it, augmentation fresh each epoch and repeatable, a withheld recording stopping the run before anything is written, a 30-epoch synthetic run whose kept epoch is the best seen, and the Core ML conversion matching PyTorch).
