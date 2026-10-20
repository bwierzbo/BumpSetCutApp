# Phase 0 — Baseline lock and gap analysis

Written 2026-10-20T21:52Z against the roadmap document
`BumpSetCut_RallyLab_ML_Implementation_Roadmap_REVISED.md` (dated 20 October 2026).
No code was changed in this phase.

## Open decisions — resolved 2026-10-20

The ten questions below were answered by the owner on 2026-10-20
([verbatim](../decisions/2026-10-20-phase0-owner-decisions.md)); the
normalised entries are [D-001 … D-010](../decisions/DECISION_LOG.md). The
questions are kept as asked, for the record. Where the owner's answer differs
from the recommendation given here, the decision log wins.

Each of these is a point where the roadmap, the code, or an earlier product
decision disagree.

1. **Decision layer.** The roadmap treats a learned rally classifier as P2
   research needing an RFC, citing CLAUDE.md. On 2026-10-06 the owner decided a
   small learned decision model over tracker signals replaces the FSM
   thresholds, with rules as the safety net, and `scripts/train_rally_classifier.py`
   already exists. Which governs? Recommendation: keep the roadmap's ordering
   (measurement first) but treat the learned decision layer as planned
   production work after Phases 2 and 7, not as approval-gated research.
2. **Frozen holdout.** All 13 pipeline-tuning videos (9 tune + 4 holdout) sit
   inside the detector's val split, so detector model selection and FSM tuning
   use the same videos. Proposal: freeze the 4 holdout cards as the final test
   for both, and drop them from heat-model test-set scoring. That shrinks the
   detector test set from 25 to about 21 sessions. Accept, or rally-mark more
   val videos first?
3. **Footage.** Scratch footage (25 GB) is on the desktop `D:\RallyLabFootage`,
   not this Mac. The boundary pilot, tuner re-detection, `--render-pipeline`
   and real-frame Core ML parity all need video. Copy back now, or run those
   steps over SSH on the desktop?
4. **Boundary pilot.** The 20–30 rally frame-accurate review is the owner's
   labour. Build a frame-stepping review screen with earliest/latest
   uncertainty first, or re-mark the pilot rallies with the existing live-tag
   pass at 1× and treat that as reviewed truth?
5. **Branch.** The roadmap says work on a feature branch and never touch main;
   the standing repo rule is push after every commit chunk. Proposal:
   `feature/rallylab-ml-evaluation-v2`, pushed after every chunk, one PR per
   phase.
6. **Phases 5 and 6 (pretraining, resolution, colour, pseudo-labels).** The
   roadmap schedules these as fresh experiments. They were run 2026-10-12/17
   (score table below): from-scratch beats VballNet-start, 1024 loses, colour
   wins beach/grass and grey wins indoor, machine labels hurt. Options:
   (a) accept those results and skip Phases 5/6, (b) re-run only the finalists
   under the new frozen split with 3 seeds, (c) re-run everything. Recommendation: (b).
7. **Tuner objective.** The roadmap wants the primary objective to be
   "minimise dead-time retention subject to complete-rally recall ≥ target",
   and the existing `0.25 × dead-time` score kept only as a named diagnostic.
   The owner chose the 0.25 score on 2026-10-11 ("missing a rally is worse").
   Switch the primary objective as the roadmap says, or keep the 0.25 score as
   primary and add the constrained one as a report column?
8. **Rally-score gate mismatch.** `PipelineTuner` searches `enableRallyScoreGate`
   and `EvidenceReplayer` applies it, but production `VideoProcessor` never
   does. Fix by (a) making production apply the gate so replay and app match,
   or (b) removing the gate from the replayer and the tuner's search space.
   The roadmap says only "reconcile". Recommendation: (b), unless the gate was
   meant to ship.
9. **Venue grouping unit.** The roadmap's splits, leakage audit and paired
   bootstrap all key on a venue/session ID, which does not exist in any stored
   format. Proposal: use the clip card (`PlannedClip.id`, one uploader/channel
   + surface) as the venue group, add an optional explicit `venueId` field for
   manual overrides, and flag uploader reuse across cards. The roadmap warns
   against silently inferring one venue per video; the card is coarser than a
   video but still an inference.
10. **Phase 4 scope.** The roadmap assumes verified dead-time negatives can be
    enabled by including the dead windows in training. In the trainer those
    windows have no labels on any frame and unlabeled frames have loss weight
    0, so the change is larger: a new per-frame `VERIFIED_ABSENT` target (zero
    heatmap, weight 1) with a sampling weight, plus a review step that promotes
    dead windows from "unmarked" to "verified absent". Confirm this larger
    scope is wanted before the trainer is touched.

## Roadmap items that need no decision (will be done as written)

