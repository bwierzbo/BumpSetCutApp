---
name: court-net-validation-20261124
status: active
created: 2026-11-25T05:44:12Z
updated: 2026-11-25T05:44:12Z
---

# Validation of the Court & Net / YOLO-removal stack (PRs #206, #207, #208)

Asked for by the owner on 2026-11-24, before the merge gate ([D-042](../decisions/DECISION_LOG.md#d-042)). Run on PR #208's head `25b16a7c` (which contains #206 and #207) against `main` at `bd25d95b`. Evidence (per-frame dumps, results, the harness and scripts) is in `~/Movies/RallyLab/Reports/court-net-validation-20261124/` on the Mac; nothing in it is in this repository.

No model was trained, no classifier exported, nothing merged, deployed or distributed.

## 1. Tests

| Suite | Head | Result |
|---|---|---|
| `BumpSetCutTests` (iOS unit) | `25b16a7c` | `Executed 569 tests, with 0 failures (0 unexpected) in 162.332 (162.490) seconds` |
| `RallyLabTests` (macOS, hosted in RallyLab) | `29a14f71` | `Executed 716 tests, with 1 test skipped and 7 failures (0 unexpected) in 331.526 (331.736) seconds` — all seven are assertions of one test, below |

Between `29a14f71` and `25b16a7c` only iOS-app files, a script and documents changed; nothing RallyLab compiles.

**The one failing RallyLab test is not from this stack.** `NetLabelsTests.testAProposalsOwnFrameOpensFromThisMacAndAChangedOneIsReadFromTheVideo` fails 3 runs of 3 on `main` at `bd25d95b` as well as 3 of 3 here. It is left as found and needs its own look.

RallyLab's owner-facing state during the hosted runs: the app's preferences were exported before and after and are byte-identical; the test host does not restore the last project (`ProjectsModel`, under XCTest). The owner's own RallyLab window stayed open and untouched throughout.

## 2. The research pipeline is unchanged by the move

A temporary hosted harness (not committed; kept with the evidence) ran RallyLab's `VideoProcessor` over the same local copies of nine development recordings — train split, not withheld, three each of grass, beach and indoor, 5 minutes each — built from `main` and from #208, and wrote every frame's evidence (time, ball flags, each detection's box, confidence, off-court and source flags, the track point, the gate's rejection reason, the candidate count) to text.

| Check | Result |
|---|---|
| Default pipeline (multi-frame ball model, old net detector), `main` vs #208 | **9 of 9 recordings: evidence byte-identical** (8,992–9,000 frames each), clips identical, net box identical |
| That net box vs the net stored for the recording in `rc-v1-20261112` | identical to the last digit on 9 of 9 (largest difference 0.00) |
| YOLO-only research path (`heatmapModel = nil`), `main` vs #208 | 3 of 3 recordings: evidence byte-identical, clips identical |
| Same build run twice | evidence byte-identical (the comparison is not within noise: there is none) |
| `ProcessorConfig().canonicalSHA256` on `main`, on #208, and the stored dataset | all `5be93ef689c9e95de2b0164bfb2232ca1ff44af551b50636c5b2f289bd02ef87` — the dataset's `pipelineConfigSha256` and its `r0` baseline's `configSha256` |

No stored dataset, baseline, fold, audit record or ledger was written or read for writing.

**Limits.** Nine recordings, not the dataset's 49. The runs went through the pipeline directly on local copies, not through `RallyLab --project Scratch`, because the owner's RallyLab was open on Scratch and reading over a slow link: a headless run on the live project would have written its ledger beside the open app and read the share against the owner's playback. So these runs are **not in Scratch's exposure ledger** (section 5).

## 3. A person's net against the detector's net

### 3a. The boxes, 34 recordings, no video read

Every train recording with a person-confirmed net (four corners) and a stored detector net in `rc-v1-20261112`: the box round the person's corners against the detector's box. Differences are person − detector, in the units the rules use.

```
n 34
top edge (person - detector), frame heights min/med/max -0.108 / -0.004 / +0.078  |abs| med 0.006  >0.02: 6  >0.05: 4
bottom edge min/med/max -0.038 / +0.003 / +0.036  |abs| med 0.005  >0.02: 7  >0.05: 0
left post, frame widths min/med/max -0.285 / -0.004 / +0.093  |abs| med 0.008  >0.02: 9  >0.05: 5
right post min/med/max -0.251 / -0.002 / +0.092  |abs| med 0.009  >0.02: 10  >0.05: 6
IoU min/med/max 0.20 / 0.87 / 0.98   <0.5: 3
```

Typically within one percent of the frame; on about one recording in six the two differ by more than 5% of the frame somewhere, and on three the overlap is under half — the detector and the person are not marking the same thing (a neighbouring court's net, or a net the detector boxed loosely).

### 3b. Rally output, 9 recordings, same footage and configuration

#208's pipeline, default configuration with the recording's camera, three ways: the old detector's net (RallyLab's default), the box round the person's confirmed corners (what the app uses), and no net (what the app does for a video nobody calibrated). Scored with `RallyCutScore.Tally` against the complete rally marks: *found* is a clip matching a rally at IoU ≥ 0.3; *missed* is a rally no clip touches; *false* is a clip touching no rally; *merged* is one clip covering two or more rallies; *dead* is clip time outside every rally and excluded span.

| Net | Rallies found | Missed outright | False clips | Merged clips | Dead time |
|---|---|---|---|---|---|
| Detector (before) | 87 of 163 (53.4%) | 6 | 12 | 17 | 647 s (37.9% of clip time) |
| Person-confirmed (app, calibrated) | 88 of 163 (54.0%) | 2 | 12 | 21 | 686 s (38.7%) |
| None (app, not calibrated) | 61 of 163 (37.4%) | 1 | 23 | 22 | 885 s (44.4%) |

Per recording:

```
#208: detector net vs person-confirmed net vs no net
  recording                      net       truth found missed false merged dead_s clip_s offCourtDets
  grs_gnd_sun_land_self_01_v5    detector     25    18      2     1      3   52.0  178.0   1608
  grs_gnd_sun_land_self_01_v5    person       25    16      1     2      4   64.2  199.6   1333
  grs_gnd_sun_land_self_01_v5    none         25     7      0     0      6   96.8  250.0      0
  grs_ele_sun_land_self_01_v3    detector     12    11      0     1      0   70.7  127.3    200
  grs_ele_sun_land_self_01_v3    person       12    11      0     1      0   72.1  128.7    124
  grs_ele_sun_land_self_01_v3    none         12    10      0     6      0  119.1  175.7      0
  grs_ele_sun_land_self_01_v2    detector     12    12      0     1      0   59.0  131.9    482
  grs_ele_sun_land_self_01_v2    person       12    12      0     1      0   62.9  135.7    310
  grs_ele_sun_land_self_01_v2    none         12    12      0     4      0  108.5  181.4      0
  bch_gnd_sun_land_self_02_v3    detector     24     3      0     0      4   92.1  278.4    377
  bch_gnd_sun_land_self_02_v3    person       24     3      0     0      4   92.5  278.8    312
  bch_gnd_sun_land_self_02_v3    none         24     2      0     0      3   98.2  285.2      0
  bch_ele_ovc_land_self_02_v5    detector     19    12      0     0      4   94.5  251.3    418
  bch_ele_ovc_land_self_02_v5    person       19    12      0     0      4   94.5  251.3    423
  bch_ele_ovc_land_self_02_v5    none         19     8      0     0      5  101.1  257.8      0
  bch_ele_ovc_land_self_02_v4    detector     11     9      2     4      0   60.0  114.1    105
  bch_ele_ovc_land_self_02_v4    person       11    10      0     5      0   74.6  134.9    119
  bch_ele_ovc_land_self_02_v4    none         11     8      0     7      1   90.7  151.0      0
  ind_ele_dim_land_self_04       detector     28     1      1     0      3   73.8  283.1    240
  ind_ele_dim_land_self_04       person       28     1      1     0      3   73.8  283.2    247
  ind_ele_dim_land_self_04       none         28     1      1     0      2   76.3  287.4      0
  ind_gnd_bright_land_self_01_v2 detector      9     8      0     3      0   65.3  116.4     13
  ind_gnd_bright_land_self_01_v2 person        9     8      0     3      0   65.3  116.4     27
  ind_gnd_bright_land_self_01_v2 none          9     9      0     5      0   78.9  129.9      0
  ind_gnd_bright_land_self_01_v4 detector     23    13      1     2      3   79.7  228.2   1539
  ind_gnd_bright_land_self_01_v4 person       23    15      0     0      6   86.2  242.6   1158
  ind_gnd_bright_land_self_01_v4 none         23     4      0     1      5  115.7  276.2      0
```

**Reading.**
- **Person's net vs detector's: not identical, close in total.** One more rally found (88 vs 87), four fewer missed outright (2 vs 6), the same false clips (12), four more merged clips (21 vs 17) and 39 s more dead time (+6%). Five of nine recordings are the same or within a second; the differences are in the four where the boxes disagree most (3a) and go both ways — `ind_gnd_bright_land_self_01_v4` gains two rallies and loses two false clips but merges three more; `grs_gnd_sun_land_self_01_v5` loses two rallies and gains a false clip.
- **No net is a real loss.** 26 fewer rallies found as their own clips (61 vs 87), nearly twice the false clips (23 vs 12) and 37% more dead time. Fewer rallies are missed outright (1 vs 6) because without the rules more is kept — merged and padded. This is what a video costs until its net is confirmed.
- The low "found" rate under every net (about half) is the pipeline's on these recordings before and after; it is not from this change.

**Limits.** Nine recordings chosen for being small and end-line, before the boxes were compared; they happen to include four of the larger disagreements, so the set leans toward where the two nets differ. Five-minute cuts. Train-split recordings, which the rules were tuned on. One person's nets. It measures the three net rules as they are; it says nothing of a camera-view change within a video, which the app treats as no net.

## 4. Shipping artifacts

`scripts/check_shipping_build.sh` now reads archives. Release archives of both shipping apps for a generic iOS device (unsigned):

```
▸ <scratch>/archives/BumpSetCut.xcarchive/Products/Applications/BumpSetCut.app
  models: ball_heat.mlmodelc 
  no research detector code (HeatmapBallDetector seen, so the code was read)
▸ <scratch>/archives/Labeler.xcarchive/Products/Applications/Labeler.app
  models: ball_heat.mlmodelc 
  no research detector code (HeatmapBallDetector seen, so the code was read)
✓ no Ultralytics-derived model and no research detector code
```

It reads the bundle's models, the symbol tables (the executable and the dSYM) and the type names a stripped Swift binary keeps; it fails closed unless it finds the multi-frame detector in the code it read. The same check on RallyLab fails with the six packages and the detectors' code, as it should. RallyLab's detectors and the six packages in git are untouched.

## 5. Owed

- **Exposure rows.** The nine recordings (`grs_gnd_sun_land_self_01_v5`, `grs_ele_sun_land_self_01_v3`, `grs_ele_sun_land_self_01_v2`, `bch_gnd_sun_land_self_02_v3`, `bch_ele_ovc_land_self_02_v5`, `bch_ele_ovc_land_self_02_v4`, `ind_ele_dim_land_self_04`, `ind_gnd_bright_land_self_01_v4`, `ind_gnd_bright_land_self_01_v2`) were run through the pipeline and scored against their rally marks outside Scratch's ledger. If the owner wants them on record, `RallyLab --project Scratch --backfill-scoring-exposure` writes rows as the scoring command would have; it needs RallyLab closed. Not done.
- **Physical iPhone.** Sections A–H of the [device acceptance list](../workflow/COURT_NET_CALIBRATION_DEVICE_ACCEPTANCE.md): the owner's, by Xcode install. Not run.
- **Labeler tracking, before and after.** Section H. Not measured anywhere yet.
- **The failing RallyLab test on `main`** (section 1).
