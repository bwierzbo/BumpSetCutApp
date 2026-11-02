---
id: EXP-20261102-net-model-v2
status: planned — not approved, not run
created: 2026-11-02T16:23:54Z
updated: 2026-11-02T16:23:54Z
decision: owner direction 2026-11-02 ("do a higher input resolution and more data augmentation"), after EXP-20261031-net-model-v1 missed H1; D-002, D-017, D-018 honoured
roadmap_phase: net model replacement (licensing, 2026-10-09; plan: ../NET_MODEL_PLAN.md)
pr: exp/net-model-v2-recipe (the trainer options and this record); the run's results go on the same branch
issue: n/a
---

# EXP-20261102-net-model-v2 — the net detector at a higher input resolution and with stronger augmentation

**Status: planned, not approved, not run.** Written before any run. The previous record, [EXP-20261031-net-model-v1](EXP-20261031-net-model-v1.md), found the net on every validation frame but missed the bars: median top error 0.043 H (bar 0.02) and side errors 0.080 / 0.092 W (bar 0.05). With the Roboflow boxes added the figures were 0.033 H and 0.058 / 0.065 W. The owner chose to change the recipe: "do a higher input resolution and more data augmentation". This record tests those two changes, separately and together, on the same data and the same validation frames as v1. Nothing runs until the owner approves this record and the trainer change is merged.

## What changes in the trainer

Both changes are options; their defaults reproduce v1. The basic augmentation was checked against the merged trainer: identical output on 400 draws (5 real frames × 40 seeds, with and without a net). The v1 checkpoint loads unchanged.

- **`--input WxH`** sets the letterbox canvas. v2 uses **640×360**, about 2.8× the pixels of 384×216. At 1080p one input pixel then covers 3 frame pixels instead of 5, so the tape band (about 22 px at 1080p, the 0.02 H bar) spans about 7 input pixels instead of 4. The network is unchanged apart from its head: six stride-2 blocks, and then the final 6×10 map (instead of 4×6) feeds the same 256-unit layer. That is 3.35 M parameters instead of 1.87 M. The checkpoint records its input size. `--score-only` refuses a checkpoint trained at another size, and `net_to_coreml.py` converts at the size the checkpoint records.
- **`--aug strong`** keeps v1's flip and adds:
  - a deeper crop: 60–100% instead of 80–100%, still keeping the net whole;
  - a rotation of up to ±6° on 70% of frames;
  - a zoom-out to 70–100% on a grey canvas on 30% of frames;
  - saturation 0.5–1.5, hue ±8 (OpenCV units) and gamma 0.7–1.4;
  - contrast 0.6–1.4 and brightness ±45, instead of 0.8–1.2 and ±30;
  - Gaussian blur on 25% of frames, JPEG recompression at quality 35–90 on 30%, and noise up to σ 8 on 40% (v1: σ 4 on 30%).

  Each geometric change is skipped when it would push a corner out of the frame. The corners move with the pixels: a test places a bright dot on each corner and checks that, after 60 strong augmentations, every returned corner is still on its dot.
- `say()` no longer stops a run when a Windows console cannot print "✅". This was v1's deviation 3.

## Hypothesis

