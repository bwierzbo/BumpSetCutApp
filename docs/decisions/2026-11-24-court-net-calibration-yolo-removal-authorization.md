---
name: court-net-calibration-yolo-removal-authorization
status: accepted (owner authorisation); D-042
created: 2026-11-25T01:01:46Z
updated: 2026-11-25T01:01:46Z
source: owner, delivered to Claude Code on 2026-11-24 (Mountain Time) as one document
---

> Verbatim record of the owner's authorisation, reproduced as received (headings demoted one level under this
> note's own). In summary: manual-first Court & Net Calibration in the iPhone app, on a shared versioned format;
> YOLO out of the shipping baseline with an explicit net-geometry source in its place; focused reviewed PRs; the
> classifier workstream untouched; merge, TestFlight and release remain the owner's gates.

**Not asked back.** The document was acted on as given. Where it leaves a choice, the choice and its reason are in
the PR that makes it.

---

## BumpSetCut — Owner Authorization: Court & Net Calibration, Manual-First Release, and YOLO Removal

**Date:** 2026-11-24  
**Repository:** `bwierzbo/BumpSetCutApp`  
**Starting point:** Latest main; verify before proceeding  
**Priority:** High  
**Primary deliverable:** A usable Court & Net Calibration feature in the iPhone application  
**Secondary deliverable:** A YOLO-free application processing baseline

### 1. Owner Direction

I want BumpSetCut to support physical court-boundary and net calibration directly in the iPhone application.

The eventual experience is:

**Model proposes → User corrects → User confirms → Geometry is saved and reused.**

However, I do not want the lack of an accurate automatic model to delay releasing this feature.

**Ship a manual-first calibration experience now. Add automatic proposals when they are sufficiently reliable and legally suitable for distribution.**

I also want YOLO removed from the active BumpSetCut processing baseline, including its legacy net detection and ball-detection fallbacks.

These are explicit product priorities.

Do not spend weeks optimizing an automatic court or net model before delivering a working interface.

### 2. Immediate Deliverable: Manual Calibration

Implement a working iPhone Court & Net Calibration screen.

Users must be able to open a video, select a frame, draw the court and net, adjust the geometry, confirm it, and save it.

The feature must work even when no automatic detector is installed or available.

#### Court boundaries

Use the existing six-point ground-plane representation:

1. Near-left corner.
2. Near-right corner.
3. Left sideline/net-ground intersection.
4. Right sideline/net-ground intersection.
5. Far-left corner.
6. Far-right corner.

Connect the points into the physical court boundaries, including the ground-plane net division.

Use perspective-correct geometry. Do not assume the court is rectangular in the image.

Allow corners to be outside the frame or unknown.

#### Physical net

Use four independently adjustable points:

1. Top-left of the net.
2. Top-right of the net.
3. Bottom-right of the net.
4. Bottom-left of the net.

These describe the actual net quadrilateral, not its bounding rectangle.

The physical net and court ground plane must remain separate representations.

#### User controls

Support:

- Tap to place points.
- Drag to adjust points.
- Drag a line or complete geometry.
- Pinch to zoom and pan.
- Frame stepping for precise placement.
- Independent court and net overlay visibility.
- Reset or start over.
- Save draft.
- Confirm.
- Edit a previous confirmation.
- Mark a camera change.
- Mark a view as unsuitable or unknown.

Use large, touch-friendly controls. Add an offset magnifier or equivalent precision aid so the user's finger does not hide the point being positioned.

**A user must be able to complete calibration with no machine proposal whatsoever.**

### 3. Automatic Detection Is Optional

Reuse the existing research in PR #166:

- `court_geometry_v1`
- `net_guided_v1`
- `court_lines_v1`
- `combined_v1`
- CourtCalibration and CourtLayout
- CourtProposer
- Human confirmation and camera segmentation

Also inspect the existing RallyLab Net Labels implementation.

Do not merge the entire research branch. Extract or adapt only the relevant components.

When a suitable proposal is available, offer it to the user.

When it is not available, open the manual editor immediately.

Use this priority order:

1. An existing valid human-confirmed calibration.
2. A valid automatic proposal, shown as unconfirmed.
3. A clearly identified geometric estimate.
4. Manual placement.

No automatic detector is required for the initial release.

Do not train a court model or net model under this assignment.

Do not introduce new proprietary, license-restricted, or unsupported model dependencies merely to generate proposals.

### 4. Remove YOLO From the Application Baseline

This is a deliberate architectural change.

I want active BumpSetCut application processing to stop relying on YOLO, including legacy ball and net models.

#### Audit existing dependencies

Inspect all active runtime call paths, including:

- `YOLODetector.swift`
- `YOLORawDecode.swift`
- `NetDetector.swift`
- `VideoProcessor.swift`
- `BallNetSampler.swift`
- `TrackFinder.swift`
- `Labeler/Tracking/TrackSession.swift`
- Debug and TestFlight model-selection settings
- Model-loading and fallback logic
- Xcode project membership and bundled resources
- RallyLab paths shared with the shipping pipeline

