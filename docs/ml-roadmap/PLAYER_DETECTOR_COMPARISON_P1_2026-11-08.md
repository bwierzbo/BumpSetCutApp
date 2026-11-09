---
name: player-detector-comparison-p1
status: proposed (owner review); P1 detector comparison run 2026-11-08; research only, no training, no production change
created: 2026-11-09T01:02:44Z
updated: 2026-11-09T01:02:44Z
decision: D-034 (proposed); owner instruction 2026-11-08 "go route B for now and look for a version we can use without training from scratch"
experiment: EXP-20261108-player-detector-p1
---

# Player detector comparison (P1): Apple Vision against RTMDet + RTMPose, whole frame and tiled

**Question.** P0 ([report](PLAYER_POSE_FEASIBILITY_P0_2026-11-08.md)) found that Apple Vision's rectangles box only ≈ 28 % of on-court players. This step asks two things. Can a stronger detector, or tiling, fix that on the same frames? And is there a version we could ship without training from scratch?

**Answer.**
- **Accuracy.** OpenMMLab **RTMDet-m + RTMPose-m**, converted to Core ML and run on the whole frame, boxed **96 % of on-court players** (≈ 237 of 247 over the same 36 audited frames), at 94–100 % on every recording. Vision on the whole frame boxed 26 % and Vision on 3×2 tiles 76 %.
- **Its costs.**
  - About 2.9 false on-court detections per frame: spectators, next-court players, and reflections in a glossy gym floor, all of which the net-based court lane lets in.
  - About 60 ms per frame to detect, plus about 5 ms per person to pose, on a Mac under load.
  - **Its official weights cannot ship.** They are trained on research-terms data.
- **Shippable alternatives.**
  - **RF-DETR Nano/Small/Medium** (Roboflow) is the one person detector whose weights are explicitly licensed for closed-source commercial use (Apache-2.0), with an official, experimental Core ML export.
  - **RF-DETR Keypoint** (preview, Apache-2.0) and **Apple Vision's body pose** are the matching pose options.
  - None of them is measured here yet; that is the recommended next run (§7).

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
| RF-DETR Keypoint (preview) | Apache-2.0, explicit | COCO keypoints; same backbone caveat | export contract listed | Pose candidate (preview) |
| Apple Vision | system framework, nothing shipped | n/a | built in | Shippable now; weakest detector (§2) |
| YOLOX | repo Apache-2.0, no explicit weight statement | COCO only, trained from scratch (no ImageNet) | not official, simple to convert | Cleanest data lineage, lower accuracy |
| D-FINE COCO-only | repo Apache-2.0; publisher excludes its Objects365 checkpoints | ImageNet backbone | no official path | Possible |
| RTMDet / RTMPose (this run) | no weight licence; data research-terms | COCO + Objects365; AI Challenger | works (§1) | **Research only** |
| Ultralytics YOLO*, YOLOv6/7/9/10 | AGPL / GPL | — | — | Excluded (D-012, copyleft) |
| MediaPipe BlazePose, MoveNet | Apache-2.0 | single-person or ≤ 6 close people | TFLite | Unsuitable for distant multi-person play |

## 7. Recommendation and owner gate

1. **Run RF-DETR (Small, then Medium) through the same comparison** before deciding anything. Use the same plan, the same 36 frames and the same audit, with Vision body pose (shippable) and RF-DETR Keypoint as pose options.
   - Needs: a separate Python environment with `rfdetr` and its experimental Core ML export, and a check of the Objects365 lineage question with Roboflow's documentation or the maintainers.
   - Research only until the owner decides; nothing is bundled.
2. **Fix court membership before any classifier use.** It is now the bottleneck. Candidate fixes:
   - person-labelled court corners alongside the net corners;
   - a seated/standing filter;
   - suppressing boxes whose foot point lies below the floor line (reflections);
   - for distant cameras, a stricter lane.
   Measure each against this audit.
3. **Tiling:** keep it for Vision only. Fix the seam duplicates if Vision remains in the comparison.
4. **Phone feasibility** (only if a shippable detector wins): fp16 pose with the head kept fp32, on-device timing verified by the owner on the physical iPhone.

**Decisions requested from the owner:**
- approve the RF-DETR comparison (item 1);
- choose a court-membership approach to try (item 2);
- confirm that the RTM weights stay research-only (they do unless you decide otherwise);
- whether a person should recount the 36 frames for both P0 and P1.

No training, production integration, bundling, migration or bulk processing is requested.