- Create `docs/ml-roadmap/` in git (this file); `reports/` is gitignored.
- Phase 2 canonical scorecard: raw boundaries from `BuiltSegment.raw` of one
  padded run; padded clips scored separately for coverage and dead time.
- Scorer fixture `raw [10,14] vs truth [10,14], export [8,14.5]` → zero raw
  error, full export coverage; plus the adversarial cases the roadmap lists.
- Replay-vs-`VideoProcessor` parity as a unit test, not a runtime warning.
- Label provenance fields added with `decodeIfPresent`; legacy marks tagged
  `legacy_unverified`, never "reviewed".
- YOLO packages (`ball_v2_small`, `bestv2`, `bestv3`, `ball_rallylab_*`,
  `net`) leave the public iOS bundle before launch (Phase 10); kept for
  RallyLab and the internal Labeler build.

## Repository state

| Item | Value |
|---|---|
| Branch / commit | `main` @ `f63bfe05bbcb6e5482f32046510dc1eb63e4468d`, working tree clean |
| Other worktrees | `epic/rallyplayerviewinterfaceupgrades` (73b07d1), `epic/rallyswipingfixes` (e04d2de) — unrelated |
| Build (`scripts/build.sh both`) | BumpSetCut iOS sim: **BUILD SUCCEEDED**; RallyLab macOS: **BUILD SUCCEEDED**; exit 0 |
| Unit tests | not yet run in this phase (last known green 377/377 on 2026-10-04) |

Every file the roadmap lists exists locally except the two it marks "new if
needed" (`RallyLab/DatasetSplitManifest.swift`) and the tuning file it places
at the wrong path (`pipeline_tuning/validation.json` lives per project, see
below).

## Roadmap claims vs the actual code

| Roadmap claim | Verdict | Actual |
|---|---|---|
| App default is not a heatmap-only deployment | **Wrong** | `BallFinder.current` defaults to `.multiFrameOnly` (`YOLODetector.swift`). YOLO runs only via the debug picker. |
| Shipping heat model is VballNet fine-tuned | **Wrong** | `ball_heat.mlpackage` = `scratch_768_1014`: from scratch, colour, 768×432, package `Scratch-multiframe-20261014-0006`, converted 2026-10-14 (commit ed25d2c). |
| Scratch-vs-pretrained, 512/768/1024, colour/grey and pseudo-label ablations are still to run (Phases 5, 6, Q4, Q5) | **Already run** | Test-set rescore 2026-10-16/17 of 10 models (table below). 1024 is worse and 3× slower; machine labels hurt (r3). |
| No surface / venue metadata anywhere | **Wrong** | `PlannedClip` (project.json) has environment, camera, lighting, orientation, ball, split. Clip IDs encode them (`bch_onl_sun_land_onl_03`). No venue, game or recording-session ID exists; the surface-from-prefix parser is duplicated in 4 files. |
| `pipeline_tuning/validation.json` is in the repo | **Wrong path** | Per project: `~/Movies/RallyLab/Projects/Scratch/pipeline_tuning/validation.json` — `{tune: 9, holdout: 4}` session names only. |
| Headless scorer scores padded clips at IoU 0.3 / 1 s tolerance; UI scores raw | **True** | `RallyCutScore.Tally.add` scores `VideoProcessor.rallySegments` (padded; preroll 2.0 s, postroll 0.5 s), so preroll reads as ≈ −2 s start error. `RallyLabModel.recomputeScore` scores raw at the scorer default IoU 0.5. |
| `EvidenceReplayer` exposes raw and padded outputs | **Partial** | Computes both, returns padded only. "Raw" is a second run with padding zeroed — merge (≤ 1.35 s gap) and min-length (2.61 s) then run on unpadded ranges, so raw and padded runs can yield different segment sets. |
| Tuner objective is 0.25 × dead-time per rally-second, not a flat 4 s per missed rally | **True** | `PipelineTuner.swift:139`: `covered / rallyTime − 0.25 × deadTime / rallyTime`. `missed`/`cutShort` are counters only. |
| Trainer scores dead windows but excludes them from training | **True, and deeper** | `load_windows` returns dead windows separately; their frames load with `labels = [None]*SEQ`, and unlabeled frames have loss weight 0. Adding them to `train_w` unchanged would train on nothing. Phase 4 needs a new verified-absent target. |
| Core ML converter: FP16, one random tensor, max-diff ≤ 0.05, macOS14 target | **True** | `heatmap_to_coreml.py:58-66`. No iOS deployment target; no real-frame parity. |
| Rally labels lack provenance fields | **True** | `RallyMarkRecord {startTime, endTime, kind?, contacts?}`. Per-frame ball points already carry `origin` (auto/user/filled), `reviewed`, `unsure`. A decode failure loads as empty and the next save overwrites the file. |
| Reviewed track bounds are auto-written as rally marks | **Partly stale** | `LabelTrackTask.swift:203` still writes marks on Done, but from the person's serve-to-dead trim, not the visible-ball span. Since 2026-10-17 the live-tag pass (presses snapped ±0.4 s to the ball path) is the main source of rally times. |
| `PipelineCompare` uses first/last visible ball as a guide only | **True** | Header comment says so. |
| 9-frame heatmap, grey or RGB, portrait rotation; ~30 fps sampling; 0.3 s track margin; 17-frame stored windows | **True** | 60 fps → 30, 24 fps stays 24. |
| Dead windows exported only from fully marked videos | **True, weak** | "Fully marked" = manual `ralliesMarked` flag; nothing checks it against the label file. Dead windows every 3 s, ≥ 1.5 s clear of any mark. Hidden ball is encoded like "no ball" unless the hide is ≤ 0.6 s. |
| No raw-vs-padded fixture, no replay parity test | **True** | No test references the scorer, replayer, tuner, dataset store, multi-frame package or heatmap detector. Parity is a runtime warning in the tuner at 0.2 s. `SegmentBuilderTests` comments quote stale merge/min-length values. |
| `TestSetScore` lacks false-track duration / per-dead-minute rates | **True** | Thresholds 0.1–0.9, τ 4 px (16 px occluded), 90 % clip bootstrap (2000 resamples). Dead time is a frame count. |