Identify which YOLO dependencies are genuinely active and which exist only for historical research, reproducibility or isolated experiments.

Produce a dependency inventory before making changes.

#### Required production behavior

Remove YOLO from active production and TestFlight processing paths.

This includes:

- No YOLO ball detector in the shipping runtime.
- No YOLO net detector in the shipping runtime.
- No automatic fallback to old YOLO weights.
- No YOLO/hybrid option in user-facing or TestFlight processing settings.
- No Ultralytics-derived model packages bundled into the shipping application.
- No production code silently invoking a legacy detector when another model fails.

The multi-frame heatmap ball detector should remain the supported ball-detection baseline where it is already validated.

Refactor callers so they do not instantiate YOLO unnecessarily.

If the heatmap model is unavailable, report the actual failure or explicitly supported degraded mode. Never silently fall back to YOLO.

#### iPhone labeling

The existing Labeler still has YOLO-backed tracking operations.

Remove YOLO dependencies from its active assisted-tracking implementation as part of reaching a YOLO-free shipping baseline.

Use supported heatmap evidence where the implementation and validation allow.

Where equivalent automated tracking is unavailable, retain manual labeling rather than pretending an unsupported replacement provides identical results.

Do not silently reduce labeling accuracy or change labels already confirmed by a person.

#### Existing RallyLab research

Preserve historical model evaluations, stored results, dataset identities and experiment reproducibility.

Legacy YOLO research code may remain in an explicitly isolated research-only target or archival path if necessary.

It must not be reachable from the default application-processing pipeline or bundled into shipping targets.

Do not erase historical evidence or change sealed experiment artifacts merely to eliminate references to YOLO.

#### Important

Removing YOLO must not be accomplished merely by deleting model files.

Update every affected code path, configuration, model picker, dependency and test.

Make the shipped application YOLO-free and verifiably functional.

### 5. Replace the Existing Net Dependency Safely

The current pipeline uses the legacy net detector for functions including:

- Above-net requirements.
- Under-net rejection.
- Approximate off-court filtering.
- Net-related spatial reasoning.

Removing that detector changes those capabilities unless a replacement is supplied.

Do not silently treat the absence of a detected net as proof that the ball is inside the court or above the net.

Implement an explicit net-geometry source that can represent:

- Human-confirmed geometry.
- Future automatically proposed geometry.
- Unknown or unavailable geometry.

For the first release, manually confirmed net geometry should be usable as a trusted spatial input where coordinate compatibility and behavior have been verified.

When no net geometry exists, the processing system must report that limitation and use an explicitly defined fallback behavior.

Preserve accurate processing metadata showing which spatial checks actually ran.

Do not introduce arbitrary synthetic net positions.

Any change to active rally decision rules requires focused regression testing, documentation and owner review.

If a verified replacement cannot preserve an existing gate's behavior, describe the degradation explicitly rather than claiming parity.

### 6. Shared Calibration Architecture

Use a versioned calibration format compatible with the existing P2 research where practical.

A saved calibration should contain:

- Recording and source fingerprint.
- Geometry schema version.
- Source-frame dimensions and orientation.
- Court points and their seen/estimated/unknown states.
- Physical net points.
- Court dimensions and format.
- Camera segment start/end times.
- Confirmation status.
- Proposal provenance, if any.
- Original proposed geometry, if any.
- Human-adjusted geometry.
- Reviewer identity.
- Confirmation timestamp.
- Previous confirmations or revisions.

A confirmed calibration must never be overwritten by a fresh automatic proposal.

Source replacement, incompatible coordinate changes, or camera-view changes must invalidate or restrict use of the old calibration.

Implement strict validation and atomic writes.

Reuse shared geometry code between the Mac and iPhone where feasible.

Avoid building another competing geometry representation.

### 7. Camera Segments and Reuse

One calibration may cover an entire video recorded from a stationary camera.

For recordings with camera movement, support multiple calibration segments.

The user can choose:

- Camera changed here.
- Calibrate this segment.
- Reuse previous calibration as a starting point.
- Not a stable court view.

A reused calibration is a draft until confirmed for the new viewpoint.

Do not automatically assume that footage recorded at the same venue has identical camera geometry.

For the initial release, simple manual segment splitting is sufficient.

Automatic camera-change detection can come later.

### 8. Integrate Into the iPhone Video Workflow

Court & Net Calibration should be available directly from the existing video-processing experience.

It should not require:

- Opening RallyLab on a Mac.
- Uploading a video to a separate service.
- Completing a model-training experiment.
- Waiting for automatic detection to succeed.

Suggested flow:

**Video details → Court & Net → Mark or correct geometry → Confirm → Return to video.**

Provide a visible status such as:

- Not calibrated.
- Draft.
- Court confirmed.
- Net confirmed.
- Both confirmed.
- Needs review.

Confirmed geometry should be viewable and editable later.

Where possible, display confirmed overlays during video playback.

The feature must be useful even if no processing integration has been enabled yet.

Do not make calibration mandatory before a user can view or manage a video.

### 9. Release Strategy: Ship the Manual Version First

