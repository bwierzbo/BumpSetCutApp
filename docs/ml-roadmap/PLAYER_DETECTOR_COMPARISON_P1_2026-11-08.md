---
name: player-detector-comparison-p1
status: proposed (owner review); P1 detector comparison run 2026-11-08; research only, no training, no production change
created: 2026-11-09T01:02:44Z
updated: 2026-11-10T20:04:02Z
decision: D-034 (proposed); owner instructions 2026-11-08 "go route B for now and look for a version we can use without training from scratch" and "yes, run the RF-DETR comparison"
experiment: EXP-20261108-player-detector-p1
---

# Player detector comparison (P1): Apple Vision, RTMDet + RTMPose and RF-DETR

**Question.** P0 ([report](PLAYER_POSE_FEASIBILITY_P0_2026-11-08.md)) found that Apple Vision's rectangles box only ≈ 28 % of on-court players. This step asks two things. Can a stronger detector, or tiling, fix that on the same frames? And is there a version we could ship without training from scratch?

**Answer.**
- **Accuracy.** OpenMMLab **RTMDet-m + RTMPose-m**, converted to Core ML and run on the whole frame, boxed **96 % of on-court players** (≈ 237 of 247 over the same 36 audited frames), at 94–100 % on every recording. Vision on the whole frame boxed 26 % and Vision on 3×2 tiles 76 %.
- **Its costs.**
  - About 2.9 false on-court detections per frame: spectators, next-court players, and reflections in a glossy gym floor, all of which the net-based court lane lets in.
  - About 60 ms per frame to detect, plus about 5 ms per person to pose, on a Mac under load.
  - **Its official weights cannot ship.** They are trained on research-terms data.
- **Shippable alternatives, measured (§8).** Roboflow's RF-DETR checkpoints are Apache-2.0, and its own Core ML export worked.
  - **RF-DETR Small and Medium detect as well as RTMDet:** recall **0.96** and 0.96 (237 and 236 of 247), at 0.92–1.00 on every recording, with no floor reflections boxed. On their own they run in 18 ms and 29 ms on the Mac against RTMDet-m's 38 ms.
  - **But the shippable pose doesn't keep up.** Apple Vision's body pose, run on each RF-DETR person crop, posed only **26 %** of the people found: 80 % of those at least 150 px tall, and almost none under 50 px. Enlarging the crops made it worse.
  - **RF-DETR Keypoint (preview, Apache-2.0)** poses everyone it finds, but finds fewer: recall **0.71**, and 0.29 on the distant grass camera. It also boxes far fewer spectators (0.6 false "in" per frame against 3.8–3.9 for Small and Medium).
  - So a shippable *detector* exists today; a shippable *pose* for small, distant players does not, without training.

Nothing here says players improve rally cutting (P0 report §8).

## 1. What ran

| Variant | Detector | Tiles | Run | Code | Features manifest SHA-256 |
|---|---|---|---|---|---|
| vision-1x1 | Apple Vision rectangles r2 + body pose r1 | whole frame | `p1-vision-1x1` | `62ff13a` | `06f6ed4e1001d16c…` |
| vision-3x2 | same | 3×2, overlap 0.15 | `p1-vision-3x2` | `62ff13a` | `17406665cba19e9d…` |
| rtm-1x1 | RTMDet-m person (fp16) + RTMPose-m COCO-17 (fp32), Core ML | whole frame | `p1-rtm-1x1-r2` | `c416ae2` | `e4cadf3db576b0c0…` |
| rtm-3x2 | same | 3×2, overlap 0.15 | `p1-rtm-3x2-r2` | `c416ae2` | `7274074510f82315…` |

- **Setup:** the same 6 recordings, 18 intervals and 1,350 frames at 5 Hz as P0, on the experiment's local scrub-proxy copies. The plans are P0's plan plus `detector`/`tiles`, frozen as `EXP-20261108-player-detector-p1-*.plan.json`.
- **Validation:** every run passes `validate_player_features.py`.
- **Isolation:** Scratch was only read. Its 20,267 files were unchanged in modification time and size from the first P0 snapshot (15:54 MST) to after the last P1 run, and its ledger and manifest hashes were unchanged. Uses are recorded in the experiment's own ledger.

**The models.**
- **Weights:** the official OpenMMLab checkpoints, SHA-256 `235e8209…` (detector) and `5e55be2a…` (pose).
- **Training data,** read from the configs embedded in the checkpoints:
  - detector: COCO train2017 + Objects365 v1, with ImageNet-1k backbone initialisation;
  - pose: AI Challenger + COCO keypoints.
  Research use only.
