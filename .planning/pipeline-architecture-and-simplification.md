---
name: pipeline-architecture-and-simplification
description: Full walkthrough of the rally-detection pipeline — every stage, every option (live vs dead), and ranked approaches to simplify it
status: reference
created: 2026-06-18T02:58:19Z
updated: 2026-06-18T02:58:19Z
---

# BumpSetCut Rally-Detection Pipeline — Architecture & Simplification

This document maps **every step and every option** in the current rally-detection
pipeline, then lays out **multiple approaches to simplify it** and **how to choose
between them**. It is written against the code as it exists on disk on the
`multi-court-trajectory-selection` branch (2026-06-18), including the in-flight
letterbox, serve-signature, and rally-score work.

> Sourcing note: the stage descriptions and the LIVE/DEAD inventory were produced
> by reading the actual source (`YOLODetector`, `KalmanBallTracker`,
> `BallisticsGate`, `MovementClassifier`, `QuadraticFit`, `RallyDecider`,
> `SegmentBuilder`, `VideoProcessor`, `VideoExporter`, `ProcessorConfig`). Where
> the code is internally inconsistent, that is called out rather than smoothed over.

---

## 1. Pipeline at a glance

```
        ┌─────────────┐   per processed frame
video → │ 0. Frame    │ ──────────────────────────────────────────────┐
        │   extract   │  (dynamic stride: dense while tracking)        │
        └─────────────┘                                                │
              ↓ CVPixelBuffer                                          │
        ┌─────────────┐                                                │
        │ 1. Detect   │  YOLO (CoreML) → dedupe → static suppression   │
        │ YOLODetector│  ⇒ [DetectionResult] (bbox + confidence)       │
        └─────────────┘                                                │
              ↓                                                         │
        ┌─────────────┐                                                │
        │ 2. Track    │  Kalman predict → Mahalanobis associate →      │
        │ KalmanBall- │  update / spawn / prune ⇒ N live tracks        │
        │ Tracker     │  (one per ball / court)                        │
        └─────────────┘                                                │
              ↓ tracks                                                  │
        ┌─────────────┐                                                │
        │ 3. Gate     │  per track: parabola fit + R² + curvature      │
        │ Ballistics- │  floor + span + gravity sig + supported-ball   │
        │ Gate        │  veto + loop veto ⇒ ValidationResult           │
        │   ├ 3b. MovementClassifier (airborne/rolling/carried)        │
        └─────────────┘                                                │
              ↓ validated tracks                                       │
        ┌─────────────┐                                                │
        │ 4. Select   │  bestTrack(): quality-first pick of THE rally  │
        │ (multi-court)│ trajectory, with size/age tiebreak + sticky   │
        └─────────────┘                                                │
              ↓ isProjectile + ballY for the selected track            │
        ┌─────────────┐                                                │
        │ 5. Decide   │  RallyDecider hysteresis: start after          │
        │ RallyDecider│  startBuffer of projectile; end on timeouts    │
        └─────────────┘                                                │
              ↓ isActive (bool stream)                                 │
        ┌─────────────┐                                                │
        │ 6. Build    │  SegmentBuilder: toggle→ranges, merge gaps,    │
        │ Segments    │  drop shorts, apply preroll/postroll           │
        └─────────────┘                                                │
              ↓ [RallySegment]                                         │
        ┌─────────────┐                                                ┘
        │ 7. Output   │  Metadata (prod) │ Debug MP4 │ Export cut clips
        └─────────────┘
```

Two side artifacts feed off the same loop:
- **FrameEvidence capture** (opt-in `collectFrameEvidence`) records per-frame
  signals so **RallyLab** can replay decisions without re-running detection.
- **Serve signature / Rally score** (new, RallyLab-only, flag-only) are computed
  from that evidence and currently change nothing in the pipeline.

---

## 2. Stage-by-stage detail

### Stage 0 — Frame extraction & stride
- The production path (`processVideoMetadata`) walks the video with a **dynamic
  stride** from `tracker.recommendedStride(currentTime:)`: it processes nearly
  every frame while a ball is actively tracked (dense parabola sampling) and skips
  more frames when idle (speed).
- `activeTrackingStride` (config, default **2**) is the reference stride; the debug
  path uses a fixed `stride = 3`.
