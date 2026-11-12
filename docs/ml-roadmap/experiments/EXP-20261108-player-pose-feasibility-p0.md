---
id: EXP-20261108-player-pose-feasibility-p0
status: done — feasibility pilot run 2026-11-08 (research only; no training; next step needs the owner)
created: 2026-11-08T23:12:03Z
updated: 2026-11-10T21:10:33Z
approved_by: owner assignment "Player Detection, Tracking and Pose Feasibility (Phase P0)" and "Additional authorization — RallyLab player-model pilot testing", 2026-11-08 (bounded pilot; no training)
decision: D-034 (accepted, research scope); D-001 production scope unchanged; D-002, D-010, D-017, D-030, D-031 honoured
pr: research/player-pose-feasibility-p0
---

# EXP-20261108-player-pose-feasibility-p0 — Apple Vision people, tracking and pose on development footage

**Purpose.** Measure whether player boxes, tracks and 2D poses can be extracted reliably enough to justify the classifier ablation (A ball only, B + positions and movement, C + poses, D + interaction). This is not a classifier experiment, and it makes no claim about rally cutting. Full method, results and recommendation: [PLAYER_POSE_FEASIBILITY_P0_2026-11-08.md](../PLAYER_POSE_FEASIBILITY_P0_2026-11-08.md).

## Inputs

| What | Identity |
|---|---|
| Plan | [`EXP-20261108-player-pose-feasibility-p0.plan.json`](EXP-20261108-player-pose-feasibility-p0.plan.json), SHA-256 `e84f462880b5698441ca06ed07ad749713fe39225e5522f55b8a551d13631fcd` (frozen) |
| Source project (read only) | Scratch; manifest `8dea6dbe14bd21b3…`, project.json `1364ee92aa269f71…`, exposure ledger `eb6feb185b25b20e…` — all three unchanged after the runs |
| Recordings | 6 train-split, continuous, rally-classifier `standard` recordings, two per surface (list in the plan and §4 of the report); withheld closure refused before any video was opened |
| Footage | the six recordings' local scrub proxies (960 px long side), copied into the experiment with a SHA-256 check |
| Detector | Apple Vision on macOS 26.4 (25E5207k): `VNDetectHumanRectanglesRequest` r2 (full body), `VNDetectHumanBodyPoseRequest` r1; system models, nothing bundled |
| Settings | 5 Hz on presentation timestamps; `ptrk_v1`, `court_net_lane_v1`, `pfd_v1` at the defaults recorded in each run manifest |
| Experiment folder (local, not in git) | `~/Movies/RallyLab/Experiments/player-pose-p0` (footage copies, its own `manifests/exposure-log.json`, runs, the local visual report) |

## Runs

| Run | Code | Features manifest SHA-256 | Note |
|---|---|---|---|
| `p0-pilot-1` | `60b7693` + uncommitted tool changes | `6b8e8f813b03ef861ff93087df19e7a98cc2cbc62107f258f2050e73d0dec9b0` | audited (`diagnostics/audit-filled.csv`), GUI screenshots |
| `p0-pilot-2` | `7f75e2d` + uncommitted decision-log edit | `c42c6f9be39b6bc0f661441be2c17da5f81b5077dc7a5fb00fe2ba81d007d64a` | identical to pilot 1 on 1,350/1,350 frames apart from `ms` |
| `p0-pilot-3` | `0bcb381` (clean; the tool's code is unchanged since) | `954826e99e73000d193fac9a7751976dbf07a6c017ca43dc0005613f4525fa1e` | canonical; identical to pilot 1 on 1,350/1,350 frames apart from `ms`; Scratch unchanged before and after |

## Results (detail in the report)

- **Detection.** Rectangle recall on on-court players was **0.28** (68 of about 239, 36 frames; approximate counts by the reviewer, not owner-verified). By recording: 0.29–0.44, except the crowded indoor landscape gym at **0.06**. False on-court detections: 0.08 per frame.
- **Pose.** The body-pose request found players the rectangles missed in 14 of the 36 frames (up to 5 per frame indoors). A detected player's pose reported 14–17 of 19 joints; poses were plausible in all 25 judgeable frames.
- **Tracking.** Identities were stable for separated players. One identity switch occurred in a net cluster, flagged ambiguous on exactly those frames. Fragmentation follows detection gaps.
- **Activity.** Scene movement features did not separate active play from between-rally time at this recall.
- **Runtime (pilot 3).** About 4.0 ms (rectangles) + 4.9 ms (pose) median per 960 px frame on an M3 Pro, under concurrent load; 0.54 CPU cores; 652 MB peak process memory; GPU not measured.

## Conclusion

Player detection as tested is not reliable enough to feed the classifier ablation. Recommended next, subject to the owner's approval (report §9):
1. originals at full resolution;
2. rectangles ∪ pose as the person set;
3. one licence-cleared alternative detector;
4. a person-verified audit gate before any B/C/D ablation.