- **Conversion:** `scripts/player_features/convert_rtm_coreml.py` puts the preprocessing and output decoding inside the graph. Converted package digests are `ea945f1f…` (detector) and `f3cf7252…` (pose).
- **Parity on three real pilot frames:**
  - the ported decoding against mmdet/mmpose: same person counts, box IoU ≥ 0.994, joints within 1.7 px;
  - Core ML against PyTorch: kept scores within 0.023, boxes within 3.1 px, joints within 1.5 px.
- **Pose precision:** the pose model must stay **fp32**. At fp16 its joint scores collapse to ≈ 0 while positions survive, so the Neural Engine is not usable for it as converted.
- **Where the models live:** in the experiment folder; never bundled, never in git.

**Two corrections during P1.**
1. *Strided outputs.* Core ML returns the detector's boxes `[1, 8400, 4]` with strides `[268800, 32, 1]`. The first RTM runs read the buffer as packed, so every box and keypoint was scrambled. That surfaced as "no one found" on the portrait recording, against 8 people in Python on the same frame. The runs were discarded and their outputs deleted; their ledger rows stay. The reader now follows strides, with a regression test for padded fp32 and fp16 layouts. After the fix the Swift path matches Python exactly on the parity frames (10, 16 and 8 persons).
2. *Vision's input path.* The detector refactor gives Vision an RGB `CGImage` instead of the decoder's YUV buffer. Vision's output moved: total persons rose 4 %, but per interval its counts halved on the elevated beach and doubled in the indoor gym. So **Vision's results depend on the input path**, and P1 compares against `vision-1x1` on the new path, not against P0's numbers. Its audited recall, 0.26, is close to P0's 0.28.

## 2. Detection quality (manual audit, same 36 frames as P0)

- **Counted per frame and variant:** distinct on-court players boxed (a duplicate box of one player counts once), and boxes labelled "in" that are not on-court players.
- **Visible on court:** the larger of P0's count and the distinct real players any variant showed. RTM revealed players P0's count had missed, mainly distant ones on the elevated beach, so recall can't exceed 1.
- **Reviewer:** Claude, visually; approximate in crowded frames; **not owner-verified**.
- **Where:** sheet `runs-comparison/p1/audit-p1.csv` in the experiment folder.

| Recording | Visible | vision-1x1 | vision-3x2 | rtm-1x1 | rtm-3x2 |
|---|---|---|---|---|---|
| beach, elevated, crowded | 71 | 0.14 | 0.69 | **0.96** | 0.94 |
| beach, ground, doubles | 16 | 0.25 | 0.75 | **0.94** | 1.00 |
| grass, elevated, 4s | 34 | 0.35 | 0.82 | **1.00** | 1.00 |
| grass, ground, distant | 21 | 0.29 | 0.90 | **1.00** | 1.00 |
| indoor, crowded gym | 62 | 0.21 | 0.81 | **0.94** | 0.90 |
| indoor, portrait, close | 43 | 0.44 | 0.67 | **0.95** | 1.00 |
| **all** | **247** | **0.26** | **0.76** | **0.96** | **0.96** |

False on-court ("in") detections per frame:

| | vision-1x1 | vision-3x2 | rtm-1x1 | rtm-3x2 |
|---|---|---|---|---|
| all | 0.1 | 1.5 | 2.9 | 4.6 |
| worst recording | 0.7 (gym) | 5.5 (gym) | 7.0 (beach ground, sideline spectators) | 11.3 (gym) |

**Reading it.**
- RTMDet on the whole frame finds nearly every player Vision misses, including players about 40 px tall on the distant grass camera and the crowded gym.
- Tiling helps Vision a lot (0.26 → 0.76) but adds nothing to RTM. Tiling also produced duplicate half-body boxes along the horizontal tile seam: the cross-tile merge looks for overlap, and two halves of one person lie side by side.
- With a detector that finds everyone, **court membership becomes the limiting step**. The net-based lane counts seated spectators, next-court players and floor reflections as "in", most of all for ground-level cameras.

## 3. Pose coverage