- Each processed `CMSampleBuffer` is invalidated immediately after use to release
  pixel memory.

### Stage 1 — Detection (`YOLODetector`)
Ordered steps in `detect(in:at:)`:
1. **Inference** via Vision/CoreML. Scaling mode is `.scaleFit` (letterbox) if
   `useScaleFitLetterbox` else `.scaleFill` (stretch). *(New: letterbox keeps the
   ball round on ultrawide/0.5x footage; raw-tensor boxes are de-letterboxed.)*
2. **Decode** — two formats: Vision-native `VNRecognizedObjectObservation`
   (bestv2) or a raw `[1,N,6]` tensor decoded by hand (bestv3, current model).
3. **Same-frame dedupe** — cluster by center within `nmsMergeRadius` (0.02), keep
   highest confidence.
4. **Static-object suppression** — a detection that sits in the same 1/96 grid cell
   for `staticMinStreak` (8) frames is muted for `staticCooldownSec` (10s), to kill
   stationary false positives (court fixtures, a resting ball).

**Options that matter:** `detectionConfidence` (0.6021), `useScaleFitLetterbox`.
**Hard-coded (not in config):** `nmsMergeRadius`, `staticEps`, `staticMinStreak`,
`staticCooldownSec`, `grid`, and an internal velocity threshold — all in
`YOLODetector`. These are real tuning knobs that are **invisible to RallyLab**.

### Stage 2 — Tracking (`KalmanBallTracker`)
Ordered steps in `update(with:)`:
1. **Predict** every existing track's Kalman state forward to the frame time.
2. **Associate** — build all (track, detection) pairs, compute **Mahalanobis
   distance** from each track's covariance, keep pairs within
   `kalmanGateThresholdSigma` (3.0σ), greedy-assign nearest first.
3. **Update** matched tracks with the measurement.
4. **Spawn** a new track for any unclaimed detection that has no stronger neighbor
   (a track of `age ≥ minTrackAgeForPhysics` inside the gate).
5. **Prune** tracks unseen for > 2.0s.

Multi-court falls out naturally: a ball on another court lands outside every
existing track's gate → starts its own track → stays separate.

**Options that matter:** `kalmanGateThresholdSigma` (the real association gate),
the Kalman noise/uncertainty set (`kalmanProcessNoise*`, `kalmanMeasurementNoise`,
`kalmanInitial*Uncertainty`), `minTrackAgeForPhysics`.

> ⚠️ **Known inconsistency (important).** The codebase has **three** association-ish
> config fields but only one drives association:
> - `kalmanGateThresholdSigma` — **LIVE**, the actual gate (Mahalanobis).
> - `trackGateRadius` — **DEAD**, never read.
> - `trajectoryRoiScale` → `TrackedBall.roiRadius()` — **read only for RallyLab's
>   ROI circle drawing**, *not* for association.
>
> So the ROI circle RallyLab draws (a ball-sized spatial radius) is **not** the gate
> the tracker actually uses (a covariance ellipse). The "make the gate ball-sized so
> the drawing equals reality" change was started (the `roiRadius` helper + config
> field exist) but the association loop was **never switched over**. This is the #1
> source of confusion in the tracking stage and a prime simplification target
> (see Approach F).

### Stage 3 — Physics gate (`BallisticsGate.validateProjectile`)
The gate decides, per track per frame, "is this a ball in free flight?" The
**enhanced path is disabled** (`enableEnhancedPhysics = false`), so the **legacy
path always runs**. Ordered checks:
1. **Enough samples** — ≥ `parabolaMinPoints` (4) total and ≥ 4 within the
   `projectileWindowSec` (0.745s) window, else `insufficient`.
2. **Movement classification** (3b below) — computes movement type + gravity
   signature, attached to every result.
3. **Position-jump check** — reject if the last point jumps > `maxJumpPerFrame`
   (10%).
4. **ROI coherence** — predict last Y from a fit of the prior points; reject if off
   by > `roiYRadius` (6%). Uses Kalman-smoothed positions when `useSmoothedTrack`.
5. **Quadratic fit** `y = ax² + bx + c` (`QuadraticFit`):
   - R² ≥ `parabolaMinR2` (0.80);
   - curvature sign correct (gravity direction);
   - **|a| ≥ `minCurvatureMagnitude` (0.004)** — the primary held-ball rejector (a
     straight carry is a degenerate parabola with a ≈ 0);
   - optional upper band `gravityMaxA` if `useGravityBand` (off).