- **H1 (the gates' needs, our recordings).** Bars as in v1, unchanged. `net_v2` is 640×360 with strong augmentation and the Roboflow boxes. On the grouped validation frames of our recordings it has a **median top error of at most 0.02 of the frame height**, **median left and right edge errors of at most 0.05 of the frame width**, and a **detect rate of at least 0.95** at presence 0.5. If H1 fails on a surface, that surface's figure is reported and the model is not a candidate for the gates.
- **H2 (exploratory: which change does what).** Three runs differ from v1's `net_v1_extra` only in what their names say: `net_v2_res` (640×360, basic augmentation), `net_v2_aug` (384×216, strong augmentation) and `net_v2` (both). Each is compared with `net_v1_extra` frame by frame on the same validation frames. Reported for each: the difference in median top error and in the median left and right errors, with a 90% range from resampling the 15 validation groups. No direction is preregistered. A range that includes zero means the runs were not told apart on this many groups.
- **Not a hypothesis here:** the pipeline gates with the old `net.mlpackage` against the new model. That is the replacement PR's diagnostic, as in v1.

## Inputs (frozen)

| Input | Value |
|---|---|
| Code SHA | to be filled on approval: the merged head that holds the `--input` / `--aug` trainer (this PR) |
| Dataset | **the v1 dataset, unchanged:** `D:\RallyLabStaging\Scratch-net-20261102-0140`, `net-dataset.json` SHA-256 `67d60f666397237dd59bf6fbf7e702db732574a931e204da636d17386c98eedc`, 129 labeled frames from 74 recording groups. No re-export, so no new ledger rows; the 129 `training_package` rows of `-0140` already record this use |
| Dataset manifest SHA-256 | `493dd89ff8e18479d68667a4d62582d5cd1d7fb32711d15d963cd40f78b3abb9` (the copy beside the dataset; the trainer refuses entries against it again) |
| Split | v1's `runs\net\net_v1\split.json` (SHA-256 `d5b665502d6f8330b69e63f7b99bff6eba0991971d3b5c90ea1d10a866122846`), passed as `--split` to every run. Val = 36 frames, 15 groups, val digest `050294b6f5a4eb9ca49d5dfb75d1ad132b15971c5548901b468c1e521ddef65b`. A run whose val digest differs is not compared |
| Label set version(s) | as v1: the owner-confirmed four corners in `net-labels.json` at the `-0140` export (one label's corners clamped onto the frame on the owner's instruction, v1 deviation 1) |
| Withheld | as v1: the 21 withheld recordings and their aliases are refused by the export and by the trainer; the 8 handheld recordings are not labeled |
| Extra data | Roboflow `bumpsetcut/volleyball-ykkmn-grgwy` v1 boxes (`D:\RallyLabStaging\roboflow-net-v1-boxes`, CC BY 4.0, attribution required), training only, in **every** run, as in `net_v1_extra` |
| Control model | `net_v1_extra` (EXP-20261031-net-model-v1): best.pt `eb75eaa41f59cc5902e95817dfca5f04e7be8e1e4d0989ee1e7464ef9c848a41`, already run on this split; not retrained |
| Treatment models | `net_v2_res`, `net_v2_aug`, `net_v2`; their `best.pt` and `best.onnx` SHA-256s are recorded by the trainer |
| Fixed as in v1 | seed 0, 40 epochs, batch 32, lr 0.002, AdamW + one-cycle, checkpoint kept by the lowest mean top error with misses counted as 1 |
| Trainer / converter versions | `train_net_model.py` and `net_to_coreml.py` at the code SHA; torch 2.11.0+cu128 (desktop), coremltools 9.0 (Mac); `paired_compare.py` copied beside the trainer |
| Compute | the desktop RTX 3060 over SSH. Expected time: about 10 min for each 384 run and about 25–30 min for each 640 run (v1_extra took 545 s at 384) |

## Procedure

```
# on the desktop, in C:\BallTraining, with train_net_model.py and paired_compare.py at the code SHA
set PYTHONIOENCODING=utf-8
set DS=D:\RallyLabStaging\Scratch-net-20261102-0140
set COMMON=%DS% --manifest %DS%\manifest.json --split runs\net\net_v1\split.json --extra D:\RallyLabStaging\roboflow-net-v1-boxes --seed 0
python train_net_model.py %COMMON% --input 640x360 --aug basic  --name net_v2_res
python train_net_model.py %COMMON% --input 384x216 --aug strong --name net_v2_aug
python train_net_model.py %COMMON% --input 640x360 --aug strong --name net_v2
rem the control's per-frame sides: score the frozen net_v1_extra checkpoint (nothing is trained)
python train_net_model.py %COMMON% --input 384x216 --score-only runs\net\net_v1_extra\best.pt --name net_v1_extra_rescored
# on the Mac, ~/.venvs/heatconv
python scripts/desktop_training/net_to_coreml.py ~/Movies/RallyLab/Reports/net-v2/<run> ~/Movies/RallyLab/Reports/net-v2/<run>.mlpackage
```

The three runs are started one after another, detached, each with its own log. A run that stops is reported and not retried with other settings.

**Paired analysis, the same as in v1's H2, extended to the sides.** The trainer at the code SHA writes each validation frame's predicted tape ends (`top`) and the left and right edges of its predicted box (`sides`) to `per_frame`. v1's `net_v1_extra` metrics hold only `top`, so its frozen checkpoint (best.pt SHA-256 `eb75eaa41f59cc5902e95817dfca5f04e7be8e1e4d0989ee1e7464ef9c848a41`) is scored again with `--score-only` at 384×216 on the same split. Nothing is trained. That re-score is accepted as the control only if all three checks hold, otherwise the analysis stops and is reported:
- its validation digest equals `050294b6…ef65b`;
- its weights' SHA-256 equals the one above;
- its per-frame `top` matches v1's stored `per_frame` within 0.0002.

Each frame's top, left and right errors are computed from `per_frame` against `net-dataset.json`, the same way the trainer computes them: the top error is the mean of the two tape ends' vertical errors, and each side error is the gap between the predicted and labelled box edges. One check is that these reproduce each run's reported medians. The 90% ranges for the three differences in medians come from 10,000 resamples of the 15 validation groups, seed 0.

Outputs are copied to `~/Movies/RallyLab/Reports/net-v2/` (the bring_back folders and Core ML), with SHA-256s listed here.

## Limitations, stated before the run

- **The validation frames are not fresh.** v1's results on these same 36 frames led to the decision to change the recipe. A pass here is evidence for the recipe, not an unseen-data validation. The withheld recordings remain the unseen test, untouched. The replacement PR's diagnostic on recordings still has to be done.
- Thirty-six frames from 15 groups give wide ranges, as in v1, so H2 may not separate the runs.
- Forty epochs is kept for comparability. Stronger augmentation can need more epochs to converge; if a strong run is still improving at epoch 40, that is reported and not acted on here.
- One seed.

## Results

not measured (nothing has run)

| | detect rate | top error median / p90 (H) | left / right median (W) | corner error median | IoU | 90% range of the median top error |
|---|---|---|---|---|---|---|
| bar (H1) | ≥ 0.95 | ≤ 0.02 | ≤ 0.05 / ≤ 0.05 | — | — | — |
| net_v1_extra (control, from v1) | 1.00 | 0.0330 / 0.078 | 0.058 / 0.065 | 0.093 | 0.47 | 0.026–0.043 |
| net_v2_res | not measured | not measured | not measured | not measured | not measured | not measured |
| net_v2_aug | not measured | not measured | not measured | not measured | not measured | not measured |
| net_v2 | not measured | not measured | not measured | not measured | not measured | not measured |

## Decision

none yet (planned). Possible outcomes:
- **keep:** `net_v2` meets H1 and goes to the replacement PR's diagnostic.
- **revert:** a new recipe under a new record.
- **need data:** more labeled recordings.

## Test results

`~/.venvs/heatconv/bin/python -m unittest scripts.tests.test_train_net_model`: **21 tests, 0 failures**. These are v1's 19 plus 2 new ones:
- strong augmentation keeps each corner on its pixels;
- a run at another input size records it, scores only at that size, and refuses an odd size.

The Core ML test also converts a run trained at 192×108 and checks that the model's input is 192×108.
