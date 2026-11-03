---
name: rallylab2-edited-footage-direction
status: accepted (owner direction); folded into D-031, proposed
created: 2026-11-03T03:45:00Z
updated: 2026-11-03T03:45:00Z
source: owner, delivered to Claude Code on 2026-11-02 (evening, MDT), while the Phase 1 PR was being prepared
---

> Verbatim record of the owner's direction, reproduced as received. In summary:
> - Edited and moving-camera footage is preserved and characterised, not discarded; camera motion and video editing are distinct; traits coexist and are recorded at the time-span level.
> - Eligibility is per model and per usable interval — standard, restricted, quarantined — from a conservative starting table that must stay changeable for controlled experiments.
> - Annotation completion and training eligibility are separate: a fully marked edited recording may give positive rally examples and still never ordinary full-video negatives; no temporal window crosses a cut, replay or speed change.
> - Edited derivatives stay in their original's lineage for deduplication and split isolation; unknown overlap is quarantined; protected footage is never inspected to find out.
> - The Phase 1 PR takes only the metadata extensibility; automatic detection, bulk processing and the properties UI are later reviewed PRs; no live-corpus scan under this follow-up.
>
> Applied in Phase 1 as `FootageProperties` (the per-recording span record with derivation), `TrainingEligibility` (the policy) and the source index's verdicts; see [RALLYLAB2_PHASE0_AUDIT_2026-11-02.md §11](../ml-roadmap/RALLYLAB2_PHASE0_AUDIT_2026-11-02.md) and [D-031](DECISION_LOG.md#d-031).

# RallyLab 2.0 — Additional Requirement: Edited Footage, Camera Motion, and Training Eligibility

**Owner direction:** November 2, 2026  
**Related assignment:** RallyLab 2.0 architectural overhaul and unified training-data ingestion pipeline  
**Priority:** Incorporate into the existing architecture and implementation plan.

## 1. Context

During review of our existing training videos, we identified several recordings that contain:

- Dead time removed through editing.
- Slow-motion segments.
- Instant replays.
- Digital zooms or crops.
- Camera panning during gameplay.
- Aggressive camera movement.
- Cuts between camera angles.
- Potential highlight montages rather than continuous matches.

These characteristics affect the suitability of footage for different machine-learning tasks.

**We should not automatically discard edited or moving-camera footage. Instead, RallyLab must preserve it, characterize it, and determine which portions are appropriate for each model.**

This is an additional requirement for the unified ingestion pipeline.

Do not modify existing labels, split assignments, or historical experiments to implement it.

---

## 2. Distinguish Camera Motion From Video Editing

Camera movement is not inherently a reason to exclude footage.

Natural panning, handheld recording, and camera movement during live gameplay are realistic conditions that BumpSetCut should eventually handle.

However, cuts, replays, speed changes, and montage edits alter the temporal structure of the footage.

These must be treated differently.

Introduce appropriate metadata for:

- Fixed camera.
- Normal panning.
- Aggressive panning.
- Handheld or unstable camera.
- Digital zoom/crop.
- Camera-angle change.
- Normal-speed footage.
- Slow motion.
- Replay.
- Montage/edit.
- Unknown or uncertain classification.

These characteristics may coexist. Do not force every recording into one mutually exclusive category.

Prefer recording relevant properties at the **time-span level**, not only at the full-video level.

For example, a recording may contain four minutes of continuous gameplay and a 20-second slow-motion replay.

The whole recording should not necessarily be excluded because of that replay.

---

## 3. Model-Specific Eligibility

Design a clear eligibility policy.

| Footage condition | Rally classifier | L2 ball detector | Net detector |
|---|---|---|---|
| Continuous, normal-speed gameplay | Eligible | Eligible | Eligible |
| Natural camera panning | Eligible | Eligible | Eligible |
| Aggressive camera movement | Restricted initially | Restricted initially | Conditional |
| Slow motion | Exclude from initial temporal training | Individual frames potentially eligible | Eligible if labels are valid |
| Instant replay | Exclude replay intervals initially | Individual frames potentially eligible | Eligible if labels are valid |
| Dead time removed | No ordinary full-video negative sampling | Continuous sequences eligible | Eligible |
| Digital zoom/crop | Conditional | Eligible when geometry and labeling are valid | Eligible with crop-specific geometry |
| Camera cuts | No temporal windows crossing cuts | No temporal windows crossing cuts | Individual frames may be eligible |
| Heavy overlays or effects | Restricted | Restricted | Conditional |

These are starting rules, subject to validation. Do not hardcode them in a way that prevents future controlled experiments.

The eligibility system should distinguish:

1. **Standard:** Appropriate for the relevant training task.
2. **Restricted:** Potentially useful under defined conditions.
3. **Quarantined:** Excluded pending source, quality, permission, or data-integrity review.

Eligibility must be assessed **per model and per usable interval**.

A source may be eligible for net training but ineligible for temporal rally classification.

---

## 4. Critical: Rally Classifier Ground Truth

Our intended rally-classifier workflow is to mark every rally in a five-minute video and use the unmarked time as declared non-rally training data.

That assumption is appropriate only when the recording's coverage and temporal structure support it.

For edited footage:

- Do not infer normal between-rally behavior from missing dead time.
- Do not use playback cuts as genuine rally transitions.
- Do not construct temporal feature windows across replay boundaries, camera cuts, or speed changes.
- Do not classify slow-motion replay footage as ordinary live-play timing.
- Do not interpret "Marked Every Rally" as proof that the recording represents five uninterrupted minutes of a real match.