6. **Motion evidence** — need max speed ≥ `minVelocityToConsiderActive` (0.6) OR
   (apex present AND vertical span ≥ `minProjectileSpanY` 0.04).
7. **Supported-ball veto** (when `movementClassifierEnabled`): reject `.rolling`;
   reject `.carried` if `vetoCarriedMovement`; reject if **flat**
   (`verticalMotionScore < maxVerticalMotionForRolling`) **AND** **no gravity**
   (`gravitySignature < minGravitySignature`).
8. **Loop veto** (when `enableLoopRejection`): over `loopCheckWindowSec` (1.0s), if
   horizontal excursion ≥ `loopMinExcursion` (0.05) and net return ≤ excursion ×
   `loopReturnRatio` (0.5), reject as a pickup/scoop loop.

**Returns** `ValidationResult { isValid, rSquared, curvatureDirectionValid,
hasMotionEvidence, positionJumpsValid, confidenceLevel, gravitySignature,
movementType, rejectionReason }`.

### Stage 3b — Movement classifier (`MovementClassifier`)
Runs every gate call. Synthesizes velocity-consistency, smoothness, vertical
motion, and the **gravity signature** (= `min(1, |a| / gravityReferenceCurvature)`,
from the same parabola curvature) into a label: `.airborne` / `.rolling` /
`.carried` / `.unknown`. Only the **veto in step 7** lets the label change the gate
decision.

> ⚠️ **Overlap.** The gravity signature is *both* an input to the classifier *and* a
> standalone term in the flat+no-gravity veto. The classifier's 8 airborne/rolling/
> carried thresholds and the gravity-signature floor are partly measuring the same
> thing (arc curvature). All are LIVE, but this is the densest knob cluster in the
> pipeline and a candidate for consolidation (Approach B).

### Stage 4 — Multi-court selection (`VideoProcessor.bestTrack`)
1. Consider only **fresh** tracks (last detection ≤ 0.3s).
2. Validate each via the gate; keep the **valid** ones.
3. Score: `quality = 0.5·confidenceLevel + 0.5·gravitySignature`, plus
   `trajectorySizeTiebreak·sizeScore` and `0.05·ageScore`.
4. **Sticky**: keep the current selection unless another beats it by
   `trajectorySelectionStickiness` (0.10), to stop flicker between courts.
5. The selected track supplies `isProjectile` and `ballY` to the decider; the full
   candidate list (incl. rejected) is captured for RallyLab.

### Stage 5 — Rally decision (`RallyDecider`)
Hysteresis state machine on the selected track's projectile stream.
- **START:** a projectile run sustained for ≥ `startBuffer` (0.17s);
  `projDropGracePeriod` (5) non-projectile frames are tolerated without resetting
  the clock.
- **END** (first to trip):
  - never before `minRallySec` (1.165s);
  - kept alive if a projectile was seen ≤ 1.0s ago;
  - **sky-ball grace:** if last ball Y ≥ `skyBallTopThreshold` (0.85), allow
    `skyBallTimeout` (2.0s) of no-ball (high arc leaving the top);
  - else hard-end after `min(0.8, endTimeout)` of no ball;
  - soft-end if no projectile > 1.5s and ball rate < 0.5/s;
  - fallback hard timeout `endTimeout` (0.40s).
- Evidence sliding window `windowSec` (0.8s) feeds the ball-rate calc.

### Stage 6 — Segment building (`SegmentBuilder`)
- `observe(isActive:at:)` turns the bool stream into raw ranges.
- **Merge** ranges separated by ≤ `minGapToMerge` (1.35s).
- **Drop** ranges shorter than `minSegmentLength` (2.61s).
- **Pad** with `preroll` (2.0s) / `postroll` (0.5s); short rallies cap preroll at
  0.5s to avoid over-long lead-ins on false starts; clamp to [0, duration].

### Stage 7 — Output
- **Production:** `processVideoMetadata` writes `ProcessingMetadata` (segments +
  stats); it does **not** cut video. Includes the per-segment `ballSizeTrend`
  (stored, **not consumed** by any decision).
