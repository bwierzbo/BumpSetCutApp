---
name: rally-classifier-dataset-contract
status: proposed v1 (owner review); written by `RallyLab --project <name> --export-rally-classifier-dataset <dataset>` (`RallyLab/RallyClassifierExporter.swift`, 2026-11-07), not yet run on a real project; `scripts/rally_classifier/validate_dataset.py` validates it
created: 2026-11-03T18:55:00Z
updated: 2026-11-07T17:47:31Z
decision: D-001, D-002, D-010, D-017, D-018 (the isolation and preflight pattern applied to this model), D-021 (time base and excluded spans), D-023, D-031 (per-model eligibility); D-030 (cut ranges, proposed) for compatibility
---

# Rally classifier dataset contract, version `rally_classifier_dataset_v1`

The shape of a training/evaluation dataset for the learned temporal rally classifier ([research document](TEMPORAL_RALLY_CLASSIFIER_RESEARCH_2026-11-03.md)). It follows the L2 package's principles (D-018): generated from the versioned split manifest, physically free of every protected recording, carrying the hash of every file, checked by a fail-closed validator before any trainer reads it. The validator is `scripts/rally_classifier/validate_dataset.py` (standard library only, tests in `scripts/tests/test_validate_rally_classifier_dataset.py`); its `--write-synthetic` writes a complete valid example.

## 1. Layout

```
<name>/                               e.g. Scratch-rally-classifier-20261110-1200
  dataset-manifest.json               §2
  steps/<recordingId>.jsonl           §3, one line per processed frame
  baseline/<recordingId>.json         §3a, the deterministic decider's output per variant (R0, R0′)
```