### Bugs found that the roadmap did not know about

- **Tuner can recommend a setting production ignores.** `EvidenceReplayer`
  applies `enableRallyScoreGate` and `PipelineTuner` searches it; `VideoProcessor`
  never applies it.
- **Tuning set ⊂ detector test set.** See decision 2.
- **Raw replay ≠ padded minus padding.** A correct raw scorecard must read
  `BuiltSegment.raw` from the single padded run.

## Data inventory (Scratch project, `~/Movies/RallyLab/Projects/Scratch`)

| Item | Value | SHA-256 (first 16) |
|---|---|---|
| `project.json` | 121 clip cards: Beach 49 / Grass 43 / Indoor 29; split pinned on 60 (49 train, 11 val), auto on 61 | `8404d1c0d97f10a4` |
| `sessions/*.json` | 168 files (167 sessions: 142 train, 25 val) | `67d1c51590bcdf14` (concatenated) |
| `*.rallylabels.json` | 33 files under `footage/raw/` (sidecars for the videos still on the Mac) | `679e8fff2972b276` (concatenated) |
| `pipeline_tuning/validation.json` | tune 9 (bch 3 / grs 3 / ind 3), holdout 4 (bch 1 / grs 1 / ind 2); all 13 are val-split | `a47abc72dc063405` |
| `pipeline_tuning/evidence/` | 122 cached evidence files; reports 2026-10-12 | — |
| `scores/Scratch-val-multiframe-20261016-1100/scores.json` | 10 models, 11,685 frames / 11,380 labelled / 10,979 balls / 305 dead | `b92adf478ba17a5f` |
| Footage | `footage/` holds only `meta/sources.csv` and 3 raw dirs; video is on the desktop `D:\RallyLabFootage\Scratch\footage` | — |

Split facts: split is per whole video (`DatasetStore.splitForNewVideo`, val
share target 15 %), or pinned per card. Videos of one card can land on both
sides when the card is auto. One uploader (Dianne Gan) appears on both sides
(beach val, grass train). No `ClipSource.fingerprint` appears on both sides.
No schema version exists in any stored format.

### Heat-model test-set scores (frozen reference, 2026-10-17)

F1 at τ 4 px with 90 % clip bootstrap; by-surface F1.

| Model | F1 | 90 % CI | Beach | Grass | Indoor |
|---|---|---|---|---|---|
| scratch_768_1014 (colour) — **shipping** | 0.905 | 0.879–0.922 | 0.914 | 0.924 | 0.835 |
| scratch_512_1014 (colour) | 0.903 | 0.880–0.920 | 0.910 | 0.927 | 0.829 |
| scratch_512_gray_1014 | 0.899 | 0.881–0.912 | 0.893 | 0.918 | 0.866 |
| scratch_768_gray_1014 | 0.896 | 0.879–0.910 | 0.895 | 0.911 | 0.865 |
| scratch_768_gray_1016 | 0.888 | 0.869–0.903 | 0.878 | 0.910 | 0.857 |
| r3_nopseudo (VballNet start) | 0.887 | 0.869–0.900 | 0.882 | 0.905 | 0.855 |
| heat_20261009-2308 (VballNet start) | 0.881 | 0.863–0.895 | 0.878 | 0.892 | 0.861 |
| scratch_1024_gray_1015 | 0.878 | 0.864–0.890 | 0.879 | 0.883 | 0.863 |
| heat_20261009-1233 (VballNet start) | 0.863 | 0.846–0.878 | 0.849 | 0.885 | 0.847 |
| Test1 heat_run4_512 | 0.836 | 0.808–0.859 | 0.816 | 0.868 | 0.805 |