- **RTMPose poses every person RTMDet keeps** (top-down, up to 40 per frame; pose share 1.0). In P0, Vision paired a pose with 29–84 % of its boxes, by interval.
- **Plausibility:** RTMPose skeletons were plausible on standing, moving and crouched players in the reviewed frames.
- **Failures:** it fails on a player cut off by the frame edge close to the camera, as Vision does, and draws skeletons on the floor reflections it boxed.
- **Joint coverage:** RTMPose produces COCO-17, not Vision's neck and root. In `player_features_v1` those slots stay null, so `pfd_v1` features built on neck/root (arm elevation, torso lean) are null for RTM runs, while knee angle, speed and lift remain. A detector-neutral torso (shoulder and hip midpoints) would be a `pfd_v2` decision.
- **Joint scores** are RTMPose's raw SimCC maxima, which can exceed 1; the contract and validator now say so.

## 4. Tracking

The tracker is unchanged. With RTM it receives 10–20 people per frame in the crowded scenes instead of 1–4, so it now meets crowding head-on. Identity continuity under RTM was not separately audited in P1; P0's sequence method applies. False "in" people form tracks too, so court membership must be fixed before scene features such as movement coherence mean anything.

## 5. Runtime (Apple M3 Pro, macOS 26.4, 960 px proxies, under the concurrent rally-classifier export)

| Variant | Wall time per frame (incl. decode) | Detector median | Pose median | Peak process memory |
|---|---|---|---|---|
| vision-1x1 | 15 ms | 3.6 ms | 5.2 ms | 652 MB |
| vision-3x2 | 63 ms | 21 ms | 32 ms | 689 MB |
| rtm-1x1 | 204 ms | 59 ms | 63–227 ms (≈ 5 ms per person) | 650 MB |
| rtm-3x2 | 596 ms | 354 ms | 78–446 ms | 650 MB |

