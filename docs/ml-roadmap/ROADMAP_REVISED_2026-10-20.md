---
title: "BumpSetCut + RallyLab"
subtitle: "Revised: Dataset Audit, Independent Ground Truth, Scoring Repair & Claude Code Handoff"
author: "Technical research and engineering plan"
date: "20 October 2026"
documentclass: article
classoption: [oneside]
fontsize: 10pt
mainfont: "Lato"
monofont: "DejaVu Sans Mono"
geometry: "letterpaper, left=0.86in, right=0.86in, top=0.94in, bottom=0.90in"
colorlinks: true
toc: true
toc-depth: 2
numbersections: true
header-includes:
  - "\\input{/mnt/data/bsc_work/header.tex}"
---

\newpage

# Decision in one page

**Goal.** Improve automatic volleyball highlight creation on previously recorded iPhone videos while preserving complete rallies, reducing retained dead time, working on-device with Core ML, keeping RallyLab and BumpSetCut behavior consistent, and eliminating prohibited model provenance from any release artifact.

**The central recommendation:** Treat ball detection as one subsystem inside a **cost-sensitive temporal segmentation product**. Do **not** maximize detector F1 in isolation. Optimize complete-rally retention subject to dead-time removal, with real iPhone processing speed and licensing as release gates.

**Do not do a wholesale rewrite.** The connected repository `bwierzbo/BumpSetCutApp` already contains a deterministic rally decider, segment builder, evidence replay, rally-level scorers, a pipeline tuner, model-library tooling, a multi-frame heatmap detector, and a Core ML converter. Reuse those first. The repository's own `CLAUDE.md` explicitly says **no ML rally classification as the primary mechanism**. A TCN/GRU is therefore an **offline, optional research branch**, requiring an explicit architecture decision before any production integration.

**New priority after follow-up audit:** Ball detection/tracking annotations and rally event boundaries serve **different tests**. Do not throw away dense ball tracks to repair imprecise rally times; and do not treat a tracked ball's first/last visible timestamp as an independently reviewed serve/dead-ball label. Add a modest frame-accurate rally-boundary audit, source-aware annotation versioning, and tests for the raw-vs-padded scorer mismatch **before claiming rally-boundary improvements**. Existing heatmap training can continue under frozen data/split rules.

**The highest-leverage discovery:** In the current `scripts/desktop_training/train_heatmap_model.py`, *dead-time windows are scored but explicitly excluded from training*. That makes the first targeted negative-training ablation more urgent than an immediate network redesign. The same trainer already supports author-provided pretrained VballNet weights, `--from-scratch`, `--mine`, and `--pseudo`; do not reimplement those features.

**Two truths to keep separate:** The user's reported detector F1 of **0.875-0.886**, increasing no-rally false fires **7.5% to 11.5%**, approximately **10,000 labeled frames**, and **167 planned rally videos** come from the supplied research questionnaire; they were not independently rerun in this handoff. The code findings below were inspected from the connected GitHub repository on 20 October 2026; Claude must confirm the local checkout, branch, and current code before editing.

## Do this first, in order

1. **Protect the baseline:** inventory the exact repository revision, model lineage, current thresholds, dataset exports, validation manifests, and processing outputs. Snapshot scores and never overwrite them.
2. **Separate annotation purposes before measuring:** preserve dense ball boxes, frame states, reviewed/machine label origins, and the ~0.3s tracking context. Independently validate serve-contact and dead-ball timestamps; do not infer those event times solely from a trajectory.
3. **Fix measurement before models:** build venue/session-grouped train/tune/holdout splits; preserve a frozen final test set; define rally-level and detector-level metrics unambiguously. Audit scorer correctness.
4. **Use the real decision pipeline:** replay cached `FrameEvidence` through the actual `RallyDecider` and `SegmentBuilder`; compare **raw boundaries** and **padded export** quality separately.
5. **Attack false alarms:** incorporate **verified dead-time negatives** in a controlled training experiment, respecting partial labels and stationary-ball semantics. Keep the current checkpoint as the control.
6. **Compare the inexpensive pretrained baseline:** run existing VballNet author-pretrained vs scratch using paired seeds and grouped splits; consider a MobileNetV3 temporal architecture only if the simpler comparison fails.
7. **Tune and test the deterministic rally editor:** reduce missed, clipped, fragmented, and false rallies using held-out videos and evidence replay. Keep any learned TCN offline for now.
8. **Validate deployment:** audit YOLO-related shipping assets and training lineage, run PyTorch-vs-Core ML parity on a real clip corpus, and measure sustained iPhone throughput.
9. **Promote only with evidence:** merge only if user-facing rally scores improve or are preserved, no key surface regresses, build/tests pass for both targets, provenance is approved, and physical-device processing is verified.

## Meaningful definitions

**P0** means implement now or block further model comparisons. **P1** means implement after P0 baseline results. **P2** means optional research that requires a positive go/no-go decision. Values described as **proposed** are experiment settings, not measured facts or hard contractual product requirements.

# Repository-specific starting point

## Connected repository and observed code

The available connected repository is **`bwierzbo/BumpSetCutApp`**, default branch `main`. The following paths were directly inspected, and Claude should compare them to its working tree:

- **Repo working rules** — Respect dual-target builds, metadata-only processing, endline camera assumption, and deterministic pipeline invariant. **Files:** [`CLAUDE.md`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/CLAUDE.md).
- **Frame orchestration** — Instrument and optionally inject detectors; preserve existing processing lifecycle. **Files:** [`VideoProcessor.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Features/Processing/VideoProcessor.swift).
- **Ball heatmap model** — Reuse 9-frame, gray/RGB Core ML input and coordinate conventions. **Files:** [`HeatmapBallDetector.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Core/ML/HeatmapBallDetector.swift).
- **Rally FSM** — Keep production authority unless a later experiment justifies change. **Files:** [`RallyDecider.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Features/Processing/Logic/RallyDecider.swift).
- **Segment construction** — Preserve raw-vs-padded segments, joining, and minimum duration. **Files:** [`SegmentBuilder.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Features/Processing/Logic/SegmentBuilder.swift).
- **Reproducible evidence replay** — Use for rapid detector-independent decision-model experiments. **Files:** [`EvidenceReplayer.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/EvidenceReplayer.swift).
- **Rally ground-truth scoring** — Extend metrics and error reporting; do not create a parallel scorer. **Files:** [`RallyCutScore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/RallyCutScore.swift).
- **Generic segment scoring** — Reuse matching logic, raw boundary metrics, and unit tests. **Files:** [`RallySegmentationScorer.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Features/Processing/Optimization/RallySegmentationScorer.swift).
- **Pipeline tuning** — Replace/extend grouping and objective selection; retain cheap evidence replay. **Files:** [`PipelineTuner.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/PipelineTuner.swift).
- **Ball-scoring reports** — Add hard-negative duration metrics, reliable grouping, and locked test reporting. **Files:** [`TestSetScore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/TestSetScore.swift).
- **Project/data export** — Add provenance and venue metadata compatibly. **Files:** [`DatasetStore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/DatasetStore.swift), [`TrainingPackage.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/TrainingPackage.swift), [`HeadlessProjects.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/HeadlessProjects.swift).
- **Heatmap trainer** — Experiment with negative inclusion and pretraining before a major new architecture. **Files:** [`train_heatmap_model.py`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/scripts/desktop_training/train_heatmap_model.py).
- **Heatmap Core ML conversion** — Extend parity checks and target/device verification. **Files:** [`heatmap_to_coreml.py`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/scripts/desktop_training/heatmap_to_coreml.py).

**Present implementation details that affect the plan:**

- `HeatmapBallDetector` currently supports **9 consecutive frames**, grayscale or RGB, and returns Vision-normalized coordinates. The code handles portrait rotation; parity tests must cover that path.
- `VideoProcessor` instantiates `YOLODetector` by default, can use heatmap detections, and captures per-frame `FrameEvidence` for replay. The default is **not** already a pure heatmap-only deployment.
- `EvidenceReplayer` calls the **production** decider and segment builder and can score without re-running the visual model. It supports raw and padded outputs.
- `RallyCutScore` and `RallySegmentationScorer` already cover temporal overlap, misses, false clips, splits/merges, and boundaries; use one canonical aggregation with explicit metric definitions. **Audit the padded command scorer against the raw-interval UI scorer; current uses appear inconsistent.**
- `PipelineTuner` uses `pipeline_tuning/validation.json` with `tune` and `holdout` video lists. These lists must be audited for shared-venue leakage before interpreting gains.
- `train_heatmap_model.py` includes `--from-scratch`, loads the original author's VballNet weights otherwise, supports `--mine`, `--pseudo`, `--aug`, `--occluded`, and scores dead-time samples, **but `dead_w` is not in `train_w`**. That is a direct and testable explanation for limited negative training.
- `heatmap_to_coreml.py` already uses `compute_precision=FLOAT16`; its current numerical smoke test checks a single random tensor with a maximum-difference limit. That is insufficient for deployment validation on real volleyball frames.
- `CLAUDE.md` documents a default `ball_v2_small.mlpackage` derived from Ultralytics/YOLO and shared by iOS/RallyLab. Shipping restrictions require a model-license audit rather than assuming Core ML conversion makes licensing disappear.