- **Debug:** `processVideoDebug` writes a full-length annotated MP4 via
  `DebugAnnotator` (boxes, trails, HUD).
- **Export:** `VideoExporter` cuts/concatenates the padded segments
  (passthrough when possible, re-encode otherwise; optional watermark). Reads no
  config — boundaries arrive pre-padded.
- **DEAD:** `processVideoLegacy` (direct trimmed export) has **no callers**.

### Side harness — RallyLab (eval/tuning)
Replays `FrameEvidence` through `EvidenceReplayer` → `rawPredictions`, scores them
against hand labels (`RallySegmentationScorer`, F1/precision/recall/MAE), and runs a
parameter **sweep** over six post-detection params. Detection-time params (anything
that changes what's detected/tracked/gated) require a **re-run**. New flag-only
layers: **serve signature** (opening-window size trend) and **rally score**
(weighted blend: serve + travel + continuity + sizeDynamics), displayed as a
stacked contribution bar.

---

## 3. The options inventory — LIVE vs DEAD

ProcessorConfig has **~90 fields**. Roughly **26 (~29%) are dead** — defined but
never read in any live path (some only appear in `validate()`, which is itself
never called in production, or in `withModifications()`, used only by the debug
TrajectoryDebugger).

### Fully LIVE clusters (keep)
- **Detection:** `detectionConfidence`, `useScaleFitLetterbox`.
- **Kalman (6):** all of `kalmanProcessNoise*`, `kalmanMeasurementNoise`,
  `kalmanInitial*Uncertainty`, `kalmanGateThresholdSigma`.
- **Tracking:** `minTrackAgeForPhysics`, `activeTrackingStride`, `trajectoryRoiScale`
  (viz-only — see caveat).
- **Gate physics:** `parabolaMinPoints`, `parabolaMinR2`, `projectileWindowSec`,
  `maxJumpPerFrame`, `roiYRadius`, `minCurvatureMagnitude`, `minProjectileSpanY`,
  `minVelocityToConsiderActive`, `yIncreasingDown`, `useGravityBand`, `gravityMaxA`,
  `useSmoothedTrack`.
- **Movement classification (14):** `movementClassifierEnabled`,
  `minClassificationConfidence`, `minGravitySignature`, `gravityReferenceCurvature`,
  `vetoCarriedMovement`, and the 8 airborne/rolling/carried thresholds.
- **Multi-track selection (7):** `trajectorySizeTiebreak`,
  `trajectorySelectionStickiness`, `trajectoryRoiScale`, `enableLoopRejection`,
  `loopCheckWindowSec`, `loopReturnRatio`, `loopMinExcursion`.
- **Rally + export (9):** `startBuffer`, `endTimeout`, `projDropGracePeriod`,
  `skyBallTopThreshold`, `skyBallTimeout`, `preroll`, `postroll`, `minGapToMerge`,
  `minSegmentLength`.
- **Memory limits (core 5 + debug 5):** live, but the debug 5 only matter in the
  debug path.

### DEAD — safe to delete (≈26 fields)
- **Parameter Optimization / A/B (7, all dead):** `enableParameterOptimization`,
  `optimizationMode`, `maxOptimizationTimeHours`, `enableABTesting`,
  `abTestingSplitRatio`, `statisticalSignificanceLevel`, `minimumSampleSize`.
- **Quality Scoring (7 of 8 dead):** `enableQualityScoring`,
  `excellentQualityThreshold`, `goodQualityThreshold`, and the 4 weights
  (`velocityConsistencyWeight`, `accelerationPatternWeight`, `smoothnessWeight`,
  `verticalMotionWeight`). The weights are only checked to *sum to 1.0* in
  `validate()`; the actual score uses fixed 1/3 weights. `minQualityScore` is read
  only inside the dead enhanced path.
- **Metrics Collection (4 dead):** `enableAccuracyMetrics`, `enablePerformanceMetrics`,
  `maxProcessingOverheadPercent`, `performanceAlertThreshold`.
- **Memory pressure (3 dead):** `enableMemoryPressureDetection`,
  `memoryPressureThresholdMB`, `reduceQualityUnderMemoryPressure`.
- **Enhanced-physics thresholds (4 dead):** `excellentR2Threshold`,
  `goodR2Threshold`, `acceptableR2Threshold`, `maxAccelerationDeviation`.
- **Stale physics (2 dead):** `accelConsistencyMaxStd`, `gravityMinA`.
- **Stale association (1 dead):** `trackGateRadius`.

### Effectively dead subsystem
- **Enhanced Physics Validation** (`enableEnhancedPhysics = false`):
  `validateProjectileEnhanced`, `ParabolicValidator`, `TrajectoryQualityScore` are
  never executed. The toggle + its remaining fields are reachable only by flipping
  the flag — which has been off "to fix processing issues." Either delete the
  subtree or finish/justify it.

---

## 4. Problems & redundancies (the case for simplifying)

1. **~26 dead config fields** plus an entire dead validation subtree (enhanced
   physics) and a dead processing path (`processVideoLegacy`). Pure noise that makes
   the config look far more complex than the live pipeline is.
2. **Three association params, one real.** `trackGateRadius` dead; `trajectoryRoiScale`
   drives only the RallyLab drawing, not the gate. The visual ROI ≠ the real gate.
3. **Dense, overlapping physics knobs.** Gravity signature, the 8 movement-class
   thresholds, the curvature floor, and the supported-ball veto all key off the same
   parabola curvature in different guises. Hard to reason about; easy to double-tune.
4. **Hidden knobs.** The static-suppression + NMS constants in `YOLODetector` are
   real tuning levers but live as hard-coded constants invisible to RallyLab.
5. **Decisions split across altitudes.** "Is this a rally?" is decided partly
   per-frame (gate), partly in selection (bestTrack), partly in the decider
   hysteresis, partly in segment building — with the new per-segment rally-score
   sitting outside all of it. No single place owns the verdict.
6. **Two parallel "rally-likelihood" systems forming.** The hand-tuned gate/veto
   stack and the new weighted rally-score measure overlapping things. Without a plan
   they'll drift into redundancy.

---

## 5. Approaches to simplify

These are **not mutually exclusive** — they're ordered roughly by risk/scope. A, B,
F are cleanups; C, D, E are rearchitectures.

### Approach A — Dead-code purge (lowest risk, no behavior change)
Delete the ~26 dead fields, the enhanced-physics subtree, `processVideoLegacy`,
`trackGateRadius`, and fold `validate()`/`withModifications()` down to what remains.
- **Pros:** ~30% smaller config; the live pipeline becomes legible; zero behavior
  change; makes every later approach easier. Fully testable (output identical).
- **Cons:** none of substance. Loses the (unused) optimization/A-B scaffolding —
  fine, it was never wired.
- **Effort:** ~half a day. **Risk:** minimal (deletions verified by the audit).

### Approach B — Consolidate the physics gate
Collapse the overlapping curvature signals into **one** "free-flight score" derived
from the parabola fit (R² × normalized |a| × span), and reduce the movement
classifier to the single discriminator that actually fires the veto. Replace the 8
airborne/rolling/carried thresholds + gravity floor with 2–3 interpretable knobs.
- **Pros:** the gate becomes one formula you can reason about and tune; far fewer
  knobs; the RallyLab sliders map 1:1 to behavior.
- **Cons:** requires re-validating against labels (F1) to prove the collapsed score
  matches the current veto stack; risk of regressing a corner case the dense
  thresholds were quietly catching.
- **Effort:** 1–2 days incl. RallyLab A/B. **Risk:** medium (behavior change).

### Approach C — Promote the weighted rally-score to the verdict (data-driven)
Make the **per-segment rally score** (serve + travel + continuity + sizeDynamics,
already built flag-only) the place where "is this a real rally?" is decided. The
per-frame gate degrades to a cheap *candidate generator*; the segment score
*confirms*. Tune the weights/threshold against labeled F1; later fit them with
logistic regression.
- **Pros:** one transparent, tunable decision point; directly attacks the false
  rallies you actually see (carries); features are orthogonal and inspectable; you
  already have the harness + labels to validate it.
- **Cons:** introduces a second decision system unless you also thin the gate;
  depends on FrameEvidence being available at decision time (today it's RallyLab-only
  — would need to run in-app); camera-geometry-dependent features (serve/travel) need
  the baseline-camera assumption to hold.
- **Effort:** 2–4 days (compute features in-app, gate behind a flag, validate).
  **Risk:** medium.

### Approach D — Re-architect to "detect → score → threshold"
A bigger version of C: explicitly split the pipeline into (1) cheap per-frame
**evidence** (detect/track only), (2) per-candidate **feature extraction**, (3) a
single **scoring + thresholding** stage that owns the rally verdict and the
boundaries. The hysteresis decider becomes a thin smoother over the score, not a
decision-maker.
- **Pros:** one obvious place for every decision; the gate/classifier/veto/score
  redundancy collapses by construction; trivially A/B-able and learnable.
- **Cons:** the largest change; touches every stage; needs a careful migration so
  prod output doesn't regress; more up-front design.
- **Effort:** 1–2 weeks. **Risk:** high (but highest payoff for long-term clarity).

### Approach E — Learned classifier (far end)
Once features are stable (post-C/D), replace hand-weights with a small trained model
(logistic regression → gradient-boosted trees) on the labeled set.
- **Pros:** objective weights; best accuracy ceiling; adapts as you label more.
- **Cons:** needs a real labeled corpus + a training/eval loop; less interpretable;
  overkill until the feature set and labels are mature.
- **Effort:** ongoing. **Risk:** medium, but premature now.

### Approach F — Finish the ball-sized association gate (targeted)
Complete the started work: switch the tracker's association from Mahalanobis to the
Euclidean **ball-sized spatial gate** (`roiRadius`), delete `kalmanGateThresholdSigma`
and `mahalanobisDistance`, so the RallyLab ROI drawing *is* the real gate.
- **Pros:** removes the visual-vs-real ROI confusion; one intuitive knob
  (`trajectoryRoiScale`); simpler tracker.
- **Cons:** Mahalanobis adapts to track uncertainty (a virtue for fast/occluded
  balls) that a fixed ball-sized radius loses; needs A/B on multi-court clips to
  confirm IDs don't churn. Could instead be resolved the *opposite* way — keep
  Mahalanobis, delete `roiRadius`/`trajectoryRoiScale`, and draw the covariance
  ellipse in RallyLab.
- **Effort:** ~1 day. **Risk:** medium (tracking behavior change). **Decision still
  open** — pick one direction and make the drawing match the gate.

---

## 6. How to select the best approach

Use these criteria, in priority order:

1. **Does it change behavior?** Cleanups that don't (A) are free wins — do them
   first, unconditionally. They also shrink the surface every other approach has to
   touch.
2. **Is it validated against labels?** Any behavior change (B–F) must be A/B'd in
   RallyLab against hand-labeled F1 before it ships. If you can't measure it, don't
   merge it.
3. **Does it reduce decision points or add one?** Prefer changes that *consolidate*
   where "is this a rally?" is decided (C, D) over ones that add a parallel system.
4. **Is the prerequisite data mature?** Learned weights (E) need a labeled corpus;
   geometry features (C) need the baseline-camera assumption to hold. Don't build
   ahead of the data.
5. **Effort vs. payoff for where the product is.** If the pain is "config is
   incomprehensible," A+B solve it cheaply. If the pain is "too many false rallies,"
   C is the direct hit. If the pain is "the whole thing is hard to evolve," D is the
   investment.

### Recommended sequence
1. **Approach A now** — purge dead config/paths. No risk, immediate legibility,
   unblocks everything else. *(This is the obvious first move.)*
2. **Approach F (decide + execute)** — resolve the ROI mismatch one way or the other
   so the tracker has one clear association story. Small, removes a recurring source
   of confusion.
3. **Approach C** — promote the rally-score to a real (flag-then-gate) verdict,
   since reducing false rallies/carries is the active product goal and the harness
   already supports validating it. Keep it flag-only until the labeled F1 says it
   beats the status quo.
4. **Approach B** opportunistically, as C subsumes parts of the gate — collapse the
   now-redundant curvature/veto knobs rather than maintaining two systems.
5. **Approach D / E** only if/when the pipeline needs to scale beyond hand-tuning —
   treat them as a future milestone, not now.

**Bottom line:** A is a no-brainer cleanup; F removes a specific known wart; C is the
right *next functional* step because it aligns with the goal you're already pursuing
(serve signature → rally score) and is measurable with tools that already exist. B
folds in naturally behind C. D/E are deliberate future bets, not near-term work.