These are Mac numbers with fp32 pose on the CPU/GPU, not iPhone numbers. For a 5 Hz player channel, rtm-1x1 is affordable offline in RallyLab. On a phone it would need the pose model in fp16 (it isn't, as converted), fewer persons posed, or a lighter model.

## 6. Licences: what could ship without training from scratch

The full table, with sources, came from a research pass this session (summarised from primary sources where they exist).

| Candidate | Weights licence | Training-data caveat | Core ML | Verdict for the app |
|---|---|---|---|---|
| **RF-DETR Nano / Small / Medium** (Roboflow) | Apache-2.0, explicitly "commercially usable … closed-source" (README) | DINOv2 backbone; the paper's recipe pretrains on Objects365, and whether the public N/S/M checkpoints descend from it is **unverified** | official `format="coreml"`, experimental | **Best detector candidate** |
| RF-DETR Keypoint (preview) | Apache-2.0, explicit (README table); 40.7 M parameters at 576 px — "xlarge" appears only in the checkpoint's file name, not the PML-licensed XL detector | COCO keypoints; same backbone caveat | own exporter works (fp32; §8) | Measured: lower recall (§8) |
| Apple Vision | system framework, nothing shipped | n/a | built in | Shippable now; weakest detector (§2) |
| YOLOX | repo Apache-2.0, no explicit weight statement | COCO only, trained from scratch (no ImageNet) | not official, simple to convert | Cleanest data lineage, lower accuracy |
| D-FINE COCO-only | repo Apache-2.0; publisher excludes its Objects365 checkpoints | ImageNet backbone | no official path | Possible |
| RTMDet / RTMPose (this run) | no weight licence; data research-terms | COCO + Objects365; AI Challenger | works (§1) | **Research only** |
| Ultralytics YOLO*, YOLOv6/7/9/10 | AGPL / GPL | — | — | Excluded (D-012, copyleft) |
| MediaPipe BlazePose, MoveNet | Apache-2.0 | single-person or ≤ 6 close people | TFLite | Unsuitable for distant multi-person play |

## 7. Recommendation and owner gate

1. **RF-DETR comparison: done (§8).** RF-DETR Small is the detector to carry forward if anything ships. The Objects365 lineage question still needs an answer from Roboflow's documentation or maintainers before that.
2. **Fix court membership before any classifier use.** It is now the bottleneck. Candidate fixes:
   - person-labelled court corners alongside the net corners;
   - a seated/standing filter;
   - suppressing boxes whose foot point lies below the floor line (reflections);
   - for distant cameras, a stricter lane.
   Measure each against this audit.
3. **Tiling:** keep it for Vision only. Fix the seam duplicates if Vision remains in the comparison.
4. **Phone feasibility** (only if a shippable detector wins): fp16 pose with the head kept fp32, on-device timing verified by the owner on the physical iPhone.

**Decisions requested from the owner:**
- choose a pose route for the shippable stack (§8.6): accept Vision's ~150 px floor, fine-tune a licence-clean pose model on our own frames (training: preregistration first), or keep pose research-only (RTMPose);
- whether to ask Roboflow about the Objects365 lineage of the public RF-DETR checkpoints;
- choose a court-membership approach to try (item 2);
- confirm that the RTM weights stay research-only (they do unless you decide otherwise);
- whether a person should recount the 36 frames for both P0 and P1.

No training, production integration, bundling, migration or bulk processing is requested.

## 8. RF-DETR: the licence-clean candidates (owner: "yes, run the RF-DETR comparison")

### 8.1 What ran

| Variant | Model | Pose | Run | Code | Features manifest SHA-256 |
|---|---|---|---|---|---|
| rfdetr-small | RF-DETR Small, COCO, 512 px, Core ML **fp32** | Apple Vision body pose on each person's crop | `p1-rfdetr-small-1x1` | `bee388d` | `b9025e01fd762512…` |
| rfdetr-medium | RF-DETR Medium, COCO, 576 px, Core ML **fp16** | same | `p1-rfdetr-medium-1x1` | `bee388d` | `73fd2d364af9b06a…` |
| rfdetr-keypoint | RF-DETR Keypoint (preview), COCO-17, 576 px, Core ML fp32 | the model's own joints, one pass | `p1-rfdetr-keypoint-1x1` | `bee388d` | `cfd5a89a195ac7f8…` |

- **Same frames and audit as §2:** P0's plan with only `detector` changed (`EXP-20261108-player-detector-p1-rfdetr-*-1x1.plan.json`), whole frame, person score > 0.3 (RTM's operating point). Every run passes `validate_player_features.py`.
- **Weights:** rfdetr 1.12.0's own checkpoint table, MD5-checked on download. SHA-256: Small `d81979a9213a2109…`, Medium `749ff6071828aaff…`, keypoint preview `2b70ddf51d2b9e02…`. Package digests as recorded by the runs: `daf21397…`, `72671231…`, `c7669b44…`. They live in the experiment folder (`models/rfdetr/`), never in git or the app.
- **Conversion:** `scripts/player_features/convert_rfdetr_coreml.py` uses rfdetr's own exporter (`format="coreml"`, marked experimental upstream), so the graph is the one a production build would use. Input: the frame stretched to N×N and ImageNet-normalised. The features are renamed `input` / `boxes` / `logits` / `keypoints` for the app.
- **Parity, on the three parity frames:**
  - the person slot (sparse COCO id 1) gives exactly the person counts rfdetr's own `predict()` gives;
  - the keypoint preview's score is rfdetr's uncertainty-fused one (`trace_alpha` 0.2). Its port matches `predict()` to 2e-6 in score and 1e-4 px in joint position, and a unit test pins the Swift port to rfdetr's torch code;
  - Core ML against eager PyTorch:
    - fp32 boxes IoU ≥ 0.9999 on all three models;
    - Medium fp16 boxes IoU ≥ 0.976, kept;
    - Small fp16 added one borderline person on the gym frame, and the keypoint fp16 dropped and added people there. By the rule fixed before the results, both stay fp32.
  - **Swift against Python on the same sampled frames** (extracted with ffmpeg, run through the Python port):

    | | Swift | Python |
    |---|---|---|
    | Small | 10, 13, 8 | 9, 12, 7 |
    | Medium | 10, 14, 8 | 10, 14, 7 |
    | Keypoint | 8, 17, 3 | 7, 14, 3 |

    Python's near-misses score 0.31–0.39. The app decodes with Core Image and resizes with Core Graphics, while Python uses ffmpeg and torch bilinear without antialias, and that moves borderline scores. So **the app's counts run 0–3 people above the reference on crowded frames.** This is not resolved here. It errs toward finding more, so it does not explain the keypoint preview's low recall, and the decode itself is pinned by tests.
- **Isolation:**
  - Scratch was only read by these runs. Between my last check and the end, its manifests were rewritten at 22:08 MST by the rally-classifier exporter, which started a new export from its own build (`BumpSetCut-celnvfm…`), not by this tool.
  - These runs read only the experiment's local proxy copies, never the SMB share.
  - Uses are recorded in the experiment's own ledger.

**Discarded runs** (outputs deleted; their ledger rows stay):
- an RF-DETR Small run built from a dirty tree;
- an RF-DETR Small run with enlarged pose crops (§8.3);
- a Small run that overlapped a conversion job, and a Medium run stopped part-way;
- three complete runs whose binary carried `7added3-dirty`, because it was built just before the commit. Their outputs were identical to the kept runs.