## Conflicts Claude must not silently resolve

**Product requirement vs existing model:** The questionnaire says **no YOLO-derived weights may ship**. The repository's current default model has a YOLO lineage. Preserve the baseline for internal measurement, but do not promote such an asset into a release under the no-YOLO requirement. Obtain the exact licensing choice and approval; engineering decisions do not settle legal obligations.

**Research proposal vs product invariant:** The previous ML analysis recommends testing a small TCN. The repository explicitly says **no ML rally classification as primary production mechanism**. The correct near-term interpretation is *train and score a shadow TCN offline only after the deterministic baseline is sound; do not change the default production architecture without an explicit approval and positive independent test results*.

**User's 4x cost phrasing vs actual code:** The questionnaire describes a missed rally as costing 4x one second of dead time. The inspected `PipelineTuner.Score.value` actually computes *fraction of rally seconds retained minus 0.25 times dead-time seconds divided by total rally seconds*. This makes **one lost rally-second** equivalent to **four retained dead-time seconds**; it is **not** a fixed four-second penalty per completely missed rally. Rename/document the metric, present both alternatives, and get the product target aligned before tuning.

# What the current footage and annotations actually support

**Discussion-based dataset facts, not independently enumerated counts:** About one quarter of the current footage is reported to be self-recorded iPhone video; much of the rest comes from YouTube. The videos were deliberately selected for variation in court environment, lighting, angles, handheld/tripod setups, and image quality. Most current experiments work on approximately five-minute extracts, rather than whole matches. That is **not evidence of an inadequate dataset**. It is a reason to inventory the distribution and validate independent recordings and full-match behavior.

**Source traceability already exists in code.** In `RallyLab/ProjectsModel.swift`, `ClipSource.origin` stores the source URL or local path, alongside `start`, `length`, `title`, `uploader`, `license`, and a source `fingerprint`; projects are serialized as `project.json`. Audit **actual local project records** before claiming that every old URL still exists. Canonicalize YouTube video IDs where possible; link every five-minute derivative to the same `parent_source_id` regardless of filename. For iPhone-origin media, extract what is actually present with `ffprobe` (frame rate, dimensions, codec, bitrate, orientation, and timestamps when available). Do not claim that downloaded YouTube files identify the original camera.

## Annotation contract: three distinct ground truths, plus export behavior

| Layer | What a human confirms | Used to measure | Precision needed |
|:---|:---|:---|:---|
| **A. Ball location, per observed frame** | Main-court game ball bounding box; `visible`, `hidden/occluded`, or `unknown`; human-verified versus machine-suggested source | YOLO/heatmap frame recall, precision, localization; trajectory/tracker continuation and target switches | Frame-level box and state accuracy on **each labeled frame**; not exact rally-event timing |
| **B. Rally event boundaries** | **Serve-contact time** and **ball-dead time**, plus event type such as missed serve | True rally detection, raw start/end MAE, temporal IoU, missed/split/merged events | Aim for frame-level review on frozen validation; record tolerance and uncertainty |
| **C. Ball absence / negatives** | Verified ball absent **or** documented distractors/resting balls in a known annotated interval | False ball fires, spurious tracks, false exported clips | Must not equate unknown/unreviewed frames with true negatives |
| **D. Exported keep intervals** | No fresh hand-boxing required; derive from actual output and ground-truth B | Complete-rally preservation, dead-time retention/removal, user's delivered experience | Compare to true rally intervals **including intentional pre/post roll**, not as raw detection boundaries |

The key distinction: **the ball detector needs correct ball labels, not frame-perfect official serve/dead-ball timestamps**. Rally-boundary ground truth needs event timing, not a bounding box on every intervening frame. A tracked rally that starts somewhat late may still provide valid interior-ball training frames, but the missing serve frames should not be mistaken for absence; an overlong track should not turn unrelated idle-ball footage into `in-play` targets. Maintain a light, separately verified event boundary on all benchmark rallies.

`TrackedRally.margin` is currently **0.3 seconds**, used to retain context for the multi-frame model's nine-frame neighborhood. Its sampled tracking is approximately **30 fps**, not necessarily every source frame of 60/120 fps footage. `MultiFramePackage.swift` builds longer 17-frame stored windows and supervises labeled frames; distinguish temporal sampling from source FPS in reports. Extra frames outside a rally are context, not automatically negative training examples. Treat occlusions, out-of-frame positions, uncertain detections, and genuinely absent balls as different states.

## Important code interactions to verify and correct

1. **Auto-propagated labels are not independent boundary review.** `RallyLab/LabelTrackTask.swift` finishes a tracked rally by calling `marker.mark(start: bounds.start, end: bounds.end, session: session)`; `RallyMarkModel.swift` can also propose labels from tracked-ball visible spans. Preserve this convenience, but add `annotation_origin`, `reviewed_for_rally_boundary`, `reviewer`, and `annotation_version` so promoted benchmark truth requires an independent event review. Migration must preserve old data; mark unknown origin as `legacy_unverified`, **not** reviewed.
2. **Tracking comparisons are not the same as rally scoring.** `RallyLab/PipelineCompare.swift` separately records detection near a labeled ball, correct selected track on that ball, and whether a predicted rally covers the **first/last visible ball** span. Its own comment says those endpoints are only a guide. Do **not** use `PipelineCompare` start/end errors as authoritative serve-contact/dead-ball error.
3. **Scoring paths are not currently equivalent.** `RallyLab/RallyLabModel.swift` scores `rawPredictions` against hand labels, as it should. The `RallyLab/RallyCutScore.swift` command processes `VideoProcessor.rallySegments` and feeds those output clip intervals directly into `RallySegmentationScorer`, with `iouMatchThreshold: 0.3` and `boundaryToleranceSec: 1.0`. Because `SegmentBuilder` adds contextual pre/post roll, this likely counts intentional padding as event-boundary error. Verify with an exact fixture; fix by comparing **raw** boundaries against event truth and **padded** boundaries only against export coverage. Label legacy reports with scorer/version semantics; do not silently overwrite their historical meaning.
4. **Review affects training semantics.** `MultiFramePackage.swift` preserves checked labels, distinguishes machine pseudo-labels and hidden/occluded frames, and exports dead-time windows from fully marked videos. `train_heatmap_model.py` currently splits dead windows for scoring, not training. Any hard-negative ablation must use separately verified absence; rough rally boundaries by themselves don't prove all neighboring frames contain no ball.

## Two independent validation products (one shared source manifest)

**Ball/trajectory benchmark:** Choose human-reviewed, frame-wise ball trajectories from varied surfaces, venue/camera groups, ball sizes and occlusion conditions. Score visible-ball recall/precision at declared pixel tolerances and input sizes; localization error distribution; correct-track continuity, track swaps, time-to-reacquire after occlusion, and false tracks in verified negatives. Preserve labels and explicitly mask unknown states. No model-generated label may be the sole truth on a locked validation clip.

**Rally-segmentation benchmark:** Choose videos **fully scanned for all rally events**, ideally several complete matches in addition to five-minute development extracts. Human-confirm serve contact, ball dead, miss-serve class, and uncertainty. Score raw start/end and detected counts against event truth, then compare actual **padded export intervals** to complete-rally retention and removed/retained dead time. Correct boundaries independently of ball boxes; a visible first/last ball is not necessarily the start/end event.

These are independent **annotation and evaluation tasks**; they may reference some of the same footage only if the shared source's full parent/venue group is assigned consistently to a split. Never let ball-labeled training clips leak into the frozen rally validation or vice versa through matching source videos or adjacent five-minute clips. Maintain one inventory keyed by parent source + venue/session/camera and separate immutable label-version hashes for the two benchmarks.

## One-week annotation/scorer calibration pilot (before relabeling everything)

