---
name: player-features-contract
status: proposed v1 (owner review); written by `RallyLab --player-lab-run <experiment> --source-project <project> --plan <plan.json> --run <name>` (`RallyLab/PlayerResearch/PlayerFeaturesRun.swift`); validated by `scripts/player_features/validate_player_features.py`
created: 2026-11-08T22:34:07Z
updated: 2026-11-09T01:02:44Z
decision: D-034 (proposed); honours D-002, D-010, D-017, D-021, D-030, D-031
---

# Player features, version `player_features_v1`

What the player-feasibility research tool (Phase P0, [report](PLAYER_POSE_FEASIBILITY_P0_2026-11-08.md)) writes per recording: the people Apple Vision found on sampled frames, their 2D poses, a deterministic tracker's identities, court membership as evidence, and compact derived features. It is a **separate** format from the rally classifier's: it never changes `rcf_v1`, never adds a file to a `rally_classifier_dataset_v1` folder, and nothing in the app or the processing pipeline reads it. A later fusion step joins the two by recording identity and tick (§6).

Nothing in it is ground truth. A detection, a pose or a track is a model's output. A missing joint is null, a person without a pose has no pose, and a frame the tool did not analyse says so. None of these is ever converted into a label (D-010).

## 1. Layout

The tool works in a separate **experiment folder** and only reads the source project (owner, 2026-11-08). Nothing in the source project is written: not its sessions, marks, splits, footage properties, manifests or exposure ledger. The project is also never opened through `ProjectsModel`, which can rewrite derived files.

```
<experiment>/                            e.g. ~/Movies/RallyLab/Experiments/player-pose-p0
  footage/<recordingId>.mp4              byte-for-byte copies of the source project's local scrub proxies (SHA-256 checked)
  manifests/exposure-log.json            the experiment's own ledger (ExposureLog format, kind detector_evaluation)
  runs/<run>/
    features/                            the format (validated, strict: nothing else may be in it)
      player-features-manifest.json      §2
      frames/<recordingId>.jsonl         §3, one line per sampled frame
    diagnostics/                         not part of the format
      overlays/<recordingId>/<interval>_<tick>.jpg
      audit-sample.csv                   frames for manual review, columns blank until a person fills them
      summary.json                       per-interval numbers (PlayerFeaturesSummary; the Player Lab window shows the same)
      runtime.json                       per-recording timings, process CPU and peak memory
    gui-snapshots/                       Player Lab snapshots (frame PNG + facts JSON)
```

It is never inside a project or a `rally_classifier_dataset_v1` folder. `RallyLab --player-lab <experiment>` opens the Player Lab window over the runs.

## 2. `player-features-manifest.json`