### 8.2 Detection quality (same 36 frames, same counting rule as §2)

Sheet: `runs-comparison/p1/audit-p1-rfdetr.csv`. The "visible" column comes from `audit-p1.csv`. The counts are mine (approximate in crowded frames, not owner-verified).

| Recording | Visible | rtm-1x1 (§2) | rfdetr-small | rfdetr-medium | rfdetr-keypoint |
|---|---|---|---|---|---|
| beach, elevated, crowded | 71 | 0.96 | 0.94 | 0.96 | 0.73 |
| beach, ground, doubles | 16 | 0.94 | 1.00 | 1.00 | 0.69 |
| grass, elevated, 4s | 34 | 1.00 | 1.00 | 1.00 | 0.79 |
| grass, ground, distant | 21 | 1.00 | 1.00 | 1.00 | **0.29** |
| indoor, crowded gym | 62 | 0.94 | 0.92 | 0.94 | 0.84 |
| indoor, portrait, close | 43 | 0.95 | 0.98 | 0.91 | 0.63 |
| **all** | **247** | **0.96** | **0.96** (237) | **0.96** (236) | **0.71** (175) |

False on-court ("in") detections per frame:

| | rtm-1x1 (§2) | rfdetr-small | rfdetr-medium | rfdetr-keypoint |
|---|---|---|---|---|
| all | 2.9 | 3.9 | 3.8 | **0.6** |
| worst recording | 7.0 (beach ground) | 10.8 (beach ground) | 10.2 (beach ground) | 1.3 (beach ground) |

**Reading it.**
- **Small and Medium equal RTMDet on recall.** They find the distant grass players and the crowded gym as well as RTMDet does, and Medium adds nothing over Small.
- **They box more spectators than RTMDet,** mainly seated people along the sidelines of the ground-level beach and the elevated grass. They box **no floor reflections in the gym,** where RTMDet boxed several.
- **The keypoint preview is conservative:** few false people, but it misses small and distant players. On the distant grass camera it finds none in two of the six frames.

### 8.3 Pose coverage

| Person box height (px, in the 960 px proxy) | rfdetr-small + Vision | rfdetr-medium + Vision | rfdetr-keypoint | rtm-1x1 |
|---|---|---|---|---|
| under 50 | 0.04 | 0.04 | 1.00 (5 people) | 1.00 |
| 50–99 | 0.15 | 0.14 | 1.00 | 1.00 |
| 100–149 | 0.38 | 0.38 | 1.00 | 1.00 |
| 150 and up | 0.80 | 0.80 | 1.00 | 1.00 |
| all detected people | **0.26** (of 15,014) | **0.26** (of 15,214) | 1.00 (of 9,817) | 1.00 (of 14,940) |

- **Vision's floor.** Vision's body pose request finds little in a crop of a person under about 150 px. Enlarging each crop to at least 256 px before Vision saw it made coverage **worse** (0.26 → 0.22): the detail isn't in the pixels. That variant was discarded and its code reverted.
- **On full-resolution originals** (1080p or 4K rather than the 960 px proxies), players are 2–4× taller, so Vision's coverage there is likely higher. It was not measured here, because the pilot is held to the local proxies.
- **Coverage is not quality.** RTMPose and the keypoint preview always return 17 joints, so their 1.00 says nothing about how good a small person's joints are. Joint scores carry that: the keypoint preview's are rfdetr's "findable" probabilities.

### 8.4 Runtime (Apple M3 Pro, macOS 26.4, Debug build; the keypoint run overlapped the exporter's start at 22:08)

| Variant | Wall time per frame | Detector median (in app) | Model alone (Core ML, all units) | Pose median per frame | Peak memory |
|---|---|---|---|---|---|
| rtm-1x1 (§5) | 204 ms | 59 ms | 38 ms | 63–227 ms | 650 MB |
| rfdetr-small | 193 ms | 126 ms | **18 ms** | 24–82 ms | 652 MB |
| rfdetr-medium | 233 ms | 164 ms | 29 ms | 25–83 ms | 651 MB |
| rfdetr-keypoint | 203 ms | 196 ms | 49 ms | — (in the detector) | 650 MB |