1. **Freeze the current run first**: export original labels, split manifests, model and configuration hashes, and baseline predictions; work on **copies** of labels so comparison remains possible.
2. **Select 20-30 rally events** from several independent recordings covering beach/grass/indoor, long and very short rallies, near/far ball, obvious missed serves, and hard boundary cases. This is a **calibration pilot**, not a statistically powered final holdout.
3. **Review serve-contact and ball-dead time frame by frame**. Mark event kind and whether boundary is definite or occluded/ambiguous. For uncertain boundaries preserve `[earliest, latest]` interval instead of claiming false precision. Have a second reviewer check a small sample or revisit difficult cases blindly.
4. **Re-score the identical frozen predictions twice**, once with the original intervals and once with corrected intervals. Compare changes in detection counts, IoU at both 0.3 and 0.5, start/end MAE and tolerance coverage, complete-rally recall, and dead-time removal. Include **rallies that reverse match/unmatch status** and absolute annotation shifts.
5. **Create a scorer equivalence fixture**: one exact `serve_contact=10.0`, `dead_ball=14.0` rally with raw prediction `[10.0,14.0]` and exported prediction `[8.0,14.5]`. The raw boundary error must be zero; the export must contain the rally; the 2-second preroll must **not** count as a 2-second start-detection error. Repeat for short rallies, merge/split cases, zero rallies, and edge clamping.
6. **Decide based on measured sensitivity**: if score changes are small, retain legacy annotations with provenance flags and selectively correct only sensitive cases; if substantial, expand boundary review systematically across the frozen rally benchmark. Never present old metrics as directly comparable to new metric definitions without version labels.

**Minimum pilot deliverables:** `docs/ml-roadmap/annotation_contract.md`, `dataset_manifest_v2.json`, `boundary_audit.csv`, `boundary_label_sensitivity.json`, and `scorer_raw_export_parity_tests.md` (or equivalent executable test logs). Include a rubric for what counts as first serve contact, ball dead, missed serve, replay/no-play, and occluded termination. Keep the existing multi-frame training on its original fixed split while this *evaluation work* proceeds; do not silently change the training corpus mid-comparison.

# Non-negotiable engineering constraints

1. **Keep user video immutable.** BumpSetCut processing produces metadata. It does not create or overwrite a second copy of the original video merely to record processing results.
2. **Preserve the production path.** Shared Swift processing code must compile and behave in both RallyLab (macOS) and BumpSetCut (iOS). Don't introduce desktop-only dependencies into shared logic.
3. **Use the exact repository build workflow:** `scripts/build.sh`, `scripts/build.sh ios`, `scripts/build.sh mac`, `scripts/build.sh both`; run the existing test suite. Do not improvise hard-coded simulator identifiers.
4. **Do not replace the deterministic decider with a learned classifier as part of this plan.** Train a shadow classifier only in an isolated research experiment and bring the change back for explicit approval.
5. **Separate model confidence from derived scores.** Preserve raw model confidence in UI/evidence. Additional calibrated probabilities or gating scores require distinct names.
6. **Fix leakage at source.** Frames, overlapping nine-frame windows, augmented views, and derived labels from the same recording must remain grouped. Prefer venue/session grouping for evaluation.
7. **Avoid hidden data assumptions.** Only fully marked videos may contribute to dead-time metrics; unknown intervals must not be treated as verified negative labels.
8. **Record versioned provenance.** Every report must include dataset ID/hash, split manifest hash, model checkpoint SHA, inference parameters, pipeline config, code SHA, and evaluation-code version.
9. **Keep physical-iPhone validation as a promotion gate.** Desktop or Simulator speed is not a substitute for sustained iPhone results.
10. **No license laundering.** Converting a model to `.mlpackage` or training with a different head does not make its source licensing irrelevant. Check training code, architecture, weights, data rights, and release bundles.

# Metric contract: what success means

The number-one model-selection metric should be **complete-rally recall at a fixed dead-time removal level**, plus a balanced scorecard of failure modes.

## Freeze definitions before optimization

For a fully labeled video let $G$ be the union of true rally intervals, $P$ the union of **exported padded** intervals, and $T$ the video duration. Use true interval arithmetic rather than counting frames when original frame rates vary.

- **Rally-time coverage** = $|P \cap G| / |G|$. This is a *seconds-weighted* quantity and can hide complete short-rally losses.
- **Dead-time retention** = $|P \setminus G| / (T-|G|)$, for $T>|G|$. **Dead-time removal** = 1 - retention. Never divide by total video time unless explicitly labeled differently.
- **Per-rally retained fraction** = $|P\cap G_i|/|G_i|$ for each ground-truth rally $G_i$.
- **Complete rally (proposed operational definition)** = per-rally retained fraction >= 0.98 **and** serve-contact and final dead-ball times fall within the padded export with a small context tolerance. The 0.98 cutoff is a starting proposal to review, *not* an existing product standard. Check genuine boundary containment separately because near-total overlap can still clip a serve.
- **Missed rally** = ground-truth rally unmatched at the agreed temporal-overlap threshold. Report both `IoU >= 0.3` and `IoU >= 0.5`, never conflate those with 'complete'.
- **Clipped rally** = rally detected but the padded export omits a material part of its real action.
- **False clip** = exported segment with no actual rally overlap. Report both count/hour and false dead-time seconds/hour.
- **Split** = one actual rally represented across multiple predictions; **merge** = one prediction spans multiple real rallies. Define overlap threshold, matching rules, and handling of multiple-to-one cases in tests.
- **Detector false fire** = a false peak on labeled ball-absent frames; additionally report **false track starts per dead-minute** and **false track persistence** at >=0.5s and >=2s, which matter more to the editor.

**Critical scoring rule:** Compare model **raw** interval starts/ends to human-labeled serve/dead-ball times. Compare **padded** intervals to actual exported-video coverage and dead-time efficiency. Mixing those evaluations makes pre-roll look like a boundary error.

## A decision policy grounded in the product

Recommend a constrained objective on the *tuning set*:

$$\text{Minimize dead-time retention, subject to complete-rally recall} \ge R_\mathrm{target}.$$

Set $R_\mathrm{target}$ through product testing, not arbitrary claims. As a development direction, an aspirational target near 99% might be useful; **it is not a guaranteed or currently measured target**. Report the Pareto frontier when no candidate meets the constraint.

Also retain a readable diagnostic cost:

$$L=C_mN_m + C_cT_c + C_dT_d + C_sN_s + C_fN_f,$$

where $N_m$ is fully missed rallies; $T_c$ is trimmed legitimate rally seconds; $T_d$ is retained dead seconds; $N_s$ is split rallies; and $N_f$ is false clips. The coefficients are product choices and **must not be silently interchanged** with the existing `0.25` rally-seconds score.

## Acceptance scorecard

| Category | Report for every candidate | Gate |
|:---|:---|:---|
| Ball detector | Precision, recall, F1, AP or threshold sweep, median/p90 localization error | No material regression by held-out venue or small-ball stratum. |
| Negative behavior | False frames/min, false track starts/min, persistence >=0.5s and >=2s | Meaningful, repeatable improvement for negative-data experiment. |
| Surface generalization | Beach/grass/indoor by venue, ball-size bin, near/far, occlusion | No hidden surface collapse. |
| Rally product | Complete-rally recall, missed/clipped/split/merge/false, start/end errors | Primary production gate. |
| Editing efficiency | Dead-time removal and exported duration | Compare at same recall constraint. |
| Deployment | Real iPhone processing ratio, decode/inference/rules timing, peak memory, temperature/thermal behavior | Must fit target hardware envelope. |
| Reproducibility | Frozen manifests, hashes, seeds, provenance, CSV/JSON/HTML output | Must be complete for promotion. |

For close differences use **paired venue/session-cluster bootstrap** (e.g. 2,000 replicates), plus multiple training seeds. A 0.01 F1 lead is *not* automatically meaningful. Fewer than roughly five independent test venues warrants caution about intervals even with thousands of frames.

# Step-by-step implementation sequence

The sequence below is intentionally dependencies-first. Each phase has an actionable Claude task, concrete deliverables, tests, and a stop condition. **Do not skip ahead to model architecture just because it is interesting.**

## Phase 0 - Baseline lock, repo audit, and safe branch (P0)

**Do:**

1. In the local `BumpSetCutApp` checkout, read `CLAUDE.md`, the existing `.claude` skills, `VideoProcessor`, `HeatmapBallDetector`, `EvidenceReplayer`, `RallyCutScore`, `PipelineTuner`, `TestSetScore`, trainer, and converter. Confirm they match the inspected paths; report all differences rather than assuming GitHub and local state match.
2. Create a dedicated implementation branch (name suggestion: `feature/rallylab-ml-evaluation-v2`). Do not alter `main` or published models directly.
3. Inventory model artifacts and where they are bundled: `Resources/ML`, `.mlpackage`, `.mlmodelc`, fallback paths, training checkpoints, Xcode project membership, CI scripts, app target and extension targets.
4. Export the current training/validation manifests, rally labels, model metrics, comparison reports, and tuning reports. Keep a copy outside any cleanup job. Hash all files.
5. Choose **three small representative footage fixtures** (beach, indoor, grass) plus one no-rally fixture that can be used repeatedly for deterministic tests. Record explicit permission to use the clips.
6. Run the existing canonical builds and tests; save baseline exit codes and logs. Do not claim green builds unless actually executed.