Nothing else may be in the folder (a stray file fails validation, as in the L2 preflight). The folder's name is the dataset's name; its **digest** is the SHA-256 over the sorted `"<sha256>  ./<relative path>"` lines of every file except `dataset-manifest.json` (the registry's canonical directory digest), recorded in the experiment record together with the manifest's own SHA-256.

## 2. `dataset-manifest.json`

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | `"rally_classifier_dataset_v1"` | refused otherwise |
| `createdAt` | ISO 8601 UTC | |
| `generator` | `{tool, codeSha}` | the exporter and the commit it was built from |
| `project` | string | the RallyLab project |
| `splitManifest` | `{projectJson, sessions, validationJson, manifestJson}` | SHA-256 of each at export time; the dataset is tied to this split version and nothing else |
| `withheld` | `{names: [..], sourceIds: [..], fingerprints: [..], closureSha256}` | the **full withheld closure** at export time (`ReservedVideos.lineageWithheldNames` expanded through every identity: lineage holdout, legacy holdout, final test, candidates, aliases). The validator checks every recording against all three lists and refuses the dataset if the closure is missing or empty — a missing ledger means nothing is proven, not that nothing is withheld |
| `detector` | `{name, canonicalDigest}` | the ball model whose evidence the steps hold (e.g. `ball_heat`, `09620ab77519bd9d`); one detector per dataset |
| `pipelineConfigSha256` | hex | SHA-256 of the serialised `ProcessorConfig` the evidence was produced with (the registry's convention) |
| `timescale` | `600` | ticks per second (the scoring contract's time base) |
| `samplingHzNominal` | number | 30 for multi-frame-only processing; informative — `dt` per step is the truth |
| `featureSchema` | `{version: "rcf_v1", features: [{name, unit, nullable, kind, lookaheadSec}]}` | §4; the order of `features` is the order of `f` in every step |
| `labelSchema` | `{version: "rally_activity_truth_v1", states: {...}, boundaryIgnoreSec, weights: {...}}` | §5 |
| `baseline` | `{replayer: "EvidenceReplayer.decidedRallies", variants: [{name, configSha256, settings: {prerollSec, postrollSec, joinSec, minSegmentSec, servePrimedStart}}]}` | §3a; the variant `r0` is required and its `configSha256` must equal `pipelineConfigSha256` (the committed decider is the benchmark, never a retune); further variants (e.g. `r0_prime`, the D-029 settings) carry their own config hash; names are unique |
| `recordings` | array of §2.1 | one per recording in the dataset |

### 2.1 A recording record

| Field | Type | Meaning / rule |
|---|---|---|
| `recordingId` | string | the session name (e.g. `grs_tri_sun_land_self_01`) |
| `sourceId`, `fingerprint` | string or null | the manifest's confirmed `sourceId` (null when unconfirmed) and the card's file fingerprint |
| `groupId` | string | the recording group (§6); every recording of a group has the same `split` and `fold` |
| `split` | `train` · `dev_val` · `tune` | the split-manifest split; `legacy_holdout`, `lineage_holdout`, `final_test`, `final_test_candidate` can never appear |
| `fold` | integer or null | the development fold the preregistration assigned to the group; null before assignment |
| `surface`, `camera`, `orientation`, `originKind`, `uploader` | strings | from the manifest / card (per-surface and per-camera reporting) |
| `durationSec`, `frameRateNominal`, `vfr` | number, number, bool or null | from the asset; `vfr` null when not measured |
| `aspect` | number | frame width / height after rotation (`sel_size` is in normalised units and depends on it) |
| `upright` | bool | coordinates are in the rotation-applied frame (`FrameEvidence.upright`) |
| `net` | `{x, y, w, h, confidence}` or null | the pipeline's frozen per-video net box (Vision coordinates), null when none was found; `hasNet` is `net != null` |
| `recordingType` | `continuous` · `edited` · `unknown` | from the footage-properties record **as a person confirmed it**; `unknown` when no record exists |
| `eligibility` | `{rallyClassifier: level, fullVideoNegatives: level, reasons: [..]}` | `TrainingEligibility.assess` for this recording at export time; levels `standard` · `restricted` · `not_assessed` · `quarantined` · `ineligible`. **A recording may be in the dataset only with `rallyClassifier ∈ {standard, restricted}`**; `restricted` requires at least one reason and sets `restrictedUse: true` below. **`fullVideoNegatives: standard` is allowed only when `recordingType == continuous`** — `TrainingEligibility.assess` makes an edited recording's negatives `restricted` and an unknown one's `not_assessed`, so any other combination is an inconsistent exporter verdict and the validator refuses the dataset |
| `restrictedUse` | bool | true when `rallyClassifier == restricted`; the trainer keeps such recordings out of headline validation numbers (reported apart) |
| `coverage` | `{state, verifiedCoverageSec}` | `state ∈ {declared_complete, stage1_complete, partial, none}`; `verifiedCoverageSec` from the Stage 1 record (null otherwise) |
| `labelProvenance` | `{method, marksSha256, rallyEventsSha256}` | `method ∈ {legacy_declared, stage1_verified}`; the SHA-256 of `<video>.rallylabels.json` and, when present, of `<video>.rallyevents.json` |
| `rallies` | array of `{rallyId, startTick, endTick, kind, provenance, contactUncertaintyTicks, deadUncertaintyTicks}` | every truth rally: `kind ∈ {rally}` only (missed serves and other are excluded spans, below); `provenance ∈ {legacy_declared, legacy_nil_kind, stage1_reviewed}`; `rallyId` null for legacy marks; uncertainty ticks null for legacy marks, `latest − earliest` for Stage 1 events. `startTick` = the serve **contact** tick (`contacts[0]` of kind serve when present, else `startTime`; Stage 1: `contact.earliest`), `endTick` = the dead tick; `startTick < endTick`; rallies may not overlap (an overlap is an error naming both) |
| `excludedSpans` | array of `{startTick, endTick, kind}` | `kind ∈ {missedServe, other}` marks; the scoring contract's X |
| `cutRanges` | array of `{startTick, endTick}` | D-030 cut ranges, normalised (empty until PR #135 is on `main`; the field is required and may be empty) |
| `timeBreakingSpans` | array of `{startTick, endTick, trait, origin}` | footage-properties spans whose trait `breaksTime` (slow motion, replay, montage, camera angle change) with `origin ∈ {confirmed, proposed}`; **proposed spans restrict exactly like confirmed ones for this dataset** (a proposal never clears, D-031) |
| `nonRallyActivitySpans` | array of `{startTick, endTick}` | Stage 1 `nonRallyActivity` spans (empty today) |
| `exposure` | array of `{date, kind, ref}` | the recording's ledger rows at export time (may be empty, key required) |
| `stepsFile`, `stepsSha256`, `stepCount` | string, hex, integer | the steps file and its hash and line count |
| `baselineFile`, `baselineSha256` | string, hex | the §3a file (`baseline/<recordingId>.json`) and its hash |
| `labelCounts` | `{NON_RALLY, ACTIVE_RALLY, TRANSITION, UNKNOWN, EXCLUDED, NON_RALLY_ACTIVITY}` | integers, must match the steps file |

## 3. `steps/<recordingId>.jsonl`

One JSON object per line, one line per **processed frame** in time order (the frames the pipeline fed to the detector — about 30 Hz in multi-frame mode, never resampled, never interpolated):

```json
{"t": 12.4333, "tick": 7460, "seg": 0, "f": [0.0333, 1, 2, 2, 0.91, 0.62, 1, 0.44, 0.62, 0.021, 0.97, 0.88, 1, 1, 0, 0.09, 0], "y": 1, "w": 1.0}
```

| Key | Rule |
|---|---|
| `t` | seconds on the recording's presentation timeline (`FrameEvidence.time`), strictly increasing within the file |
| `tick` | `round(t × 600)`; the validator recomputes it |
| `seg` | contiguous-segment index, starting at 0 and incrementing by exactly 1 between two consecutive steps whenever a temporal window must not span them: a **boundary** (start or end tick) of a cut range or a time-breaking span lies in `(previous tick, tick]`, or the gap `dt > 0.5 s`. The rule tests the boundaries, not the endpoints' membership, so a span that falls entirely between two processed frames still breaks the segment. Steps **inside** a cut range or a time-breaking span are still written (they keep the timeline whole) but carry `y = EXCLUDED`, `w = 0`, and their own `seg` |
| `f` | the raw measurements in `featureSchema` order; `null` only for features declared `nullable`; every number finite |
| `y` | the label state (§5), an integer code |
| `w` | the loss weight: `1.0` for `NON_RALLY`, `ACTIVE_RALLY`, `NON_RALLY_ACTIVITY`; `0.0` for `TRANSITION`, `UNKNOWN`, `EXCLUDED` (the manifest's `labelSchema.weights` states this table and the validator enforces it) |

No derived feature is stored (§4.2): the trainer computes windows from the sequence, within one `seg`, and the Swift extractor computes the same function.

## 3a. `baseline/<recordingId>.json` — the deterministic decider's output

`rcf_v1` keeps aggregate measurements per step, not the per-detection bounding boxes `ServeWatch` consumes nor a serve's toss and end times that `RallyDecider.noteServe` uses to prime and backdate a rally start, so **the FSM cannot be re-run from the steps** (Codex round 2 on PR #136). The benchmark R0 is therefore computed **by the exporter at export time**, with `EvidenceReplayer.decidedRallies` on the full `FrameEvidence` it holds (the same replayer RallyLab scores with; parity with the pipeline within 0.2 s, EXP-20261031 §7), and stored — once per recording, once per variant — so the trainer compares against the shipped decider's actual output and never re-implements it:

```json
{"recordingId": "<id>",
 "variants": {"r0":       [{"rawSpans": [{"startTick": 2975, "endTick": 7296}], "startTick": 1775, "endTick": 7596, "serveContactTick": 3000},
                           {"rawSpans": [{"startTick": 24000, "endTick": 24900}, {"startTick": 26100, "endTick": 27000}], "startTick": 23700, "endTick": 27300, "serveContactTick": null}, …],
              "r0_prime": [ … ]}}
```

One entry per exported clip: `rawSpans` are the decider's **pre-merge** raw rallies that the clip joined (`SegmentBuilder.closedRawRanges` after `finalizeWithRaw`, in time order, each clamped to the clip), `[startTick, endTick)` the padded clip, `serveContactTick` the contact tick of the serve the rally started on or null. The pre-merge spans are stored, not their union, because `SegmentBuilder.closeSegment` caps the pre-roll at 0.5 s for a raw rally shorter than 2.5 s *before* `finalizeWithRaw` merges: the second clip above gets `startTick = 24000 − 300`, whereas its raw union `[24000, 27000)` (5 s) would get the full 2 s pre-roll — a port fed the union would compute `22800` and be wrongly rejected (Codex round 3 on PR #136). Rules the validator enforces: the variant names equal the manifest's; keys exactly these four; integer ticks; `rawSpans` non-empty, in time order, disjoint, each `start < end` and inside the padded span; padded `start < end`, in time order and disjoint across clips; within `[0, durationSec × 600]`; `serveContactTick` null or inside the padded span; `baselineSha256` matches. The file is the trainer's parity fixture for its port of the padding: fed each clip's `rawSpans` at the variant's settings (pre-roll with the short-rally cap, post-roll, clamp, **sort by padded start** — a short raw rally before a longer one pads to a later start than its successor — then join on padded gaps, then the minimum clip length), the port must reproduce the clip's padded span exactly, on every clip of every recording, before it is used on the learned decoder's intervals. Thresholds are compared **in seconds**, as `finalizeWithRaw` compares `gapSec` and the padded duration against the `Double` settings: 1.3513 s is not 811 ticks (a gap of 811 ticks = 1.35167 s stays apart, 810 joins). The validator's own `pad_and_merge` is that function, and the synthetic example contains the short-segment merge case above. Why outputs rather than lossless replay evidence: the boxes and serve events are exactly `FrameEvidence`, a far larger artefact with its own storage rules (`StoredFrameEvidence` drops candidates); a second dataset version may add it if a reviewer needs to re-run the FSM offline.

## 4. Feature schema `rcf_v1` (raw measurements)

### 4.1 Columns, in order

| # | name | unit / range | nullable | kind | source (`main` 5fcea89) |
|---|---|---|---|---|---|
| 0 | `dt` | s since the previous step (first step: null) | yes | raw | consecutive `FrameEvidence.time` |
| 1 | `has_ball` | 0/1 | no | raw | `FrameEvidence.hasBall` (VP:752) |
| 2 | `n_court_dets` | count | no | raw | `detections` with `isOffCourt == false` |
| 3 | `n_dets` | count | no | raw | `detections.count` |
| 4 | `max_conf` | 0–1, the raw heat peak value | yes (no detection) | raw | max `BallDetection.confidence` |
| 5 | `ball_y_any` | Vision y, 0–1 (1 = top) | yes | raw | the decider's `ballY` input (VP:755) |
| 6 | `is_projectile` | 0/1 | no | raw | `FrameEvidence.isProjectile` |
| 7 | `sel_x` | 0–1 | yes (no selected track) | raw | `trackPoint.x` |
| 8 | `sel_y` | 0–1 | yes | raw | `trackPoint.y` |
| 9 | `sel_size` | normalised side length (√ area), aspect-dependent | yes | raw | selected `TrackCandidate.ballSize` |
| 10 | `r2` | 0–1 | yes (not projectile) | raw | `FrameEvidence.rSquared` |
| 11 | `grav` | 0–1 | yes | raw | `FrameEvidence.gravitySignature` |
| 12 | `n_cands` | count | no | raw | `candidates.count` |
| 13 | `n_cands_proj` | count ≤ `n_cands` | no | raw | candidates with `isProjectile` |
| 14 | `n_cands_rejected` | count ≤ `n_cands` | no | raw | candidates with a `rejectionReason` |
| 15 | `y_above_net` | signed, normalised (`sel_y − net.maxY`) | yes (no net or no track) | raw | `trackPoint.y − detectedNet.box.maxY`; always null when `net == null` |
| 16 | `serve_emitted` | 0/1 | no | raw | 1 on the step at which `ServeWatch.add` returned a serve (VP:764) — the moment the pipeline first knows of it, which is after the flight's end + 0.5 s settle, at the 0.25 s poll; 0 otherwise |
| 17 | `serve_contact_offset` | s, ≥ 0 | yes (null exactly when `serve_emitted` is 0) | raw | `t − serve.contact` at the emitting step: how far back the serve's contact lies. The serve's retrospective coverage of earlier steps is a **derived** feature the trainer computes only from serves emitted no later than `t + lookaheadSec` (§4.2), so the look-ahead bound holds for it like for every other feature |

Every raw column is **causal**: its value at a step is known to the pipeline when that frame is processed (`kind: raw`, `lookaheadSec` 0.0 for all). Coordinates are Vision-normalised (origin bottom-left, 1 = top) in the rotation-applied frame when `upright`; nothing is scaled by resolution. Normalisation for training (mean/std per column over the **training folds' weighted steps**) is a model artefact, stored with the model, never in the dataset.

### 4.2 Derived features (not stored)

Computed by the trainer and by the Swift extractor from the stored steps, within one `seg`, from the same function (`derived_v1`, versioned in the experiment record): trailing 1.0 s and 3.0 s windows of ball fraction, projectile fraction, mean `r2`, mean `grav`, max `sel_y`, mean speed from finite differences of `sel_x/sel_y`, log-size rate over 1.0 s, rejection count; time since last ball / last projectile (capped 3 s); **serve coverage**: a step at `t` is covered by a serve when a step with `serve_emitted = 1` at `t_e ≤ t + lookaheadSec` has `t_e − serve_contact_offset ≤ t ≤ t_e` (the contact lies before the step and the emission no later than the bound), plus time since the last emitted serve's contact (capped 3 s); for the logistic candidate, forward windows bounded by the model's declared `lookaheadSec` (ball fraction, projectile fraction, time until next ball / projectile, capped). The trainer may use no input beyond `lookaheadSec` after `t`, no label, no FSM output.

### 4.3 What is deliberately absent

`movementType` one-hots (airborne ≡ projectile after the gate; carried/rolling never pass it), frame-level `rejectionReason` (always nil), `fromHeatmap` (always true in multi-frame mode), the Kalman `estimatedVelocity` and the gate's internal fit quantities (not in `FrameEvidence`; a later `rcf_v2` once the shared pipeline exposes them), any per-frame camera-motion measure (none exists).

### 4.4 The uniform-grid view (derived, not stored) for step-indexed models

A convolutional or recurrent model's receptive field is counted in steps, but the steps are processed frames at irregular spacing (§7), so a step count is not a time bound: a stretch sampled every 0.1 s would put 62 "future" steps 6.2 s ahead (Codex round 2 on PR #136). Every model whose context is step-indexed therefore consumes a **uniform-grid view** of each segment, built by the trainer and by the Swift runner from the same function (`grid_v1`, versioned with `derived_v1`):

- within one `seg`, cells `k = 0, 1, …` at `t_k = t_first + k / samplingHzNominal` (30 Hz → 1/30 s) up to the segment's last step; a cell holds the **last** step with `t_k ≤ t < t_{k+1}`, never a step of another segment;
- an empty cell (a dropped or undecodable frame) is a *missing row*: every nullable column null, binary columns 0, counts 0, `dt` = the cell period, plus a derived indicator `cell_missing = 1`; its label is `UNKNOWN` with `w = 0`. Because a gap over 0.5 s breaks the segment, at most 15 consecutive cells can be missing;
- a cell with a step takes that step's `y` and `w`; a prediction for a raw step is the prediction of the cell that holds it, so scoring stays per processed frame;
- the pipeline's feed spacing is `1/30 − 0.004` s (research document §1), so about one step in eight shares a cell with its predecessor and is not seen by the step-indexed model (the cell keeps the later one). Timestamp-windowed models (the logistic candidate) see every step; this asymmetry is a stated limitation of the comparison, not hidden by resampling the stored data.

With the grid, a receptive field of 125 cells is ±2.07 s **of time** in every segment, under the declared `lookaheadSec` 2.1 whatever the processed-frame spacing; the stored steps stay raw (§7: nothing is resampled in the dataset).

## 5. Label schema `rally_activity_truth_v1`

| Code | State | Loss weight | Definition (ticks at 600/s; intervals half-open `[start, end)`; a step with tick `k` is "inside" when `start ≤ k < end`) |
|---|---|---|---|
| 1 | `ACTIVE_RALLY` | 1 | inside a truth rally's `[startTick, endTick)`, outside the ignore band |
| 0 | `NON_RALLY` | 1 | not inside any rally, excluded span, cut, time-breaking span, non-rally-activity span or ignore band, **and** the recording's `eligibility.fullVideoNegatives == standard` (which the manifest rule admits only for a confirmed `continuous` recording, §2.1) **and** `coverage.state ∈ {declared_complete, stage1_complete}` |
| 5 | `NON_RALLY_ACTIVITY` | 1 | inside a Stage 1 `nonRallyActivity` span (trained as a negative; reported as its own class) |
| 2 | `TRANSITION` | 0 | within `boundaryIgnoreSec` (default 0.5 s, manifest field) of a rally start or end, or within a Stage 1 event's `[earliest, latest]` widened by one frame; also the ignore band around an excluded span's edges |
| 4 | `EXCLUDED` | 0 | inside a `missedServe` / `other` span, a cut range or a time-breaking span |
| 3 | `UNKNOWN` | 0 | everything else: time outside marks in a recording whose negatives verdict is not `standard` or whose coverage is not complete; unreviewed time |

Precedence when a step satisfies several: `EXCLUDED` > `TRANSITION` > `ACTIVE_RALLY` > `NON_RALLY_ACTIVITY` > `NON_RALLY` > `UNKNOWN` — except that a truth rally overlapping a cut range is an **error** (a rally mark inside non-footage), not a precedence case. The band half-width around a rally's start or end is `boundaryIgnoreSec` in ticks, or the event's recorded uncertainty in ticks when that is larger. Ball visibility is never a label and never inferred from these states (D-010). A `missedServe` is never `ACTIVE_RALLY` (it is excluded with its kind; the product keeps it as an event elsewhere).

## 6. Recording groups and splits

`groupId` is the transitive closure of: same clip card, same `aliasGroup` (shared file or confirmed `sourceId`), same uploader, same confirmed `sessionId` or `venueId` — written by the exporter from the split manifest. The validator refuses a dataset in which one `groupId` carries two `split` values or two `fold` values, in which two recordings share a `sourceId` or `fingerprint` across groups, or in which a group's `fold` is null for some recordings and set for others.

## 7. Variable frame rates, alignment, camera motion, resolution

- **Frame rate.** Steps are the processed frames at their presentation times; `dt` carries the real spacing (VFR footage, the ≈ 30 Hz feed, dropped or undecodable frames). A gap over 0.5 s breaks the segment so no window spans it. Nothing is resampled in the dataset; a step-indexed model reads the grid view of §4.4 so its context is bounded in seconds.
- **Alignment.** Labels are converted to ticks exactly as the scoring contract converts marks (`round(seconds × 600)`), on the same presentation timeline the evidence uses (`CMSampleBufferGetPresentationTimeStamp`, VP:959). A legacy mark made on a scrub proxy of VFR footage may be offset; the ignore band absorbs offsets up to `boundaryIgnoreSec` and the recording's `vfr` flag lets the trainer report VFR recordings apart.
- **Camera motion.** No per-step measure exists; `camera` (card) and the `handheld` trait in `eligibility.reasons` are the only indicators; handheld recordings are `restricted`.
- **Resolution and orientation.** All coordinates are normalised; `aspect` and `upright` let the trainer correct `sel_size` and interpret `y`.

## 8. Protected material

The validator refuses the dataset when any recording's `recordingId`, `sourceId` or `fingerprint` is in `withheld.names / sourceIds / fingerprints`, when the closure is empty, or when the closure's `closureSha256` does not match the lists it carries. The exporter computes the closure through `ReservedVideos` (the one withheld rule) and must refuse before writing a step, exactly as `--package-l2` does. In the plan, a recording whose card fingerprint, confirmed `sourceId` or original's content fingerprint is one of the closure's identities is left out with that reason, before any video is processed — a re-encoded original has new bytes but keeps the fingerprint its card was registered with, so content alone is not enough (`RallyClassifierExporter.withheldIdentity`, the rule the preflight applies too); the validator is the backstop, run again by the trainer before reading. The exporter writes a `training_package`-class exposure row (`kind: training_package`, ref `--export-rally-classifier-dataset <name>`) for every recording it packages, **after** validation passes, as the L2 exporter does.

## 9. Versioning

`schemaVersion`, `featureSchema.version` and `labelSchema.version` change independently; a trainer states which it accepts. A change to the column order, a unit, a nullable rule or a label definition is a new version with a new validator branch, never an edit of `v1`. The dataset's identity for the registry is `(name, digest, manifest SHA-256, splitManifest hashes, detector digest)`.