The completion flag can still indicate that every visible rally was marked.

However, **annotation completion and training eligibility are separate properties**.

A fully marked edited recording may be useful for positive rally examples while remaining ineligible for ordinary full-video negative sampling.

Preserve missed serves as distinct annotations.

Product requirements remain:

- **Game Review:** Missed serves must be included as scoring events.
- **Highlights:** Missed-serve inclusion is user-configurable, defaulting to excluded.

---

## 5. L2 Ball Detector Considerations

Edited footage is not automatically unsuitable for ball detection.

Individual labeled frames from slow-motion footage, replays, or zoomed shots may help the detector recognize:

- Small or large volleyballs.
- Occluded volleyballs.
- Difficult lighting.
- Unusual camera perspectives.
- Cluttered backgrounds.

However, our L2 model uses temporal frame sequences.

**Never create L2 training windows that cross discontinuities or artificial speed changes without a specifically approved experiment designed for those conditions.**

For an initial conservative policy:

- Use continuous, normal-speed sequences for standard L2 temporal training.
- Permit isolated frames from edited material only in datasets or experiments that explicitly support single-frame supervision.
- Keep slow-motion temporal sequences out of the standard L2 training package.
- Preserve crop and scaling metadata whenever available.
- Keep every derivative associated with its original source and match.

Do not silently insert single frames into an L2 training package that requires contiguous temporal windows.

---

## 6. Net Detector Considerations

Net detection is primarily a spatial geometry problem.

Slow motion and replay footage can therefore provide useful net annotations when the geometry is valid.

However:

- Digital cropping changes normalized coordinates.
- Camera panning can move the net within the frame.
- A fixed camera angle creates highly correlated frames.
- Replays from the same source are not independent evaluation examples.

Continue using the proposed default of one representative frame per fixed camera setup, with up to two additional frames for meaningful occlusion or appearance variation.

If the camera physically changes perspective or the crop changes substantially, an additional net annotation may be justified.

Every exported net label must correspond to the exact image geometry being used.

---

## 7. Automatic Edited-Footage Detection

Investigate methods for proposing edit and camera-motion classifications during ingestion.

Possible approaches include:

- Scene-cut detection.
- Frame-to-frame global motion estimation.
- Abrupt scaling changes.
- Timestamp irregularities.
- Repeated visual sequences.
- Replay graphics or transition cues.
- Metadata about frame rate or playback speed.

Do not assume these techniques can reliably identify every slow-motion segment or replay.

The system should support:

- Automatic proposals.
- Confidence or uncertainty.
- Human confirmation.
- Manual corrections.
- Explicit unknown states.

Avoid adding heavy processing to the interactive UI.

Detection should run through bounded, cancelable background jobs and remain safe after crashes or restarts.

Do not install new dependencies or start expensive bulk processing without appropriate approval.

---

## 8. Data Lineage and Deduplication

All edited derivatives must remain connected to their original source when that relationship is known.

Examples:

- Original match recording.
- Highlight compilation from that match.
- Zoomed crop of one rally.
- Slow-motion replay.
- Another camera angle of the same point.

Different file hashes are not sufficient to establish independence.

A clip from a protected holdout match must not enter training because it was edited, cropped, or re-encoded.

Enforce source-group split isolation across the entire derivative chain.

Unknown or suspected overlap must be quarantined rather than treated as independent.

Do not access protected holdout footage to investigate similarity; use permitted provenance metadata.

---

## 9. RallyLab Interface Requirements

Add an intuitive way to view and correct footage properties.

For a source recording, the user should eventually be able to see:

- Recording type: continuous, edited, or unknown.
- Camera behavior.
- Detected cuts and replay intervals.
- Slow-motion intervals.
- Zoom/crop changes.
- Annotation completion.
- Model-specific eligibility.
- Reasons for restrictions or quarantine.

Do not require the labeler to manually classify every frame.

A labeler should only need to review uncertain or consequential proposals.

The interface should make it clear when a completed recording is excluded from rally-classifier negative sampling.

---

## 10. Immediate Instructions

Integrate this requirement into the ongoing RallyLab 2.0 work.

Specifically:

1. Update the architectural design to support time-span-level footage characteristics.
2. Ensure the source/task registry can represent per-model eligibility and associated reasons.
3. Include edited-media lineage in deduplication and split enforcement.
4. Add conservative default policies to the proposed data-admission and export design.
5. Identify where existing RallyLab code can be reused.
6. Add tests to the appropriate implementation phase.
7. Document any unresolved technical decisions.

**Do not restart the overhaul or discard work already completed.**

Do not modify existing video annotations, historical datasets, model weights, or frozen records.

Do not run automatic editing detection over the live corpus as part of this follow-up.

If the first implementation PR is already underway, incorporate the minimum necessary metadata extensibility without expanding that PR into a complete media-analysis implementation.

Defer automated cut detection, motion classification, and large-scale media processing to subsequent reviewed PRs.

Report whether this changes the proposed architecture or implementation order.

## Success Criterion

RallyLab 2.0 must be able to preserve and use difficult edited footage without contaminating the training or evaluation of models that depend on continuous, real-time volleyball behavior.

**The goal is selective, defensible data use—not simply maximizing dataset size or excluding everything difficult.**