**Outputs:** `docs/ml-roadmap/BASELINE.md`, `docs/ml-roadmap/model_inventory.csv`, `docs/ml-roadmap/baseline_runs.json`, named baseline artifacts, and a current working-tree commit SHA.

**Pass when:** Other engineers can reproduce the baseline scores and inspect exactly what shipped versus what was tested. No product behavior changes in this phase.

## Phase 1 - Leak-proof dataset manifest (P0)

**Do:**

1. Inspect `DatasetStore`, multi-frame package generation, `RallyMarkModel`, and `HeadlessProjects`. Preserve existing JSON/CSV structure and add optional backward-compatible metadata.
2. Add stable fields: `source_video_id`, `session_id`, `venue_id`, `camera_setup_id`, `surface`, `orientation`, `capture_date_or_bucket`, `annotation_complete`, `annotation_version`, `rights_status`, `parent_recording_hash`, and `split`. Add `original_source_url_or_path`, `parent_source_id`, `clip_start_in_parent_sec`, `clip_length_sec`, `fps`, `resolution`, `codec`, `bitrate`, `annotation_origin`, `reviewed_for_rally_boundary`, and independent label-set hashes. Parse stored `ClipSource.origin` instead of losing prior YouTube URLs.
3. Create a **venue-first split generator** that groups whole sessions/videos and all their extracted windows. It should allow manual venue IDs; it must **never** silently infer a unique venue per video if that would make leakage invisible.
4. Generate `train`, `tune`, and `holdout` partitions; reserve a **frozen final test** from entirely unseen venues. Distinguish cross-validation folds from the locked final set. Allow explicit small-data warnings.
5. Implement leakage audit for shared parent IDs, duplicate/near-duplicate clips, synchronized exports, repeated venues/cameras, overlapping time windows, and source-derived pseudo-labels.
6. Extend, not replace, `pipeline_tuning/validation.json`; migrate current users without losing labels. Add manifest schema version and a migration test.

**Outputs:** Versioned manifest schema, split command, `split_report.json`, leakage audit report, and migration tests.

**Pass when:** Every clip and derived frame has a traceable group; no group crosses split boundaries; fixed seeds make partitioning reproducible; old projects still open. A five-minute segment cannot be silently counted as an independent source video; capture-device fields unavailable after YouTube transcoding are marked unknown.

## Phase 1A - Preserve dense tracks; independently certify rally-event labels (P0)

**Do:**

1. Inspect `RallyMarkModel`, `LabelTrackTask`, `TrackLabelModel`, `TrackedRally`, `MultiFramePackage`, and `PipelineCompare`. Document where each kind of label is written and read; confirm frame timestamp handling and track margins.
2. Extend label metadata in a backward-compatible way: `source_method` (`manual_event`, `auto_from_tracked_bounds`, `auto_from_first_last_visible`, `machine_proposed`, `legacy_unknown`), `review_state`, `annotation_version`, `annotator`, `source_clip_id`, and optional earliest/latest uncertainty for serve/dead events. Preserve all existing coordinates and tracks unchanged.
3. Keep model-assisted suggestions visible in RallyLab, but require a human-confirmed **serve contact and ball dead** to designate a boundary as trusted evaluation ground truth. Preserve existing completed ball-track annotations as valid for track scoring, with per-frame reviewed/unknown states intact.
4. Run the **20-30 rally calibration pilot** described above, stratifying footage by surface, camera angle, short rally duration, and event uncertainty. Use a second reviewer on difficult or random sample labels if available.
5. Add explicit event semantics and tests: serve contact (not pre-serve toss), ball dead, miss serve, occluded/departed ball, truncated file edge, no-play/background court, and UI click delay. Do not assume button press time is physical ball-dead time.
6. Generate two label inventories tied to a common source manifest: `ball_track_truth_v1` and `rally_event_truth_v1`; do not contaminate holdout provenance or discard old labels.

**Outputs:** Label provenance migration, event review UI/checklist, frozen dual ground-truth manifests, pilot sensitivity report, and tests.

**Pass when:** A report can distinguish verified per-frame ball truth from independently human-reviewed rally event truth; legacy inferred events cannot silently become trusted benchmark events; training runs on the prior labeled frames remain reproducible.

## Phase 2 - RallyLab scorecard and evidence determinism (P0)

**Do:**

1. Audit and test `RallyCutScore`, `RallySegmentationScorer`, `EvidenceReplayer`, `PipelineTuner`, and `TestSetScore`. Keep a single canonical interval-union implementation for exported coverage and avoid duplicate formulas with different edge cases. Confirm that `RallyLabModel.recomputeScore` uses raw boundaries while `RallyCutScore.Tally.add` appears to use padded `rallySegments`; reconcile via the **same canonical raw scorer** plus an **independent padded-export scorecard**.
2. Add an exported **machine-readable per-video/per-rally** JSON/CSV report plus a human-readable summary. Include split/group metadata, model/config hashes, raw-vs-padded ranges, paired comparisons, and confidence threshold.
3. Score real outputs **at one common dead-time removal level**, or produce a recall-vs-dead-time curve if no shared operating point exists. Keep frame F1 separate. Add separate panels for **(a) per-frame ball detection, (b) trajectory continuity, (c) independently verified rally boundaries, and (d) exported clip completeness/dead-time**. Do not compare first/last visible ball as though it were manually verified serve/dead time.
4. Add the hard-negative metrics to `TestSetScore`: false tracks per labeled dead-minute, events persisting >=0.5s and >=2s, confidence buckets, and source-attributed top failures. First confirm whether the needed framewise temporal outputs are available; add only the minimal extra logging if absent.
5. Add paired session/venue-bootstrap confidence intervals for metrics that are defined at the group level. Keep existing 90% clip intervals for compatibility, but label them as distinct from the new 95% paired venue intervals.
6. Verify `EvidenceReplayer` on the same fixture as `VideoProcessor` with identical configs and assert **the same raw/padded segments** within one frame or timebase rounding. Build deterministic tie-breaks for boundary-matching.

**Required scorer parity test:** An exact raw prediction `[10.0, 14.0]` against event truth `[10.0, 14.0]` with exported clip `[8.0, 14.5]` must have 0-second raw start/end error and complete export coverage, without treating preroll/postroll as timing mistakes. Check equal results through UI and headless command for identical inputs/configs.

**Required adversarial tests:** zero rallies; video entirely rally; touching intervals; predicted clip spanning two rallies; split rally; false clip; 0s/near-zero segment; overlapping pads; noninteger frame times; missing annotations; no-rally footage; video-end finalization; return to app after cancelled run.

**Outputs:** `evaluation_v2.json`, summary CSV/HTML, plot inputs, exact metric definitions, and score/replay parity tests.

**Pass when:** Independently computed interval arithmetic matches the official scorecard; scoring a frozen fixture is deterministic and does not change app output. Boundary-only scoring is based on certified event labels; a label provenance audit and scorer-version tag accompany every report.

## Phase 3 - Diagnose the current plateau (P0)

**Do:**

1. Gather existing epochs 8, 10, 12, 14 from the *same* experiment family, if saved. Score all checkpoints on identical immutable held-out videos.
2. Sweep thresholds across a dense but finite set, e.g. 0.05-0.95 in 0.05 increments. Retain thresholds already used by `TestSetScore` for historical comparison.
3. Generate precision-recall and calibration views; report false-fire curves and tracks at each operating point. Avoid declaring 'overfit' from fixed-threshold F1 alone.
4. Partition errors by surface, **ball diameter at model input**, venue, near/far court, contrast, blur, occlusion, static ball, and moving distractor. If a factor is unavailable, mark missing rather than inventing labels.
5. Produce an HTML/video error-review queue with the worst false clips and missed rallies; reuse existing RallyLab annotation flow and debug overlays where possible.

**Outputs:** `plateau_diagnosis.md`, `threshold_sweep.csv`, and stratified confusion/error table.

**Pass when:** There is explicit evidence whether the main loss comes from confidence calibration, difficult negatives, tiny balls, poor temporal continuity, or a split problem.

## Phase 4 - Verified dead-time negatives and hard-negative mining (P0/P1)

**Rationale:** Current trainer deliberately separates `dead_w` for scoring and does **not** train on it. That is a concrete experiment worth prioritizing.

**Do:**

