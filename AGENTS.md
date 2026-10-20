# BumpSetCut — Codex repository instructions

## Purpose and scope

BumpSetCut is a SwiftUI iOS app for identifying and reviewing volleyball rallies; RallyLab is its macOS labeling, evaluation, and experimentation tool. Both use shared video-processing code. This root file establishes durable repository-wide constraints for Codex coding tasks and pull-request reviews. Do not treat historical roadmaps or notes as proof of current behavior.

For current decisions and review workflow, consult `docs/decisions/DECISION_LOG.md`, `docs/workflow/WORKING_AGREEMENT.md`, and `docs/workflow/CHATGPT_REVIEW.md` when relevant. For build and codebase details, consult `CLAUDE.md`. If a referenced document is absent on the checked-out branch, report the gap rather than inventing its contents. Accepted owner decisions supersede older, contradictory instructions; flag unresolved conflicts.

## Operating boundaries

- Review the actual diff, its surrounding implementation, and supplied test or experiment evidence. Distinguish observed behavior from assumptions; do not claim tests ran or results were verified without evidence.
- When coding, implement only the authorized scope. Preserve existing behavior unless a change is explicitly intended. Do not change production behavior solely to make an experiment pass.
- Use a feature branch and a reviewable pull request. Never push directly to `main` or merge without explicit owner approval. A clean automated review is not merge authorization.
- Do not install tools, modify security/network settings, deploy services, or alter remote data without explicit authorization. Never expose credentials or private footage in logs, PRs, or documentation.
- Keep generated reports, footage, large training artifacts, and local credentials out of Git unless intentionally approved and appropriately managed. Model files referenced by the Xcode project must be present in the intended target's reproducible build inputs.

## High-value review rules

### 1. Shared iOS / RallyLab processing parity

Changes to tracking, physics, rally decisions, segmentation, configuration, or shared model interfaces must behave consistently in the production iOS pipeline and RallyLab replay/tuning. Flag configuration options a tuner can select but production ignores, mismatched defaults, and changes that build only one affected target. Use `scripts/build.sh` for builds; shared pipeline changes require both targets to build. Prefer automated parity tests to prose assertions.

### 2. Rally scoring: raw boundaries are not export padding

Rally start/end accuracy must be evaluated against **raw** segment boundaries. Export/display pre-roll and post-roll must be evaluated separately for preserved action and retained dead time. In a padded processing run, use the same run's `BuiltSegment.raw`; do not simulate raw output by rerunning with zero padding if that changes merge or minimum-duration decisions. Flag any score that compares padded clips to raw ground truth as though the times were equivalent.

### 3. Dataset independence and provenance

Never split related frames or clips across train, development validation, tuning, and final test if they share the same source recording, known session, or confirmed venue grouping. Clip-card IDs, uploader names, and surface labels do not by themselves prove distinct venues. Flag overlaps and uncertainty; preserve existing metadata and use optional, backward-compatible fields for `sourceId`, `sessionId`, and `venueId`. Previously reused holdouts are `legacy_holdout`, not genuinely unseen final tests. Any published comparison needs the dataset/split identities and exposure history.

### 4. Ball visibility is independent of rally activity

Keep ball visibility (`VISIBLE`, `OCCLUDED`, `OUT_OF_FRAME`, `UNKNOWN`) separate from rally activity (`ACTIVE_RALLY`, `NON_RALLY`, `TRANSITION`, `UNCERTAIN`). A ball outside the frame can be part of an active rally; a visible tossed or retrieved ball can occur between rallies. Never convert an existing "no ball" label into a non-rally label or verified negative solely from its name. Unknown/unreviewed frames are not verified negatives. Check temporal target alignment, loss masks, and occlusion semantics before approving heatmap negative-supervision changes. Non-rally ball motion is important classifier data, not automatically a detector negative.

### 5. Annotation integrity and compatibility

Legacy rally marks are not frame-verified ground truth without provenance. Preserve original marks and support review state, annotation method, uncertainty, and versioning as applicable. Do not silently treat track trims, live-tag timestamps, or visible-ball spans as precise serve-contact/dead-ball boundaries. For persisted Swift `Codable` schema changes, preserve existing projects via optional fields / `decodeIfPresent` and regression tests. Treat decode failures that can overwrite annotation files as data-loss risks.

### 6. Model experiments and production promotion

A learned temporal rally classifier is permitted and is an approved production candidate; do **not** enforce the outdated prohibition on ML rally classification. The deterministic FSM remains a benchmark and fallback until a validated production change is approved. Compare models on genuinely independent grouped evaluation, including complete-rally recall, missed/clipped rallies, false starts, dead-time retention, visibility cases, per-surface performance, and on-device resource costs—not detector F1 alone. Preserve experiment reproducibility with model, config, dataset, and split identities. Retraining is allowed when justified by the evidence.

### 7. Model licensing and deployment footprint

Do not inadvertently include Ultralytics-derived YOLO packages in the public iOS release; the project decision is to remove them from the public bundle before launch unless licensing is resolved. RallyLab/internal tooling may have different target membership. Verify target membership and app-bundle consequences for model or `.pbxproj` changes, and check licensing provenance rather than assuming an experiment is redistributable.

### 8. Evidence and tests

Require tests appropriate to the changed behavior and examine what they actually establish. For shared processing changes, verify iOS and RallyLab builds; for scoring, boundaries, replay, annotations, or dataset splits, expect targeted regression fixtures and/or reproducible score reports. Record unrun tests as **not run**, not passed. Prefer stubs or deterministic fixtures for unit tests and separate integration tests for real external services; never demand live credentials for routine unit tests. Do not kill unrelated processes as test cleanup.

## Pull-request review output

For each actionable finding, report:

- **Severity:** `Blocking defect` (correctness, data loss, security, leakage, incompatible production behavior), `Substantive concern` (meaningful risk or missing evidence), or `Suggestion` (nonblocking improvement).
- **Location:** exact changed file and line range where possible.
- **Evidence:** what the diff or test output shows, and why it matters for BumpSetCut.
- **Action:** the smallest specific fix or verification needed.

Prioritize real regressions and consequential invariant violations. Do not turn every preference or speculative possibility into a blocker. If evidence is insufficient, state the uncertainty. When no actionable findings are found, say so without implying the PR is proven correct or authorized to merge.

## Handoff expectations

PRs should state scope, acceptance criteria, actual build/test results, dataset or model hashes when relevant, risks, and related documentation/decision references. Codex reviews independently; Claude Code can address findings; only the owner approves merging. Changes to ML evaluation methodology or production architecture merit separate owner discussion even after automated review.