Caveat: this test set is the detector val split, which is also the tuning set
(decision 2).

## Model inventory (`BumpSetCut/Resources/ML`, all git-tracked, all in the iOS bundle)

| Model | Size | RallyLab | Labeler | Provenance | SHA-256 (first 16) |
|---|---|---|---|---|---|
| ball_heat | 524 K | yes | yes | scratch_768_1014, from scratch (VballNetV4c architecture, MIT) | `0f34e1208a42c1f4` |
| ball_v2_small | 18 M | yes | yes | Ultralytics YOLO26s — AGPL-3.0 | `729d86a9deaa6a67` |
| bestv3 | 4.8 M | yes | no | YOLO26n — AGPL-3.0 | `3977e88538231305` |
| bestv2 | 5.9 M | yes | no | YOLOv8n-p2 — AGPL-3.0 | `4e269f2a4b5fdc76` |
| ball_rallylab_960 | 18 M | yes | no | YOLO26s on Test1 — AGPL-3.0 | `ca862c17b3ab4438` |
| ball_rallylab_1280 | 18 M | yes | no | YOLO26s on Test1 — AGPL-3.0 | `ad05b25240f20ca4` |
| net | 4.8 M | yes | yes | YOLO26n — AGPL-3.0 | `3057b0eb3328ff45` |

Runtime: `YOLODetector(modelName:)` defaults to `ball_v2_small` → `bestv3` →
`bestv2`; `HeatmapBallDetector` has no default and takes the bundle's
`ball_heat`. Processing defaults to multi-frame only, so the six YOLO packages
ship unused by default. Per the 2026-10-09 licensing decision they must leave
the public iOS bundle before launch (Phase 10 item 6); `net.mlpackage` is YOLO
and is affected. No LICENSE/README sits next to the models.

Fine-tune base (gitignored): `scripts/desktop_training/vendor/vball-net-pytorch-7d295c53…` (MIT, Alexander Sigatchov) with ONNX weights.

## Scripts and evaluation code

- Trainer `scripts/desktop_training/train_heatmap_model.py` — `--from-scratch`, `--color`, `--aug`, `--occluded`, `--qfl`, `--mine`, `--pseudo`; sizes 512/768/1024.
- Converter `scripts/desktop_training/heatmap_to_coreml.py`.
- `scripts/train_rally_classifier.py` + `RallyLab --export-training-data` — learned rally classifier experiment (2026-07-05); `scripts/rally_classifier_weights.json` is its output, loaded by nothing.
- Evaluation is Swift, not Python: `TestSetScore` (`--score-heat`), `PipelineTuner` (`--tune-pipeline`), `RallyCutScore` (`--score-rallies`, `--diagnose-rallies`), `ServeReport`, `EvidenceReplayer`, `PipelineCompare`.
- Desktop GPU: `desktop.sh train|queue|status|fetch`, `queue_runner.ps1`.

## Tests

Unit target `BumpSetCutTests` only; RallyLab has no test target.
Relevant files: SegmentBuilderTests (13), RallyDeciderTests (12),
RallyDeciderGracePeriodTests (3), HeatmapWindowsTests (4),
KalmanBallTrackerTests (5), ProcessorConfigTests (11),
VideoProcessingTrackingTests (15). Nothing covers the scorer, replayer, tuner,
dataset store, multi-frame package or heatmap detector.

## Metric fields currently emitted (to preserve in a canonical scorecard)

- `ScoringResult`: truePositives, falsePositives, falseNegatives, precision, recall, f1, startMAE, endMAE, startWithinTolerance, endWithinTolerance, matches, unmatchedPredictions, unmatchedGroundTruth, optimizerScore (0.75·F1 + 0.25·avgWithin). Matching: one-to-one greedy by descending IoU ≥ threshold (default 0.5).
- `RallyCutScore.Tally`: truth, clips, found, falseClips, missed, merged, split, startErrors, endErrors.
- `PipelineTuner.Score`: rallies, missed, cutShort, falseClips, covered, rallyTime, deadTime, value.
- `TestSetScore`: per model p/r/f1/tp/fp/fn/lo/hi, by court, τ 2/4/8, threshold sweep, err_median, occluded, size bins, empty, deadfire.