1. Identify dead-time windows from videos marked **whole-video complete**. Build a review UI/queue if needed. Do not use unlabeled unknown regions as negatives. Audit older rally boundary uncertainty before selecting nearby windows; protect a margin around uncertain starts/ends and avoid interpreting clipped final windows as pure absence.
2. Define per-frame target states: `BALL_VISIBLE`, `VERIFIED_ABSENT`, `UNKNOWN`, `OCCLUDED`, `RESTING_BALL`. Ensure the loss masks `UNKNOWN` and follows the current/resting-ball semantics; a ball missed by a teacher is **not** proof of absence.
3. Enable sampled, reviewed `VERIFIED_ABSENT` dead-time windows in `train_w` behind a new trainer option such as `--verified-dead-negatives`. Keep `--mine` and `--pseudo` independent. Add a logged negative-to-positive sampling weight; avoid drowning positives with trivial empty frames.
4. Include difficult negatives: adjacent-court balls, lights, shoes, white clothing, court lines, spectators, static balls, compression blocks, and moving hands. Record top distractor classes if labels exist; otherwise use manually reviewed descriptions.
5. Compare **A:** existing recipe; **B:** verified negatives; **C:** verified negatives + current `--mine`. Equalize training budget and seeds. Use the same frozen split and report validation venue error, not training-set wins.
6. Ensure no frames from a held-out video enter `train_w`, even indirectly through pseudo-labels, active-learning queues, or cached windows.

**Pass when:** No-rally false tracks/event duration improve on unseen venues *without* a material drop in true rally ball continuity, small-ball recall, or complete-rally recall. Otherwise revert and inspect class balance/label states.

## Phase 5 - Pretraining experiment before a new architecture (P1)

**Important correction:** The current trainer already has an **author-pretrained VballNet pathway** (unless `--from-scratch` is used). First test that directly using the same nine-frame architecture. Do **not** assume the next action must be MobileNet.

**Do:**

1. Verify the original author's source license **and exact pretrained checkpoint license** and source hash; record derived-weight lineage. The script comment calls this source MIT-licensed, but that assertion requires an auditable release manifest.
2. Run controlled scratch-vs-author-pretrained paired experiments with the same data/split/augmentations/epochs and at least three seeds for final candidates. Use separate learning-rate tuning on `tune` as needed, and do not compare results from incompatible optimization budgets as pure pretraining gains.
3. If pretraining yields clear held-out gains and acceptable iPhone performance, **keep the smallest proven change**. Recheck beach, grass, indoor, and no-rally behavior.
4. **Only if useful:** prototype a shared pretrained MobileNetV3 encoder + lightweight temporal fusion + heatmap head. Candidate: `timm/mobilenetv3_large_100.ra_in1k` (its model card lists Apache-2.0), but independently verify exact artifact rights and Core ML conversion.
5. Keep the nine-frame interface if feasible, and store model metadata sufficient for RallyLab and the app to choose the correct preprocessing and window length.

**Pass when:** A candidate reproducibly improves the *held-out* product score or detector performance at a feasible compute cost. If no clear gain, retain the existing VballNet family.

## Phase 6 - Surface and resolution ablations (P1)

**Do:**

1. From Phase 3 diagnostics, distinguish tiny far-court balls from general scene/domain failures. Do not automatically raise resolution.
2. Implement group-balanced sampling by **venue first**, then test explicit per-surface sampling including a proposed 2.5x indoor multiplier. Record repeats per venue so one gym does not dominate.
3. Run the controlled 2-by-2 design: `512 gray`, `512 RGB`, `768 gray`, `768 RGB`; preserve sequence, data and reasonable optimizer comparability. Use model-input pixel size stratification. Treat 1024 as a conditional follow-up only if small-ball evidence supports it.
4. If tiny balls remain the bottleneck, test targeted ROI/high-resolution crops and temporal context, balancing latency and risk of losing the ball off-ROI. Avoid simultaneous changes to resolution, encoder, sampling and loss.

**Pass when:** The winning recipe improves unseen indoor/grass without sacrificing beach and fits the mobile cost envelope. Document negative/null results as well as winners.

## Phase 7 - Improve deterministic rally decisions using evidence replay (P1)

**Do:**

1. Inspect actual misses with `RallyCutScore.diagnose`, `--serve-report`, `--diagnose-rallies`, and `--render-pipeline`. Classify each miss: no detection; tracking fragmented; ballistics rejected; serve not primed; FSM late start; premature end; score gate removed; above-net gate removed; padding/merge issue.
2. Use `EvidenceReplayer` for cheap sweeps of decision settings; **rerun detection** whenever detection/physics settings change and invalidate cached evidence correctly.
3. Test candidate start/end buffers, grace periods, serve continuation, minimum rally length, and gap merging. Use a robust venue-grouped `tune` set and show `holdout` deltas transparently.
4. Test start/end annotation uncertainty of +/-0.3s using **hard boundaries vs soft boundaries vs ignored uncertainty bands** only where a learned model is trained; for deterministic scorers, use tolerance-aware error analysis, not fictitious differentiable labels.
5. Evaluate optional conservative export pre-roll and post-roll. Proposed ranges: 0.5-0.8s before and 0.5-1.0s after; the final choice must come from results, not preference. Preserve the existing short-segment pre-roll cap unless tested deliberately.
6. Reject fragile gains that only help a single court or arise from optimizing repeatedly against the final frozen test set.

**Pass when:** On unseen venues the candidate improves complete-rally recall and/or dead-time removal at the same recall, with fewer missed, split, and false clips, and the evidence replay remains production-exact.

## Phase 8 - Optional shadow TCN vs deterministic FSM (P2 / approval gate)

**Do not implement as the shipping decision mechanism under the current `CLAUDE.md` product invariant.** If the owner explicitly approves an isolated experiment:

1. Count actual independent venues, session groups, rally starts/ends, and fully marked dead-time minutes across the 167 video candidates. Only then assess whether labels are sufficient.
2. Export out-of-fold **detector-produced**, not perfect truth, per-time-step features from `FrameEvidence`: `hasBall`, confidence, tracked position/velocity, motion validity, age, predicted residual, size trend, missing mask, net crossing, projected trajectory, uncertainty and rejection reason flags. Use existing fields where possible, add minimal fields where necessary.
3. Build a **rules-only baseline** and a tiny noncausal TCN. A GRU is a secondary ablation. Predict active state and optionally start/end boundary probabilities. Use robust masking for missing observations.
4. Train on fully grouped `train` data with temporal augmentations: realistic correlated gaps, small jitter, speed changes with relabeled times, confidence drift, brief occlusion. Do not cross video boundaries in temporal windows.
5. Compare TCN vs current FSM on the **same cached detector outputs**. Tune hysteresis and padding on `tune`, evaluate on untouched venues. Report processing overhead and interpretability.
6. If—and only if—the offline TCN wins materially and the owner approves a production-architecture change, propose a separate architecture RFC and feature-flagged integration. Otherwise leave production FSM untouched.

**Pass for research:** Complete paired reports exist. **Pass for product integration:** explicit approval, favorable independent tests, real phone proof, and a documented fallback. Do not equate the two.

## Phase 9 - Inference window overlap test (P1)

**Do:**

1. Reproduce current 9-frame, hop-5 center-output behavior on a locked clip corpus.
2. Add a **side-by-side experimental path** for hop 3 with center-weighted combination of valid heatmaps for the same target time. Handle startup/shutdown edge frames and original PTS correctly. Do not shift detection time when windows overlap.
3. Compare hop 5, hop 3, hop 2, and hop 5 + cheap track smoothing. Approximate evaluation multipliers relative to hop 5 are 1.0x, 1.67x, and 2.5x, but *device wall time must be measured*.
4. If two window predictions disagree sharply, inspect whether averaging diffuses the true peak. Consider temporal plausibility-based candidate selection before adding more compute.
5. Accept only if downstream rally preservation improves sufficiently to justify sustained iPhone latency.

**Pass when:** No off-by-one/PTS regressions; all outputs are aligned with the original video; meaningful product gain exceeds compute/thermal costs.

## Phase 10 - Core ML parity, phone performance, and license release gate (P0 for release)

**Do:**

1. Preserve the current conversion path as a control. `heatmap_to_coreml.py` uses float16 compute precision already. Extend it to run **real held-out sequences** across beach/grass/indoor, portrait/landscape, low light, tiny balls and no-rally footage; compare raw heatmaps, peak coordinates, confidence thresholds, end-to-end rally segments.
2. Explicitly verify compatibility with the actual **iOS minimum deployment target** and device. The converter currently specifies a macOS target for RallyLab generation; do not assume every resulting artifact can ship unchanged to iOS.
3. Run tests on a physical iPhone with the app's actual execution settings (`.cpuAndNeuralEngine` on iOS in inspected `VideoProcessor`). Measure cold and sustained processing, memory, thermal behavior, frame decode, preprocessing, Core ML, rules, and export.
4. Use float16 as the initial model format. Only evaluate INT8 weight-only/post-training quantization if size or throughput is a real constraint; evaluate weight+activation quantization and QAT only with measured need and supported hardware.
5. Create a **model provenance manifest** for every candidate: repository, commit, source code license, exact weights, weight license, training dataset rights, transformation history, coremltools version, Python/Torch versions, model hash, Xcode bundle IDs/targets.
6. Enumerate and resolve every shipping YOLO-related model, fallback and target reference. Ultralytics publicly describes AGPL-3.0 and Enterprise licensing; the requirement 'no YOLO-derived weights may ship' still applies unless the user deliberately changes that requirement. Preserve internal baseline comparisons but **block release** on unresolved prohibited assets.
7. Add approved model packages to both relevant Xcode targets and commit them in the same change as `.pbxproj` references, per the repository's CI rules.

