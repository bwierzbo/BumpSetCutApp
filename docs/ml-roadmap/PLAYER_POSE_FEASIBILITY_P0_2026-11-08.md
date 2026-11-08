---
name: player-pose-feasibility-p0
status: proposed (owner review); P0 implemented and piloted; no training, no production change; next step needs the owner (§9)
created: 2026-11-08T23:12:03Z
updated: 2026-11-08T23:12:03Z
decision: D-034 (proposed); D-001 (player tracking/pose out of production scope — unchanged); honours D-002, D-010, D-017, D-030, D-031
experiment: EXP-20261108-player-pose-feasibility-p0
---

# Player detection, tracking and pose — feasibility (Phase P0)

**Question.** Could player positions, movement and 2D poses become useful inputs to the temporal rally classifier, alongside the ball? The eventual ablation is A: ball only, B: + player positions and movement, C: + poses, D: + ball–player interaction. P0 asks the step before that: **is player evidence extracted reliably enough to be worth an ablation at all?** This document answers that question for Apple Vision on the footage available locally. It makes no claim about rally classification: nothing here shows that players would improve rally cutting. That needs the matched ablation (§9), which is not authorised.

**Answer, in one paragraph.** Not yet. Run on the local 960 px scrub proxies, Apple Vision's person-rectangle request found **28 % of on-court players** (68 of about 239) across 36 reviewed frames from six recordings. Recall was 29–44 % on beach, grass and portrait indoor, and **6 %** in a crowded landscape gym. When it does find someone, the box, the track and the pose are usually right: few false on-court detections, stable identities for well-separated players, and plausible 19-joint poses at about 16 joints per detected player. Vision's **body-pose request finds many of the people the rectangle request misses** (up to 4 per frame indoors). Both requests together cost about **10 ms per frame**, so a 5 Hz player channel is cheap. Scene-level movement features computed from players this incomplete do **not** separate active play from between-rally time (§6.6). The recommended next step (§9) is a bounded detection follow-up, not the classifier ablation: originals at full resolution once the footage share is free, pose detections as person candidates, and one licence-cleared alternative detector.

## 1. Scope and restrictions

- **Production stays out of scope.** D-001's consequences say "player tracking/pose remain out of scope", and `CLAUDE.md` repeats it for the product pipeline. That stands. This workstream is a research tool inside RallyLab, under a proposed carve-out (D-034). No file of the iOS app or the shared processing pipeline changed, and neither did `rcf_v1`, `rally_classifier_dataset_v1` or the rally-classifier exporter (PR #164, merged; its run was in progress during this work and was not touched).
- **The live project was not modified** (owner, 2026-11-08). The tool reads Scratch and writes only into a separate experiment folder with its own ledger. §5.3 shows Scratch was byte-for-byte unchanged.
- **Nothing here is ground truth.** No pose or detection is a label, no proximity is a contact, and no missing data is a non-rally label (D-010).

## 2. What the existing architecture already provides (inspection)