The in-app detector times are dominated by a per-pixel Swift loop that builds the normalised input, about 100 ms in the unoptimised Debug build. RTM's input path has no such loop. The "model alone" column is the honest model comparison:
- RF-DETR Small is about 2× faster than RTMDet-m;
- RTMDet-m runs in fp16, while Small runs in fp32.

A production port would build the input with Accelerate (vImage), or move normalisation into the graph.

### 8.5 Licence position after the run

- **Code and Small/Medium/Keypoint-preview checkpoints:** Apache-2.0, per rfdetr's checkpoint table. The Atto/Femto/Pico/XL/2XL checkpoints are PML 1.0 and were not used.
- **Unresolved, recorded in every package's metadata:** the RF-DETR paper pretrains on Objects365 before COCO, and Objects365's terms are reported as non-commercial. Whether that affects the published weights is a legal/owner question. It is not answered here.
- **Vision:** a system framework, nothing shipped.

### 8.6 What this means

1. **Detector.** RF-DETR Small matches the research-only RTMDet on recall, runs faster as a model, and boxes no reflections. It is the detector to carry forward, pending the Objects365 question.
2. **Pose is the gap.** The licence-clean options cover either the big players (Vision, at about 150 px and up) or the found players (the keypoint preview, which misses small ones). Options, each the owner's call:
   - accept pose only for near players;
   - measure Vision on full-resolution frames;
   - fine-tune a licence-clean pose model on our own labelled frames: training, so preregistration first;
   - keep pose research-only with RTMPose.
3. **Court membership** is still the bottleneck for every detector that finds everyone (§7 item 2). RF-DETR's sideline spectators make it slightly worse than RTM's.

Nothing here says players improve rally cutting.

## 9. RF-DETR Keypoint on tiles (owner: "oh lets do the RF-DETR keypoint then")

Same 36 audited frames and counting rule as §2 and §8.2. Plans `EXP-20261108-player-detector-p1-rfdetr-keypoint-2x2.plan.json` (`6927ec47…`) and `-3x2` (`264d3e89…`): the 1×1 plan with `tiles` changed, overlap 0.15, each tile enlarged to the model's 576 px input. Code `bee388d` (the build of the 1×1 run). Runs `p1-rfdetr-keypoint-2x2` (manifest `4bd9ccf79f90c548…`) and `p1-rfdetr-keypoint-3x2` (`8374cd9e52862fa5…`), both 1,350 frames, exit 0. Audit: `runs-comparison/p1/audit-p1-rfdetr-keypoint-tiles.csv` in the experiment (reviewer counts, not owner-verified; crowded-gym rows rough).

| Recording | Visible | RTM 1×1 | KP 1×1 | KP 2×2 | KP 3×2 | Extra boxes from a split player 2×2 / 3×2 |
|---|---|---|---|---|---|---|
| bch_ele | 71 | 0.96 | 0.73 | 0.92 | 0.94 | 13 / 12 |
| bch_gnd | 16 | 0.94 | 0.69 | 0.81 | 0.94 | 1 / 2 |
| grs_ele | 34 | 1.00 | 0.79 | 0.91 | 0.94 | 4 / 7 |
| grs_gnd (distant) | 21 | 1.00 | 0.29 | 0.62 | 0.71 | 4 / 4 |
| ind_land (rough) | 62 | 0.94 | 0.84 | 1.00 | 1.00 | 25 / 25 |
| ind_port | 43 | 0.95 | 0.63 | 0.93 | 0.93 | 0 / 0 |
| **All** | 247 | 0.96 | 0.71 | **0.91** | **0.94** | 47 / 50 |

- Every person the keypoint model finds has a pose (share posed 1.00 in all three variants).
- **New failure: a near player crossing a seam between tile rows comes back as two boxes** (head and shoulders; legs), each with part of a skeleton: 1.3–1.4 extra boxes per frame, most in the crowded gym. A tracker treats each piece as a person, so this must be fixed before the output is usable. Untested fixes: keep the whole-frame pass for large players and take only small ones from the tiles; or merge pieces across a seam.
- False "in" per frame (net lane): 0.6 whole frame, 2.1 at 2×2, 2.7 at 3×2 — more pixels per person also finds spectators and next-court players.
- Time per frame, Debug build: median detector 196 / 773 / 1,151 ms; model alone ≈ 49 / 200 / 300 ms.
- The source project was only read; its exposure log and new rally-classifier files changed at 22:30 on 2026-11-09, written by the concurrent rally-classifier exporter (its refs), not by these runs (0 player-feature rows there; 12 in the experiment's own ledger).