**Pass when:** Parity is established on meaningful real footage, iPhone throughput is acceptable, both targets build, and the final app contains only approved weights and licensing artifacts.

## Phase 11 - Promotion, rollout, and rollback (P0)

**Do:**

1. Create a candidate manifest naming exact model hash, pipeline config, dataset/split version, report locations, license approval, and runtime prerequisites.
2. Run dual builds + XCTest, headless frozen fixture tests, replay parity, iPhone smoke test, and one sustained full-length video.
3. Review a side-by-side dashboard against the previous release: complete-rally recall, missed, clipped, false, split, merge, dead-time removal, and minutes-to-process by surface/venue.
4. Enable controlled rollout only after approval. Keep reversible model/config selection and a clear rollback to the last compliant and measured candidate.
5. Version score outputs separately from labels. Do not allow tuning routines or routine CLI runs to mutate frozen final-test data.

**Pass when:** An engineer can demonstrate both higher editing quality and reliable deployment, or explicitly reject the candidate and retain the safer baseline.

# Full ML answers: all 14 research questions

## Q1 - Scratch heatmap vs pretrained backbone

**Answer:** A licensed pretrained encoder is worth testing, but first exploit the code already present. `train_heatmap_model.py` can initialize VballNet with author weights unless `--from-scratch` is set. Run a controlled scratch/pretrained ablation with grouped splits and consistent training budget. Only then test a MobileNetV3 shared visual encoder, lightweight temporal fusion, and task-specific heatmap decoder if the incremental value is likely to justify complexity. Classification pretraining provides generic features; it does not guarantee superiority for tiny fast balls or compatibility with the current nine-frame temporal model. Verify exact weights, not just library licenses.

**Go/no-go:** Significant held-out venue improvement, no unacceptable negative-fire increase, and realistic phone compute.

## Q2 - F1 plateau 0.875-0.886 and false fires 7.5%-11.5%

**Answer:** It could reflect overfitting, calibration drift, label errors, or missing hard negatives; a fixed-threshold false-fire trend does not diagnose the cause. Compare thresholds, average precision, per-venue training-vs-validation trajectories, confidence distributions, false tracks per dead-minute, and *duration* of false tracks. The trainer's exclusion of scored dead-time windows from training is a concrete testable factor. Keep the earliest competitive checkpoint as baseline until paired results say otherwise.

**Go/no-go:** A hypothesis is supported by changed stratified metrics, not inferred from F1 alone.

## Q3 - Indoor/grass weakness and 2.5x indoor oversampling

**Answer:** Test oversampling as one ablation, **balanced across venues**. First stratify by model-input ball diameter, near/far court, blur, background contrast and motion. Tiny far-court indoor balls imply a different fix than bright lights/shoes triggering false positives. Repeating one indoor gym 2.5x is not equivalent to increasing domain diversity. Compare global vs surface-balanced and 2.5x indoor samplers, with beach regression as a blocking metric.

## Q4 - 768 RGB approximately 512 gray, 1024 worse

**Answer:** This does not prove resolution is irrelevant or that capacity is limiting. The old comparison confounds channel count, spatial scale, batch size, Gaussian heatmap radius, optimizer schedule and receptive field. Run 512-gray, 512-RGB, 768-gray, 768-RGB under comparable training budgets and score by pixel-diameter strata. The 1024 image has about 1.78x as many pixels as 768 at fixed aspect ratio. Do not spend more compute on 1024 without evidence small-ball recall is the real bottleneck.

## Q5 - Machine-generated labels harmed training

**Answer:** Drop **naive self-training** but keep prediction-assisted human review. A missed pseudo-labeled ball must not become a 'verified absent' target. The existing `--pseudo` setting weights machine frames at 0.5; simply lowering their weight may not prevent systematic teacher errors. If retried, require confidence, temporal plausibility, human spot-checks, source provenance and careful masking of unknown frames. Teacher-student consistency (e.g., Mean Teacher/FixMatch principles) is a later experiment, not next week's priority.

## Q6 - Is 167 videos enough for a TCN/GRU?

**Answer:** Perhaps enough for a small low-dimensional model; the independent venue count, number of rallies and completed dead-time annotations matter far more than the video total. First build the deterministic baseline and quantify errors. A tiny noncausal TCN is appropriate for offline processing if an experiment is approved; a GRU is a secondary comparison. Generate model inputs from *actual detector signals*, not perfect truth tracks; use correlated-missingness augmentation and grouped train/validation windows. Do not infer a need for 500 videos before checking a learning curve.

## Q7 - Heatmap features vs hand-built tracker signals

**Answer:** Use tracker features and a handful of heatmap-quality statistics first: top peak, peak separation, spread, temporal agreement, confidence, track age, motion residual and missingness. A full spatial heatmap or end-to-end video network may learn scene-specific shortcuts with only 167 videos. Richer learned features are a P2 extension, not the default. This also preserves diagnostic interpretability.

## Q8 - +/-0.3s rally boundary labels and soft ramps

**Answer:** +/-0.3s is sufficient to start learning coarse rally state, though not perfect contact-frame timing. At 30 fps that is +/-9 frames; at 60 fps +/-18 frames. In a *learned* classifier, compare hard targets, linear soft ramps, and ignored uncertainty intervals. For the current deterministic FSM, use tolerance-based boundary scoring and tested export margins instead. Do not confuse annotation uncertainty with permission to clip the serve.

**2026-10-20 clarification:** The 0.3s around `TrackedRally` is **temporal input context** for ball tracking, not a target for accuracy of the official rally start/end. Distinguish it from uncertainty of older human rally-event marks, which was reported around **1-2 seconds on some clips**. Preserve dense tracks for detector training while separately correcting benchmark events. `LabelTrackTask` currently writes trimmed track bounds to rally marks, so provenance and independent verification are required.

## Q9 - Video, venue, or camera validation splits?

**Answer:** The critical generalization result is **unseen venue/camera-session** performance. All windows and duplicates from one parent recording must stay together. Use group-aware tuning, per-surface/venue reports, and a frozen venue-level final test. Video-only validation can still leak backgrounds, lighting and camera position. Explicitly audit pseudo-label sources and exported-frame aliases.

## Q10 - 4x missed-rally cost vs threshold calibration

**Answer:** Product asymmetry is sensible, but the cost needs precise units. The inspected scorer uses 0.25 dead-time seconds per rally-second retained, not a flat 4x cost per missed rally. Report this distinction, keep a named historical metric, and choose a new objective based on complete-rally recall, clipped time, splits and false clips. Tune thresholds **after** segmentation/post-processing. Start global; condition on surface only if venue-independent evidence supports the extra complexity.

## Q11 - Is +0.01 F1 meaningful; how many seeds?

**Answer:** Not necessarily. Use one seed for screening, three for finalists and five for closely contested/high-stakes promotion if resources permit. Use paired video/session/venue-cluster bootstrap for evaluation differences and report each model's seed spread. Thousands of correlated frames do not equal thousands of independent trials. Pre-register the primary product metric and do not choose the most flattering threshold or surface result after seeing final test performance.

## Q12 - Where do the next 40 engineer-hours go?

**Answer:** Focus on baseline proof, score/replay parity and real rally errors before labeling a large new sample. Recommended allocation: **7h** validation/metrics; **10h** deterministic rally diagnosis/scoreboard; **8h** targeted rally annotation; **7h** pretraining/verified-negative detector ablation setup; **5h** hard-negative review; **3h** Core ML/iPhone feasibility. These are engineering-effort budgets, not training-wall-clock estimates. Phase 0 may reveal tasks that should receive more time.

## Q13 - Core ML float16 and QAT

**Answer:** The code already converts the heatmap model to an ML Program using float16 compute precision. Extend parity beyond a random tensor and a single max-difference cutoff. Float16 is a sensible first deployment; it may still move small peaks across thresholds. Check preprocessing, rotation, coordinate mapping and per-frame peak continuity on physical iPhone. Test INT8 PTQ only if justified by size/throughput and QAT only if PTQ fails to meet accuracy needs. Never assume quantization automatically improves real ANE performance.

## Q14 - Hop-5 center windows vs overlapping inference

**Answer:** A moderate overlap experiment is warranted but not free. With equal-length windows, hop 3 implies roughly 5/3 as many window evaluations as hop 5; hop 2 roughly 5/2. Aggregate valid per-frame heatmaps with center weights and correct PTS alignment. Compare against cheap track smoothing, since overlapping correlated predictions may blur conflicting ball locations instead of resolving them. Promote only for real rally improvement per unit sustained device time.