| Need | What exists and was reused | Gap for players |
|---|---|---|
| Source identity, lineage, groups | `ReservedVideos` (withheld closure through file fingerprint, `sourceId`, `sessionId`, `venueId`; alias groups), `SourceRegistry` (admission, identity confidence, `TrainingEligibility` per model), stored fingerprints in `project.json` (all 167 videos have one, so no footage read is needed) | none: reused as is |
| Split isolation | `DatasetSplitManifest` + `DatasetAudit` + `LineagePackage.isolation` (the exporter's own gate) | none: reused; a stale manifest is refused, not rebuilt |
| Withheld by content | the exporter compares originals' fingerprints (reads the share) | P0 compares stored file identities and the withheld recordings' **local proxies** (hashed, never decoded); every withheld recording has one |
| Orientation and coordinates | `VideoFrameGeometry.orientation(for:)` plus Vision's orientation-aware handler, as the ball pipeline does with `applyVideoRotation`; `FrameEvidence.upright` coordinates are Vision-normalised in the upright frame | none: the player boxes are in the same space; the portrait recording confirms it (540×960 upright) |
| Presentation timestamps and time base | `CMSampleBufferGetPresentationTimeStamp`, the scoring contract's 600 ticks/s | a sampling rule on PTS (first frame at or after each 0.2 s target, never twice) |
| Court and net geometry | person-confirmed net quads (`net-labels.json`, bound to the file fingerprint); the pipeline's frozen per-video net box | **no court lines exist anywhere**, so court membership is a stated heuristic lane around the net (§4), applied only to end-line cameras, `unknown` otherwise |
| Temporal exclusion | cut ranges (D-030, `VideoSession.cutRanges`), footage-properties spans that break time (D-031), `RallyTruth` for marks | none: frames inside are written but not analysed; boundaries reset the tracker |
| Feature caching and reproducibility | `FileFingerprintCache` (in memory); exporter journals | none needed at pilot scale: two runs of the plan gave identical frames apart from timings (1,350 of 1,350) |
| Exposure | `ExposureLog` (fails closed) with kinds the old binaries decode | an existing kind (`detector_evaluation`) in the **experiment's** ledger. A new kind would make every older RallyLab build refuse the project's ledger (its `Kind` enum decodes strictly), so it is left to the owner |

## 3. What was built (RallyLab target only, `RallyLab/PlayerResearch/`)

- **`--player-lab-run`** (`PlayerFeaturesRun`) is one operation holding every guard: a bounded plan; the manifest as written, current and audited; the withheld closure (empty is refused) and isolation; development splits; admission; rally-classifier eligibility; content against withheld recordings; the experiment ledger before the first frame. Footage is the recording's local scrub proxy, copied into the experiment with a SHA-256 check.
- **Extraction** (`PlayerVisionExtractor`) uses `VNDetectHumanRectanglesRequest` revision 2 (full body) and `VNDetectHumanBodyPoseRequest` revision 1 (19 joints, several people), on a detached task off the main actor. Sampling is 5 Hz on presentation timestamps, and each frame also gets a 32×18 luminance thumbnail for cut detection.
- **Assembly** (`PlayerFrameAssembler`, pure and deterministic) associates poses with boxes and starts new segments at interval starts, gaps over 0.5 s, cut or time-break boundaries, and suspected camera cuts. It also runs the tracker (`ptrk_v1`), the court lane (`court_net_lane_v1`) and the derived features (`pfd_v1`).
- **Format** `player_features_v1` ([contract](PLAYER_FEATURES_V1_CONTRACT.md)) has a stdlib validator (`scripts/player_features/validate_player_features.py`) that fails closed.
- **Interaction interface `bpi_v1`** (`BallPlayerInteraction`) is the join to `rcf_v1` by recording and tick. It covers nearest player, wrist distance, approach rate, ball direction change near a player and confidence, with explicit missing reasons. It is defined and unit-tested, **not run** in P0.
- **Player Lab window** (`--player-lab <experiment>`) is opened before any RallyLab model exists, so no project is restored and no phone sync starts. It provides:
  - **Navigation:** run, recording and interval pickers.
  - **Playback:** frame-exact stepping and play over the sampled frames.
  - **Layer toggles:** boxes, IDs, skeletons, unmatched poses, tentative tracks, off-court persons, net, lane.
  - **Statistics:** the frame's facts and the interval's numbers, from `PlayerFeaturesSummary`, the same code that writes `summary.json`.
  - **Track timeline:** each track's lifespan, thin before confirmation and red where ambiguous, with segment starts marked and click-to-seek.
  - **Snapshot and scripting:** Snapshot saves the composed frame and its facts as JSON, and a `--script` mode drives all of the above without a pointer.

## 4. Pilot design

- **Plan:** [`EXP-20261108-player-pose-feasibility-p0.plan.json`](experiments/EXP-20261108-player-pose-feasibility-p0.plan.json), SHA-256 `e84f462880b5698441ca06ed07ad749713fe39225e5522f55b8a551d13631fcd`, frozen.
- **Recordings:** two per surface, each from a development split (train), `continuous` (confirmed), rally classifier `standard`, end-line camera, person-labelled net, rallies marked, distinct uploaders:

| Surface | Recording | Camera | Note |
|---|---|---|---|
| beach | `bch_ele_ovc_land_self_02` | end line, elevated | recreational, ~10–12 on court, neighbouring courts |
| beach | `bch_gnd_ovc_land_self_01` | end line, ground | doubles, spectators along the sidelines |
| grass | `grs_ele_sun_land_self_01_v2` | end line, elevated | tournament 4s, crowd behind |
| grass | `grs_gnd_sun_land_self_01` | end line, ground | doubles, distant (players ≈ 40 px tall) |
| indoor | `ind_gnd_bright_land_self_01` | end line, ground | 6s, crowded multi-court gym, referee stand |
| indoor | `ind_gnd_bright_port_self_03` | end line, ground | **portrait** recording, close camera |

- **Intervals:** three per recording, 15 s each, 5 Hz, which is 75 frames per interval and 1,350 frames in all.
  - `active_play`: centred on the longest marked rally.
  - `between_rallies`: centred in the longest gap between marks.
  - `difficult`: chosen by hand from a contact sheet of rally midpoints (close players, net clusters, crowding, a dive, distance); the reasons are in the plan.
- **Fixed camera first.** Camera motion was not part of this pilot.
- **Footage:** local scrub proxies only (960 px long side, the original's frame times). The originals are on the footage share, which the running rally-classifier export was reading; P0 did not touch the share.

## 5. Runs and evidence

### 5.1 Builds and tests

- `scripts/build.sh mac`: BUILD SUCCEEDED. RallyLab only; no shared-pipeline file changed, so no iOS build is required.
- **Targeted tests**, 46/46 pass:
  - `PlayerFeaturesTests` 18: sampling on PTS, tracker determinism, gaps and ID non-reuse, segment resets including a cut lying between frames, excluded frames not analysed, pose association, the lane and its unknowns, derived features, interaction missing-data, bounded plan, admission refusals, excluded spans, null joints, summary.
  - `PlayerVisionExtractorTests` 1: a synthetic rotated portrait video is analysed upright on its own timeline, with Vision really run.
  - `LaunchGuardTests` 27, including the two new launches.
- **Full RallyLabTests:** 499 run, 1 skipped, **1 failing test** (`NetLabelsTests.testAProposalsOwnFrameOpensFromThisMacAndAChangedOneIsReadFromTheVideo`, 7 assertions). It passes alone on this branch, waits on a fixed `settle()` delay, covers code this branch does not touch, and the machine was loaded by the rally-classifier export during the full run. It is reported as load-dependent timing, not fixed here.
- **Python:** `scripts/tests/test_validate_player_features.py` and `test_summarize_player_pilot.py`, 22/22 pass, run with `ResourceWarning` as an error.

### 5.2 Pilot runs (experiment `~/Movies/RallyLab/Experiments/player-pose-p0`)

| Run | Code | Frames | Validator | Use |
|---|---|---|---|---|
| `p0-pilot-1` | `60b7693` + uncommitted tool changes | 1,350 | ✅ valid (after the box-overlap rule fix, §7) | audit, GUI screenshots |
| `p0-pilot-2` | `7f75e2d` + an uncommitted decision-log edit | 1,350 | ✅ | determinism check: identical to pilot 1 on 1,350 of 1,350 frames apart from `ms` |
| `p0-pilot-3` | the PR head, clean (see the experiment record) | 1,350 | ✅ | canonical record |

### 5.3 Scratch untouched

Before the first run, 20,267 Scratch files outside images, labels and proxies were listed with their modification times and sizes. After the runs the list was identical. The SHA-256 of `manifests/exposure-log.json` (`eb6feb18…`), `manifests/manifest.json` (`8dea6dbe…`) and `project.json` (`1364ee92…`) was unchanged. No proxy was rewritten. The six recordings' use is recorded in the experiment's own ledger (`detector_evaluation`, one row per recording per run).

## 6. Results

### 6.1 Detection quality (manual audit)

- **Sample:** 36 frames, two per interval, chosen evenly by the tool before any review (`audit-sample.csv`).
- **Counted per frame:** on-court players visible (on or at the selected court, at least about half the body visible); how many of them have a box; boxes labelled "in" that are not on-court players; and detections of people off the court.
- **Reviewer:** Claude, by visual inspection of the overlays. Counts in crowded frames are approximate, and **not owner-verified**. The filled sheet is `diagnostics/audit-filled.csv` in the experiment.

| Recording | Frames | Visible on court | Boxed | Recall (rectangles) | False "in" / frame | Off-court detections / frame |
|---|---|---|---|---|---|---|
| beach elevated | 6 | 65 | 22 | 0.34 | 0 | 0 |
| beach ground (doubles) | 6 | 16 | 6 | 0.38 | 0.17 | 0 |
| grass elevated | 6 | 34 | 12 | 0.35 | 0 | 0 |
| grass ground, distant | 6 | 21 | 6 | 0.29 | 0 | 0 |
| indoor landscape, crowded | 6 | 62 | 4 | **0.06** | 0.33 | 0.17 |
| indoor portrait, close | 6 | 41 | 18 | 0.44 | 0 | 0 |
| **all** | **36** | **239** | **68** | **0.28** | **0.08** | **0.03** |

All three false "in" boxes were bystanders or spectators standing beside a net post, inside the lane's widened margin. The only off-court detection was a referee on the stand, correctly labelled "out".

### 6.2 What the pose request adds

The rectangle and pose requests disagree about who is there. 17 of the 36 audit frames had at least one pose that no box took (drawn dashed in the overlays); in 14 of them the reviewer saw on-court players found only by the pose request. In three frames (two indoor, one beach) the rectangle request found nobody while the pose request found three to five people. Over all analysed frames, the mean number of poses no box took (`unmatchedPerFrame`) was:

| Recording | active | between | difficult |
|---|---|---|---|
| beach elevated | 0.3 | 0.3 | 0.1 |
| beach ground | 0.4 | 1.1 | 0.7 |
| grass elevated | 0.4 | 0.2 | 0.2 |
| grass ground, distant | 0.0 | 0.0 | 0.0 |
| indoor landscape | 2.8 | 2.4 | 4.2 |
| indoor portrait | 0.0 | 0.1 | 0.0 |

The obvious next measurement is a person set built from **rectangles ∪ pose bounds**, audited the same way. It was not run in P0 because it would change the tracker's input after the audit.

### 6.3 Pose coverage

- **Availability:** of the persons with a box, 29–84 % also carried a pose (by interval).
- **Joints:** a carried pose reported 14.4–16.8 of 19 joints, with mean joint confidence 0.49–0.75.
- **Plausibility:** in every audit frame with an on-court pose to judge (25 frames; the other 11 had none), the poses followed the bodies.
- **One implausible pose:** in the indoor gym, a skeleton stretched to the ceiling lights, `ind_gnd_bright_land_self_01` at 216.4 s.
- **Arm elevation** (a wrist above its shoulder) appeared on 0–5 % of persons per interval, too rare at 5 Hz and this coverage to say anything about attacks or blocks; none was inferred.

### 6.4 Tracking continuity

| Interval kind (6 intervals each) | Tracks per interval (median) | Confirmed (median) | Tentative-only (median) | Confirmed length (frames of 75, mean of interval means) | Ambiguous assignments (range) |
|---|---|---|---|---|---|
| active play | 15 | 9.5 | 5 | 18.8 | 0–2.5 % |
| between rallies | 13 | 8 | 4.5 | 19.7 | 0–1.6 % |
| difficult | 14 | 7.5 | 5 | 22.5 | 0–2.9 % |

Ranges and the full table are in `diagnostics/summary.json`. Tentative-only tracks are short-lived detections that never reached 3 observations.

Identity was checked on 10 consecutive sampled frames (2 s) in two hard places:
- **Beach elevated, crowded play:** the four well-separated near players kept their IDs throughout. One player missed by the rectangles for a frame (pose only) came back under the **same** ID. A far player's track flickered tentative and confirmed. No switch.
- **Indoor portrait, three players clustered at the net:** **one identity switch**. `#19` was lost and `#29`'s box slid onto that player, while `#20`'s box grew over two people. The ambiguity flag fired on exactly the four frames where this happened (55–58), so the tracker marks its own unreliable stretches.

Fragmentation mostly follows detection: a player missed in some frames ends a track after 1 s, and the next detection starts a new one.

### 6.5 Surface and camera distance

- **Distance dominates.** Players under about 60 px tall at 960 px (the far court everywhere, the whole court on the distant grass camera) are rarely boxed. The between-rally frames of the distant grass recording had **no** detection at all.
- **Crowding matters.** The worst case, the indoor landscape gym, combines distance with a crowded background: next-court players, spectators and a referee stand.
- **Close cameras do better.** The portrait recording's close camera gave the best recall.
- **Surface itself shows no clear effect** at this sample size.

### 6.6 Activity before, during and after rallies (scene features, model output)

| Interval kind | Persons / frame | In court / frame | Mean in-court foot speed (units/s) | Share moving | Movement coherence |
|---|---|---|---|---|---|
| active play | 2.35 | 1.88 | 0.064 | 0.47 | 0.63 |
| between rallies | 2.12 | 1.76 | 0.092 | 0.50 | 0.62 |
| difficult (in play) | 2.27 | 1.92 | 0.053 | 0.37 | 0.58 |

There is **no separation** between active play and between-rally time in these aggregates. Between-rally speed is even higher: players walk to positions and retrieve balls, while during play the detected players are often the set-up near players. With about 28 % of players detected, these scene numbers mostly measure which players the detector happened to see. They are not evidence that player features would or would not help the classifier.

### 6.7 Runtime (Apple M3 Pro, 36 GB, macOS 26.4)

- **Per frame** (960 px proxy frames, 5 Hz, run `p0-pilot-2`; per-recording medians):

| | Median | p95 |
|---|---|---|
| Rectangle request | 4.4–4.5 ms | 5.1–6.7 ms |
| Pose request | 5.1–5.5 ms | 5.8–6.5 ms |

- **Per recording:** 225 frames in 3.4–4.3 s of wall time, including decode.
- **Process:** about 0.56 CPU cores busy on average; peak resident memory 653 MB for the whole RallyLab process.
- **GPU utilisation: not measured.** Per-process GPU figures need `powermetrics` as root, which was not used.
- **Concurrent load:** all runs shared the machine with the rally-classifier export (heatmap model on the GPU), so these timings are under load, not a clean benchmark.
- **Resolution:** at the originals' 1080p–4K the cost per frame will be higher; not measured.

### 6.8 Common failure modes (seen in the overlays and the Player Lab)

1. Small and far players missed by the rectangle request: the dominant failure, and the whole court on the distant camera.
2. Crowded indoor scenes where the rectangle request finds almost no one and the pose request finds several.
3. Two adjacent players in one box: net clusters and far pairs. The tracker then shares or switches identities, flagged ambiguous.
4. Court lane false positives: bystanders beside the posts inside the 15 % margin.
5. Court lane false negatives: a server standing behind the end line and outside the lane.
6. Vision extending the box of a person cut off by the frame edge beyond it (down to y = −0.25). The box is kept raw; the validator rule was corrected to require overlap only.
7. A person walking right past the lens triggering `suspected_camera_cut` in a fixed-camera recording. It cost one tracker reset.
8. One implausible pose (joints on ceiling lights).

## 7. Corrections made during the pilot

- **Box rule.** The validator first refused 7 boxes "outside the frame". These were Vision's own extended boxes for cut-off people, so the rule was wrong, not the data. The rule now requires a box to overlap the frame; the contract says so, and a regression test covers it.
- **Window capture.** The in-app capture of the whole window (AppKit view caching) left out SwiftUI controls and text, so it was removed. Snapshot now saves the exact composed frame with its facts. Whole-window images are taken with `screencapture -l` while a scripted step holds, each verified to show its own step.

## 8. Detector accuracy is not classifier benefit

Every number above describes the detector and tracker on development footage. None of it says whether player features improve rally cutting. That requires the matched ablation: the same folds, the same ball features, the same decoder, A against B/C/D on grouped recordings, the scoring contract's metrics, and independent evidence before any production claim (D-001). It is neither implemented nor authorised.

## 9. Recommendation and owner approval gate

**Finding.** Player detection alone, as tested (Vision rectangles on 960 px proxies), is **not reliable enough** to feed a classifier ablation: about 7 of 10 on-court players are missing, worst indoors, which is where the ball detector is weakest too. Box quality, pose plausibility, identity on separated players, the guards, the format and the runtime are all adequate. The weak point is detection.

**Recommended next experiment (P1, bounded, still research-only), for the owner's approval:**
1. **Resolution.** The same plan and audit on the **originals** at full resolution, run once the rally-classifier export has released the footage share. This measures how much of the 72 % miss rate is the 960 px proxy.
2. **Pose-as-person.** Rectangles ∪ pose bounds as the tracker's input, audited on the same 36 frames.
3. **One alternative detector,** only after its licence provenance is checked and recorded (D-012's spirit; nothing Ultralytics-derived). Candidates must be on-device-capable; the choice is the owner's.
4. **Gate to the classifier ablation (B/C/D).** Owner-set on-court recall and false-"in" targets, measured on a **second, independent** audit sample with a person's counts (not the reviewer used here), plus a court-membership method that handles servers and bystanders.

**Decisions requested from the owner.**
- Accept D-034 as proposed, or amend it.
- Whether the experiment ledger's six `detector_evaluation` rows should be copied into Scratch's ledger.
- Approve or decline P1 items 1–3 and set the item-4 targets.
- Whether a person should re-count the 36 audit frames (the sheet is ready).

No training, production change, bulk processing or migration is requested.