Do not wait until the complete automatic-detection system is finished.

#### Release 1 — Manual Court & Net Calibration

Required:

- Working court editor.
- Working physical-net editor.
- Save and reopen.
- Human confirmation.
- Source and coordinate validation.
- Stable camera segment support.
- Display of confirmed geometry.
- Usable portrait iPhone interface.
- Verified absence of YOLO from the shipping build.

Automatic proposals are not an acceptance requirement.

#### Release 2 — Assisted Calibration

Add available safe proposal methods:

- Net-guided estimates.
- Court-line detection.
- Combined estimates.
- Later, suitable trained models.

User correction and confirmation remain mandatory for authoritative geometry.

#### Release 3 — Processing Improvements

After separate validation and authorization:

- Court-based off-court rejection.
- Better handling of adjacent courts.
- Player court-membership filtering.
- Serving zones.
- Net-crossing and serve evidence.
- Additional classifier features.

Do not use unvalidated geometry to make hard rally decisions in Release 1.

### 10. Testing and Quality Gates

Run all applicable tests for each affected target.

#### Calibration tests

- Manual court placement.
- Manual net placement.
- Touch editing and zoom.
- Perspective transforms.
- Portrait and landscape orientation.
- Outside-frame corners.
- Missing and unknown points.
- Invalid polygons.
- Camera changes.
- Persistence and reopening.
- Human-confirmation authority.
- Stale calibration refusal.
- No proposal available.
- No model installed.

#### YOLO-removal tests

Verify:

- No YOLO inference runs in active shipping code.
- No YOLO models are included in shipping artifacts.
- No hidden YOLO fallback.
- Existing heatmap detection still works.
- Existing rally-processing behavior is regression-tested.
- Net-dependent gates explicitly handle available versus unavailable geometry.
- Labeler manual and assisted workflows remain usable.
- Both iOS and RallyLab build after shared-code changes.

Test actual video processing on representative eligible beach, grass and indoor recordings.

Check performance, thermal behavior, processing time, missed detections, and rally output.

Report any accuracy regression honestly.

Do not substitute a model-free stub that reports fake detections.

Preserve withheld-footage and lineage protections across all new processing and research paths.

### 11. Independent Review

Follow the existing repository process.

Use focused PRs rather than one enormous, difficult-to-review change.

Recommended separation:

1. Shared calibration representation and persistence.
2. Working iPhone manual editor.
3. YOLO removal and supported processing fallback refactor.
4. Optional automatic proposals and UI refinements.

The implementation order may be adjusted to keep changes buildable, but the first user-facing release must be manual-first and YOLO-free.

Each PR requires:

- Applicable builds and tests.
- Independent Codex review.
- Resolution of substantive findings.
- Green CI.
- Configuration-item documentation.
- Explicit owner merge approval.

Do not merge automatically.

### 12. TestFlight Delivery

The goal is to deliver an actual usable iPhone feature, not just completed code.

Prepare the first manual calibration release for internal TestFlight as soon as its required functionality, YOLO removal and regression checks pass.

After owner approval of the necessary PR merges, prepare the internal build and provide a physical-device acceptance checklist.

Obtain my confirmation before distributing that build.

External TestFlight and public App Store distribution remain separate approval gates.

Do not hold Release 1 for automatic model development.

### 13. Protect the Classifier Workstream

This is a separate initiative from the ongoing learned rally-classifier experiment.

Do not change:

- G6/G7 thresholds.
- Frozen human-audit records or draws.
- Existing classifier datasets.
- Classifier folds.
- Preregistration hypotheses.
- R1/R2 training methods.
- Stored R0/R0′ baseline evidence.

Do not export or train a classifier.

Do not modify active classifier evaluation code as a side effect of cleaning up the application's YOLO dependencies.

If a shared component needs alteration, explicitly demonstrate that classifier evidence and experiment reproducibility remain intact.

Do not apply migrations, alter RLS or deploy backend changes without separate authorization.

### 14. Required Progress Reports

After the first implementation phase, report:

1. What functionality now works on the iPhone.
2. What was reused from PR #166.
3. Whether users can mark court and net geometry with no models installed.
4. What calibration data is saved.
5. Which active YOLO dependencies remain.
6. What changes are required to eliminate the rest.
7. Whether current ball processing still works.
8. Which net-dependent processing behaviors change.
9. Tests completed and Codex findings.
10. The remaining steps to internal TestFlight.

At the final release gate, provide evidence that the shipping build contains no YOLO model artifacts or reachable YOLO inference paths.

#### Final Owner Instruction

**Build and ship manual Court & Net Calibration first.**

Do not delay it to develop a better model.

Remove YOLO from the active shipping baseline, preserve working ball detection using the supported multi-frame model, and handle absent net geometry explicitly.

Keep legacy research evidence intact.

Automatic court and net proposals can improve the feature later.

The immediate outcome I want is an iPhone build where a player can open a volleyball video, manually mark the physical court and net, confirm the geometry, and save it for reuse.

Proceed with development and reviewed PRs. Stop at the established merge and release approval gates.