# Experiment matrix and stopping rules

Run experiments in staged batches; record the hypothesis **before** training and do not change more than one major factor at a time.

| ID | Hypothesis | Control -> treatment | Main outcome | Decision |
|:---|:---|:---|:---|:---|
| E01 | Detector thresholds caused apparent negative regression | Epoch 8/10/12/14 fixed threshold -> PR sweep | Dead-time events/min at equal recall | Select operating point or inspect representation. |
| E02 | Verified negatives suppress dead-time alarms | Trainer default -> reviewed `--verified-dead-negatives` | False-track count/duration and complete rallies | Keep only if unseen-venue gain persists. |
| E03 | Hard mining adds complementary value | E02 -> E02 + `--mine` | Hard-case recall vs false fires | Keep if no surface regression. |
| E04 | Pretraining helps more than scratch | `--from-scratch` -> author weights | Grouped detector and rally scores | Keep simpler winner. |
| E05 | Indoor oversampling fixes low-recall stratum | Uniform -> venue-balanced -> 2.5x indoor | Indoor small-ball recall and beach impact | Adopt only if transferable. |
| E06 | Color/resolution affect specific strata | 512-gray/RGB and 768-gray/RGB | Model-pixel-size recall, phone latency | No 1024 unless proven. |
| E07 | FSM tuning improves export | Current `PipelineTuner` -> grouped sweep | Complete rallies at matched dead-time removal | Promote only after frozen holdout. |
| E08 | Overlap increases track consistency | Hop 5 -> hop 3 -> hop 2 / smoothing | Missed rallies per device-minute | Require cost-adjusted gain. |
| E09 | Learned temporal features beat FSM | FSM -> offline small TCN | Paired venue rally metrics | Research only; approval before shipping. |
| E10 | FP16 parity is safe | PyTorch -> converted Core ML / device | Location, confidence and clip parity | Block candidate if meaningful drift. |

**Stopping rules:** Reject immediately for data leakage, invalid licenses, mislabeled unknown negatives, one-sided surface regression, or broken producer-consumer frame coordinates. Pause and diagnose if a measured gain disappears in paired venue bootstrap, is dominated by one venue, or requires unacceptable phone throughput.

# Forty-hour tactical sprint, broken down

| Work block | Hours | Concrete output |
|:---|---:|:---|
| Baseline and split inspection | 3 | Commit/model/dataset inventory, group and leakage issues. |
| Metrics and paired reporting | 4 | Primary product scoreboard and reproducible comparison. |
| Rally replay/decision diagnosis | 6 | Top missed/false/split rally categories, exact attribution. |
| FSM replay tuning + tests | 4 | Versioned candidate with holdout report, no shipping switch yet. |
| Targeted rally label review (20-30 event-boundary pilot + provenance check) | 8 | Completed annotation for high-value uncertain cases. |
| Detector ablation setup | 4 | Runnable reviewed-negative vs scratch/pretrained configs. |
| Detector model experiments / review | 3 | Seeded short runs or prepared jobs and prioritized results. |
| False-fire manual audit | 5 | Error bank, source rights and negative labels. |
| Core ML / iPhone feasibility | 3 | Real-footage parity fixture and physical-device timing script. |
| **Total** | **40** | **Evidence-driven first production candidate or explicit blockers.** |

The sprint deliberately does not promise training completion or guaranteed improvement in 40 hours. If source code, local datasets, GPU or iPhone are unavailable to Claude, it must deliver **runnable commands, tests, and precise missing inputs** instead of fabricating results.

# Suggested file changes and interfaces

**Prefer extending existing files**. New names below are suggested interfaces, not claims that the files already exist.