| Field | Meaning |
|---|---|
| `schemaVersion` | `"player_features_v1"`; the validator refuses any other value |
| `createdAt`, `generator` | ISO 8601 UTC; `{tool, codeSha, run, decoded, sourceProject, experiment, ledger}`. `codeSha` is the build's `source-revision.txt`, and `tool` carries the plan file's SHA-256 |
| `project`, `splitManifest` | the source project, and the SHA-256 of its `project.json`, `sessions/`, `validation.json` and `manifest.json` when the run was made. The split manifest is read **as written**, audited (no hard finding), and refused when stale; this tool never rebuilds it |
| `withheld` | `{names, sourceIds, fingerprints, closureSha256}`: the full closure (`ReservedVideos.lineageWithheldNames ∪ reservedNames`) plus every content fingerprint it was compared with (stored file identities and the withheld recordings' local proxies). `closureSha256` = SHA-256 of `names ⧺ ["--"] ⧺ sourceIds ⧺ ["--"] ⧺ fingerprints` joined by `\n`. An empty closure is refused |
| `timescale` | `600`, the scoring contract's ticks per second |
| `coordinateSpace` | `"vision_normalized_upright"`: origin bottom-left, y up, 0–1, in the frame **after** the track's rotation flag is applied. This is the space `FrameEvidence` uses when `upright` (`ProcessorConfig.applyVideoRotation`, default on), so ball and player coordinates compare directly |
| `jointNames` | the 19 joints of `VNDetectHumanBodyPoseRequest` revision 1, in the order of every `joints` array. A detector with another skeleton writes into these slots: RTMPose's COCO-17 fills 17 of them, and `neck` and `root` stay null |
| `detector` | `name` (`vision` or `rtm`) and its full description, merged with the tiling (`tiles`, `overlap`, `merge`). **vision:** framework, macOS version and build, each request and its revision (`VNDetectHumanRectanglesRequest` r2 with `upperBodyOnly = false`; `VNDetectHumanBodyPoseRequest` r1), pairing rule, compute units, licence note. **rtm** (P1, research only): RTMDet-m person and RTMPose-m COCO-17 as Core ML, the converted packages' canonical digests, the source checkpoints' SHA-256 and training data, NMS and score threshold, precision (detector fp16, pose fp32), licence note |
| `sampling` | `hz`, plus the rule: the first decoded frame at or after `start + k/hz` on the presentation timeline, never the same frame twice; `tick = round(t × 600)` |
| `tracker`, `court`, `derived` | the versions (`ptrk_v1`, `court_net_lane_v1`, `pfd_v1`) and every setting |
| `recordings` | §2.1 |

### 2.1 A recording

| Field | Meaning |
|---|---|
| `recordingId`, `groupId`, `split` | session name; alias group from the source registry; split from the manifest. Only `train`, `dev_val` and `tune` are allowed |
| `surface`, `camera`, `cardOrientation`, `sourceId` | from the card and registry |
| `fingerprint` | the original's identity **as `project.json` stores it**. The original is not read, because it lives on the footage share |
| `decoded` | the file actually decoded: `kind` = `scrub_proxy` (the only kind in v1: the experiment's copy of the recording's ScrubProxy, with the original's frame times and a 960 px long side; originals sit on the footage share and are not read), its content fingerprint, its upright size, the EXIF orientation applied, the nominal frame rate and duration |
| `aspect` | upright width / height. Speeds and distances are in normalised units, which depend on it |
| `recordingType`, `eligibility`, `eligibilityReasons` | the confirmed footage type and the `TrainingEligibility` levels per model. `rally_classifier` must be `standard` or `restricted` |
| `net`, `courtUnknownReason` | the person's net quad (`net-labels.json`), and why court membership is `unknown` for every person in the recording (null when the lane applied) |
| `cutRanges`, `timeBreakingSpans` | `{startTick, endTick, kind}` half-open, from the session (D-030) and from footage-properties spans whose trait breaks time. Proposed and confirmed spans exclude alike; rejected spans count for nothing |
| `intervals` | `{name, kind ∈ active_play · between_rallies · difficult, startSec, endSec, selection}`, non-overlapping. `selection` says whether it was auto-derived from people's marks or chosen by hand, and why |
| `framesFile`, `framesSha256`, `frameCount` | the frames file, its hash and its line count |

## 3. `frames/<recordingId>.jsonl`

One JSON object per sampled frame, in time order. Keys are sorted, and an optional value that is absent is **null** (Swift's encoder omits nil keys; readers treat a missing optional key as null).

| Key | Rule |
|---|---|
| `t`, `tick` | presentation time in seconds; `tick = round(t × 600)`, half away from zero |
| `ms` | the only non-deterministic key: two runs of the same plan on the same machine differ only in `ms` (checked on the P0 pilot: 1,350 of 1,350 frames identical without it), so `framesSha256` differs between runs while the content does not |
| `interval` | the interval it belongs to; `t` lies in `[startSec, endSec)` |
| `seg` | contiguous-segment index. It increments by exactly 1 on a frame whose `reset` is set and is otherwise unchanged |
| `reset` | why this frame starts a segment: `interval_start` (always on an interval's first frame), `gap` (more than 0.5 s since the previous sampled frame), `cut_boundary` / `time_break_boundary` (a boundary of an excluded span in `(previous tick, tick]`; boundaries are tested, not membership, so a span falling between two frames still breaks), or `suspected_camera_cut` (`frameDiff` > 0.2) |
| `frameDiff` | mean absolute difference of 32×18 luminance thumbnails from the previous sampled frame, 0–1. A camera-cut and camera-motion indicator, null at a segment start |
| `masks` | `{ran, skipped, rectFailed, poseFailed}`. Inside a cut range or time-breaking span the frame is written with `ran: false`, `skipped: "cut" \| "time_break"` and no persons: not analysed, which is not the same as finding nobody |
| `persons[]` | `{box {x,y,w,h}, conf, track, state ∈ tentative · confirmed, hits, gap, ambiguous, court ∈ in · out · unknown, pose, derived}` |
| `persons[].box` | as Vision reports it, never clamped: for a person cut off by the frame edge Vision extends the full-body box past it (seen in the pilot down to y = −0.25), so a box must overlap the frame but may extend beyond 0–1. A foot point below the frame is then an extrapolation |
| `persons[].track` | unique within the recording and never reused. A track id belongs to exactly one segment |
| `persons[].ambiguous` | another track's predicted box overlapped this detection almost as well (≥ 0.7 of the winning IoU), so the identity may have switched here |
| `persons[].court` | `court_net_lane_v1`, §4. `unknown` for every person when the recording has no lane |
| `persons[].pose` | `{conf, joints[19]}` with each joint `{x, y, c}` or null, or null when the detector has none (§4). `c` is the detector's raw joint score: Vision's confidence (0–1), or RTMPose's SimCC score, which can exceed 1. A score ≤ 0 is written null. `conf` is Vision's observation confidence, or the mean joint score for RTMPose |
| `persons[].derived` | `pfd_v1`, §5 |
| `unmatchedPoses[]` | poses no person box took: people the rectangle request may have missed |
| `scene` | `{persons, confirmed, inCourt, meanSpeedInCourt, movingShareInCourt, coherenceInCourt, posesInCourt}` over confirmed tracks |
| `ms` | milliseconds: `thumb`, `rect`, `pose` (see the note on determinism above) |

## 4. Association, tracking and court membership

- **Pose → person.** Each detector pairs its own poses with its boxes. *Vision:* a pose belongs to the box that holds the largest share (at least 0.6) of its reported joints, with the box widened by 10 % each side; matching is greedy, ties broken by box index then pose index, and a pose left over goes to `unmatchedPoses`. *RTM:* top-down, so each kept box carries the pose of its own crop (box padded 1.25×, widened to 3:4, 192×256) and `unmatchedPoses` stays empty.
- **Tiling** (optional, `tiles` in the plan). The detector runs on `cols × rows` overlapping tiles of the upright frame. Results are mapped back to frame coordinates and merged: NMS at IoU 0.6, and across tiles a person whose box covers more than 80 % of the smaller one is kept once. Unpaired poses are de-duplicated by bounds IoU 0.5. Side-by-side halves of one person along a tile seam are **not** merged (seen in P1).
- **Tracker `ptrk_v1`.** Constant-velocity prediction of each track's centre, greedy IoU association (at least 0.15) against predicted boxes, ties broken by lower track id then lower detection index. A track is confirmed after 3 observations and ends after 1.0 s unmatched. Every segment boundary resets it, and identities are never assumed to survive one.
- **Court `court_net_lane_v1`.** No court lines are labeled in any project, so the only geometry is the person's net quad. The lane is the posts' span at the net's foot line plus 15 % of the net's width each side, widening linearly toward the camera (×2 at the frame bottom) and narrowing on the far side (−30 % at the frame top). A person whose foot point (box bottom centre) lies in the lane is `in`. It is applied only when the card's camera begins "End line" and the net label's fingerprint equals the recording's stored fingerprint; otherwise every person is `unknown`. `in` is evidence, not proof: spectators and neighbouring-court players inside the lane count in.

## 5. Derived features `pfd_v1`

These are causal: each is computed from the track's own history inside the segment, up to and including this frame. They are measurements, not actions; no "spike" or "dig" is ever inferred from a frame.

| Field | Definition | null when |
|---|---|---|
| `speed` | foot-point speed, normalised units / s, backward difference | first observation of the track in the segment |
| `accel` | change of `speed` / dt | fewer than three observations |
| `turn` | angle between consecutive foot velocities, radians | either speed below 0.05 / s |
| `armElevation` | max over both arms of (wrist.y − shoulder.y) / torso length (neck–root) | neck, root, or a wrist–shoulder pair missing or below confidence 0.2 |
| `torsoLeanDeg` | neck→root axis from vertical | neck or root missing |
| `kneeAngleDeg` | the smaller hip–knee–ankle angle | no leg complete |
| `heightRatio` | box height / trailing 1 s median height (crouching or partial occlusion) | never on an analysed person |
| `lift` | (foot y − trailing median foot y) / median height (jump indicator) | never on an analysed person |

`scene.coherenceInCourt` is the length of the mean unit velocity of the moving in-court confirmed tracks (1 means all move the same way), and is null with fewer than two moving.

## 6. Joining with ball features (future fusion; interface `bpi_v1`)

`RallyLab/PlayerResearch/BallPlayerInteraction.swift` defines the join and the interaction features. It has a reference implementation and unit tests, but is not run on real data in P0 and nothing trains on it:

- **Key.** `(recordingId, tick)`. Each player frame takes the nearest `rcf_v1` step within ±30 ticks (50 ms); both sides use the presentation timeline at 600 ticks/s. With a scrub proxy the frame times are the original's (ScrubProxy keeps every sample's timestamp). This run did not verify that independently against the original.
- **Features.** Nearest in-court (else any) person to the ball and the distance to its box; distance to the nearest usable wrist; approach rate (change of that distance per second within a segment, negative when approaching); the ball's direction change across ±0.2 s when within 0.08 of a person (0.2 s look-ahead, declared); that person's speed; and a confidence = ball confidence × person (pose, else box) confidence.
- **Missing data.** Each output carries `missing` ⊆ {`no_ball_step`, `ball_not_visible`, `no_persons`, `no_pose`, `frame_not_analysed`} and nulls. None of these means non-rally: ball visibility and rally activity are separate (D-010).
- Proximity is evidence of a possible contact, never a contact label.

## 7. Versioning

`schemaVersion`, `ptrk`, `court_net_lane`, `pfd` and `bpi` change independently. A change in column meaning, units, rounding or a rule is a new version with a new validator branch, never an edit of v1.