- **Dataset** — Source/venue/session metadata, group split and leakage audit. **Files:** [`DatasetStore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/DatasetStore.swift), [`HeadlessProjects.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/HeadlessProjects.swift), [`DatasetSplitManifest.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/DatasetSplitManifest.swift) (new if needed).
- **Scoring** — Single interval/metric semantics, threshold sweeps, stratification and event rates. **Files:** [`RallyCutScore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/RallyCutScore.swift), `BumpSetCut/.../RallySegmentationScorer.swift`, [`TestSetScore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/TestSetScore.swift).
- **Replay** — Exact replay parity, validated config search, holdout reports. **Files:** [`EvidenceReplayer.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/EvidenceReplayer.swift), [`PipelineTuner.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/PipelineTuner.swift).
- **Detector training** — Verified dead-time negatives, sampling controls, provenance. **Files:** [`train_heatmap_model.py`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/scripts/desktop_training/train_heatmap_model.py).
- **Conversion** — Real-frame numerical parity, metadata, proper target support. **Files:** [`heatmap_to_coreml.py`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/scripts/desktop_training/heatmap_to_coreml.py).
- **iOS pipeline** — Optional experiments, timings and result tracing without production drift. **Files:** [`VideoProcessor.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Features/Processing/VideoProcessor.swift), [`HeatmapBallDetector.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Core/ML/HeatmapBallDetector.swift).
- **Tests** — Split invariants, temporal interval math, replay equivalence, end-of-video / orientation behavior. **Files:** `BumpSetCutTests/...` and RallyLab fixture tests.
- **Reports** — Reproducibility, charts, license inventory, promotion evidence. **Files:** `docs/ml-roadmap/*.md`, `reports/ml/*.json`.

### Proposed evaluation JSON contract

Use stable machine-readable output; adapt field names to established repository conventions rather than duplicating models:

```json
{
  "schema_version": 2,
  "git_sha": "<actual checkout sha>",
  "dataset_manifest_sha256": "<computed sha>",
  "split_id": "venue_holdout_v1",
  "model_sha256": "<computed sha>",
  "pipeline_config_sha256": "<computed sha>",
  "evaluation_code_version": "<actual identifier>",
  "metrics": {
    "complete_rally_recall": null,
    "rally_time_coverage": null,
    "dead_time_removal": null,
    "missed_rallies": null,
    "clipped_rallies": null,
    "false_clips_per_hour": null,
    "split_rallies": null,
    "merged_clips": null
  },
  "by_venue": [],
  "by_surface": [],
  "per_video": [],
  "notes": "All null measurements must be filled by actual evaluation."
}
```

Do not write `0` to represent a missing or uncomputed metric; it makes unexecuted work look like verified success.

# Claude Code execution brief - paste this as the task

> **Read this entire PDF (or the accompanying Markdown) before changing any code. This is a multi-phase implementation brief for the existing `bwierzbo/BumpSetCutApp` repository, not permission to recreate the application.**
>
> You are the lead ML systems engineer for BumpSetCut and RallyLab. Your task is to execute Phases 0-4 first and present measured evidence before expanding scope. Preserve the shared production pipeline, immutable original videos, existing RallyLab UX, and the constraints in the repository's `CLAUDE.md`. The deterministic FSM + physics/court-geometry approach remains the primary production rally classifier; a TCN is only an offline research option and requires my explicit approval before any app integration.
>
> **New mandatory scope:** Before any model replacement, preserve verified dense ball tracks; audit automatically propagated track-to-rally labels; perform a frame-accurate 20-30-event boundary pilot; and produce two independent truth manifests, `ball_track_truth` and `rally_event_truth`. Prove that rally scoring uses raw intervals while export-quality scoring uses padded clips. Fix headless/UI scorer semantic mismatches without changing production cutting or overwriting old annotations.
>
> **First actions:** (1) inspect the actual local checkout, branch, and `CLAUDE.md`; (2) read the specific Swift and Python modules listed in Section 1; (3) report which recommendations are already implemented, partially implemented, or absent; (4) find the actual dataset and existing run scores; (5) save a reproducible baseline without altering current behavior; (6) audit model provenance and the existing shipping YOLO weights.
>
> **Implement in small, reviewable commits:** A. Versioned venue/session grouped dataset manifest and leakage checker. B. Single canonical rally-level scorecard separating raw-boundary quality from padded-export quality, with locked test and paired grouped reports. C. Evidence replay equivalence tests and failure-attribution reports. D. Verified dead-time negative training as an **opt-in** ablation, with UNKNOWN masking and reproducible sampling. E. Controlled scratch-vs-author-pretrained comparison using existing training switches; only propose a MobileNet architecture if the simpler experiment warrants it.
>
> **Avoid these mistakes:** Do not treat unmarked video as verified dead time. Do not train on held-out source clips or their derived windows. Do not compare candidates on different data or preprocessing and call it an architecture result. Do not promote 0.01 F1 wins without uncertainty. Do not replace `RallyDecider` or bypass `EvidenceReplayer`. Do not change the app's displayed raw detector confidence. Do not bundle or ship YOLO-derived weights given the stated product constraint. Do not silently change metric definitions or retune against the final test.
>
> **Testing:** Use `scripts/build.sh` as prescribed by the repository, and build both iOS and RallyLab after shared changes. Add tests for interval matching, splits/merges, timing, source grouping, raw-vs-padded scoring, evidence replay parity, and model-input orientation. Run unit tests and headless RallyLab scoring whenever local tools/data permit. Physical iPhone testing is a separate required release gate; never claim it succeeded from simulator or macOS results.
>
> **Deliver after each phase:** changed files and commit SHA; test/build results (including failures); dataset/split/model hashes; before/after by-surface and by-venue metrics; examples of wins and regressions; licensing status; a clear `keep / revert / need data` recommendation; and the exact next experiment. If tools, footage, GPU, or device are missing, generate working scripts/tests and show the unverified step rather than inventing numbers.
>
> **Do not take an unbounded rewrite mandate from this document.** Start with Phase 0 and a concise gap analysis, then implement P0 measurement and correctness work. Move to P1 experiments only after baseline checks and report review; request an explicit architectural decision before a production TCN.

# Review checklist for accepting Claude's work

**Research and data**

- [ ] Exact repo branch/commit and current `CLAUDE.md` confirmed.
- [ ] Baseline datasets and checkpoints preserved, hashed and replayable.
- [ ] Whole-video/group/venue split leakage audit is green or explicitly documented.
- [ ] Unknown and partially labeled intervals cannot become false negatives in training.
- [ ] Dense ball annotations and official rally-event boundaries have **separate, versioned, independent provenance**.
- [ ] Legacy track-derived boundary marks are identified and not silently labeled human-verified.
- [ ] At least 20-30 event-boundary pilot annotations have frame-level review, measured sensitivity, and documented uncertainty.
- [ ] Tracking's ~0.3s context margin is not confused with true serve/dead event uncertainty (often reported ~1-2 seconds on older marks).
- [ ] Rally annotation completeness and boundary uncertainty are represented honestly.
- [ ] `--verified-dead-negatives` or equivalent is opt-in with class-weight logs.
- [ ] Model comparisons use the same test corpus and realistic per-venue stratification.

**Model and scoring**

- [ ] Complete-rally and dead-time metrics are exact, unit tested and clearly distinguished from frame F1.
- [ ] Raw predicted boundaries and padded export intervals have distinct score fields.
- [ ] `RallyLabModel` and `RallyCutScore` semantics match for raw boundary scoring; known padded-vs-raw regression fixture passes.
- [ ] Ball detection, selected-track accuracy, official rally detection, and export quality report separately.
- [ ] False detection duration, not just frame fire rate, appears in the report.
- [ ] Paired group comparisons and seed spread accompany close claimed wins.
- [ ] Scores are generated from actual predictions, not manually entered values.
- [ ] Real production evidence replay matches real pipeline behavior.
- [ ] No silent change to deterministic production rally classification.

**Application and release**

- [ ] Original video file unchanged, processing remains metadata-only.
- [ ] Both iOS and macOS targets build after shared changes.
- [ ] Existing tests remain green and new failure-mode tests are added.
- [ ] Float16 vs reference parity checked on real video, both orientations.
- [ ] Physical iPhone validation includes sustained throughput and memory/thermal notes.
- [ ] Shipping models have approved, documented licenses and provenance.
- [ ] No prohibited YOLO weights/fallbacks remain in release artifact.
- [ ] Candidate includes rollback plan and frozen-test evaluation report.

# Sources and traceability

## Primary project evidence (connected repository, inspected 20 October 2026)

**Additional directly inspected paths for the October 20 follow-up:**

- [`ProjectsModel.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/ProjectsModel.swift): `ClipSource.origin`, title/uploader, clip offset/length, dedup fingerprint and `project.json`.
- [`LabelTrackTask.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/LabelTrackTask.swift): reviewed track completion currently writes corresponding rally times through `marker.mark`.
- [`RallyMarkModel.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/RallyMarkModel.swift): event timestamp records and predictions from tracks, `.rallylabels.json`.
- [`TrackedRally` in `RallyTrack.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/Labeler/Shared/RallyTrack.swift): `TrackPoint` visible/hidden/unknown, per-frame review flags, ~0.3-second context, track bounds.
- [`TrackLabelModel.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/TrackLabelModel.swift): frame-level proposals, tracking paths, sampling at approximately 30fps.
- [`MultiFramePackage.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/MultiFramePackage.swift): per-frame supervision, train/val, tracked windows, machine-label origin, negative windows.
- [`PipelineCompare.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/PipelineCompare.swift): detected-ball vs selected-track accuracy; first/last visible ball used as proxy rally span, not independently marked boundaries.
- [`RallyLabModel.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/RallyLabModel.swift): UI scorer explicitly uses raw predicted boundaries.
- [`RallyCutScore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/RallyCutScore.swift): headless scored clip intervals appear padded; confirm with fixture before modifying.



The statements in Sections 1 and 4 about the current app are grounded in these source files. File contents can evolve; **always confirm local revision**.

1. [`CLAUDE.md`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/CLAUDE.md): build workflow, product invariants, model packaging, CI.
2. [`VideoProcessor.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Features/Processing/VideoProcessor.swift): live detector/decider pipeline, evidence capture, compute-unit policy.
3. [`HeatmapBallDetector.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Core/ML/HeatmapBallDetector.swift): 9-frame input, frame orientation, Core ML execution.
4. [`EvidenceReplayer.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/EvidenceReplayer.swift): real decider/builder replay and padded/raw outputs.
5. [`RallyCutScore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/RallyCutScore.swift): rally scoring and diagnostics.
6. [`RallySegmentationScorer.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/BumpSetCut/Features/Processing/Optimization/RallySegmentationScorer.swift): interval matching and boundary tolerances.
7. [`TestSetScore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/TestSetScore.swift): heatmap test-set scoring and existing threshold reports.
8. [`PipelineTuner.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/PipelineTuner.swift): tune/holdout, scoring objective and evidence replay.
9. [`DatasetStore.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/DatasetStore.swift), [`TrainingPackage.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/TrainingPackage.swift): source frames, splits, exports.
10. [`HeadlessProjects.swift`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/RallyLab/HeadlessProjects.swift): existing CLI functions.
11. [`train_heatmap_model.py`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/scripts/desktop_training/train_heatmap_model.py): scratch/author-pretrained controls, optional pseudo/hard mining, dead-time exclusion from training.
12. [`heatmap_to_coreml.py`](https://github.com/bwierzbo/BumpSetCutApp/blob/main/scripts/desktop_training/heatmap_to_coreml.py): current float16 ML Program conversion and numerical smoke test.

## External research and vendor documentation

13. Huang et al. (2019), [TrackNet: A Deep Learning Network for Tracking High-speed and Tiny Objects in Sports Applications](https://arxiv.org/abs/1907.03698). Tracks small sports balls across frames; shows material differences between single-setting and cross-validation results.
14. Farha and Gall (2019), [MS-TCN: Multi-Stage Temporal Convolutional Network for Action Segmentation](https://arxiv.org/abs/1903.01945). Basis for an *optional* low-dimensional temporal classifier experiment.
15. Tarvainen and Valpola (2017), [Mean Teachers Are Better Role Models](https://arxiv.org/abs/1703.01780); Sohn et al. (2020), [FixMatch](https://arxiv.org/abs/2001.07685). Semi-supervised principles, not BumpSetCut-specific guarantees.
16. Shrivastava et al. (2016), [Training Region-based Object Detectors with Online Hard Example Mining](https://openaccess.thecvf.com/content_cvpr_2016/html/Shrivastava_Training_Region-Based_Object_CVPR_2016_paper.html). Hard-negative sampling rationale.
17. [scikit-learn: Cross-validation and grouped splitters](https://scikit-learn.org/stable/modules/cross_validation.html) and [cost-sensitive learning](https://scikit-learn.org/stable/auto_examples/model_selection/plot_cost_sensitive_learning.html). Split and threshold selection principles.
18. [Core ML Tools ML Program conversion](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html), [optimization overview](https://apple.github.io/coremltools/docs-guides/source/opt-overview.html), and [Apple Core ML performance profiling](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode). Exact API/device details should be checked against installed versions.
19. [Ultralytics licensing](https://www.ultralytics.com/license). Vendor position on AGPL vs commercial licensing; consult legal counsel for final compliance interpretation.
20. [MobileNetV3 timm checkpoint](https://huggingface.co/timm/mobilenetv3_large_100.ra_in1k). Checkpoint card lists Apache-2.0; confirm artifact license and data provenance before redistribution.
21. [VballNet / inference weights repository](https://github.com/asigatchov/fast-volleyball-tracking-inference). Source repository displays MIT license; exact file/weight lineage still merits verification.

---

**End state:** a reliable, provenance-clean, reproducible **RallyLab evaluation and experimentation system** that leads to measurable improvements in the exact **BumpSetCut exported rally experience**. Architecture rewrites are contingent on evidence, not a default first step.
