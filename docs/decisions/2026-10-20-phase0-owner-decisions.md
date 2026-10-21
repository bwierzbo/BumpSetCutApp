---
name: phase0-owner-decisions
status: accepted
created: 2026-10-20T22:12:44Z
updated: 2026-10-20T22:12:44Z
source: owner, reviewed with ChatGPT, delivered to Claude Code on 2026-10-20
---

> Verbatim record of the owner's decisions on the ten open questions in [BASELINE.md](../ml-roadmap/BASELINE.md). The normalised entries are in [DECISION_LOG.md](DECISION_LOG.md) (D-001 … D-010). This file is the primary source; do not edit it.

# Phase 0 — Owner Decisions and Review Workflow Authorization

I reviewed the ten open decisions in the Phase 0 baseline report with ChatGPT. Below are my decisions and instructions.

**Important: First establish the formal development and review workflow. Do not begin Phase 1 implementation until that workflow is documented and its first pull request has been reviewed.**

## 1. Learned rally classification

Remove the outdated prohibition on ML rally classification from `CLAUDE.md` and any other project instructions.

That prohibition reflects an earlier iteration of BumpSetCut and is no longer valid.

A learned temporal rally classifier is an approved architectural direction. Develop and evaluate it as a production candidate using detector/tracker features.

The current deterministic pipeline remains available as a benchmark and fallback during development. Do not impose an unnecessary approval gate on experimentation.

Production adoption must be supported by independent validation evidence.

Search all project instructions for similar outdated restrictions. Do not remove unrelated safety or engineering requirements.

## 2. Holdout and dataset leakage

Freeze the four existing holdout recordings and label their historical evaluation exposure.

Create a genuinely independent final-test collection where possible.

Ensure no original video, recording session, or known venue leaks across training and final testing.

Previously used validation recordings may remain development-validation data. Preserve historical scores, but do not describe reused data as independently unseen.

## 3. Hybrid Mac/Windows workflow and Tailscale

Adopt a hybrid workflow.

The Windows desktop remains the canonical location for source footage and primary GPU training. The Mac runs RallyLab, native Core ML verification, annotation review, and Apple-platform testing.

Develop an implementation plan for installing and configuring Tailscale on both machines.

Use official Tailscale documentation. Do not assume Tailscale SSH's built-in server works on Windows. Consider standard OpenSSH over Tailscale for automation, and Windows Remote Desktop or another appropriate remote-desktop application for interactive access.

Verify the desktop's Windows edition, OpenSSH availability, network permissions, and unattended-access requirements before selecting the exact configuration.

Ensure no public port forwarding is required. Restrict access to authorized devices and accounts.

Establish a versioned, checksummed workflow for transferring evaluation footage and experiment artifacts. Avoid maintaining two independently editable annotation repositories.

Do not install software or change network/security settings without explicit owner authorization.

## 4. Boundary annotation review

Approved.

Implement frame-stepping annotation review for 20–30 representative rallies.

Support exact serve-contact and dead-ball timestamps, earliest/latest uncertainty intervals, and provenance.

Preserve legacy annotation records.

Report how annotation differences change scoring, especially complete-rally recall and boundary errors.

## 5. Development and review cycle — implement first

Establish the following workflow:

1. Define the implementation task and measurable acceptance criteria.
2. Create a scoped feature branch from the latest approved main.
3. Implement changes and run appropriate tests.
4. Record affected files, test results, assumptions, limitations, and outstanding issues.
5. Open a GitHub pull request with the relevant evidence.
6. The owner provides the PR to ChatGPT for independent review.
7. Incorporate review findings, with further review when necessary.
8. Merge only after explicit owner approval.
9. Update documentation and decision records as part of the reviewed change.

Do not push directly to main.

Do not automatically merge PRs.

Pushing intermediate commits to an authorized feature branch is permitted.

The first PR must be documentation and workflow setup only.

### First pull request deliverables

- A concise working agreement explaining responsibilities and review gates.
- A PR template containing scope, acceptance criteria, validation evidence, risks, and documentation links.
- An authoritative decision log.
- A central documentation index usable in Obsidian.
- Updated `CLAUDE.md` and relevant rules reflecting current decisions.
- A mechanism for linking issues, experiments, datasets, model versions, and test results.
- A documented procedure for handing PRs to ChatGPT for review.

Reuse existing `.planning/` and `.claude/` infrastructure. Avoid duplicate task trackers or competing sources of truth.

The repository documentation should remain ordinary Markdown so it can be viewed in Obsidian without requiring an Obsidian MCP integration.

Do not require ChatGPT to have write access. The initial review cycle can operate entirely through GitHub pull requests and review findings.

## 6. Repeat validation and permit retraining

We want to repeat the evaluation under the corrected methodology.

Do not simply assume historical results are sufficient.

First:

1. Correct dataset grouping and leakage.
2. Establish trusted rally-boundary ground truth.
3. Correct raw-versus-padded scoring.
4. Resolve replay-versus-production inconsistencies.
5. Establish a new baseline using the current shipping model.
6. Reevaluate viable existing model checkpoints against the corrected validation procedure.

Preserve historical scores and record the exact dataset/split version used for the new evaluation.

After this baseline, conduct selective multi-seed experiments.

Retraining is authorized as a future planned activity when justified by updated annotations, a revised training distribution, or another well-defined hypothesis.

The owner is willing to spend additional training time when it meaningfully improves model performance. Do not exclude retraining merely to save compute.

Do not select architectures based only on detector F1. Include downstream complete-rally preservation, false starts, dead-time removal, and device performance.

## 7. Tuner objective

Approved.

Use constrained optimization prioritizing complete-rally recall while minimizing dead-time retention.

Preserve the existing 0.25 weighted score as a historical diagnostic.

Determine numerical gates using reliable evaluation data rather than inventing acceptance thresholds.

## 8. Rally-score gate

Approved.

Remove the unsupported `enableRallyScoreGate` option from active tuner optimization if production does not implement it.

Reconcile EvidenceReplayer with VideoProcessor.

Add automated parity testing and preserve backward compatibility with historical configurations.

## 9. Dataset grouping and provenance

Approved.

Introduce explicit optional `sourceId`, `sessionId`, and `venueId` relationships.

Do not treat clip-card identifiers as verified venue identities.

Preserve existing source URLs, recording information, annotations, and dataset splits.

Provide a provenance-quality audit and flag uncertain grouping for review.

## 10. Ball visibility, negative training, and non-rally ball activity

This decision requires an additional technical audit before implementation.

### Existing labeling convention

The owner already used these distinctions:

- Visible ball: bounding box or trajectory position was manually annotated.
- Hidden ball: obscured by a player, net, or another obstruction.
- No ball: outside the camera's view, very often due to a high trajectory during an active rally.

Most labeled footage is from within rallies, with limited footage immediately before and after them.

**Do not reinterpret existing `no ball` labels as inactive rallies or automatically convert them into dead-time negatives.**

### Separate two independent concepts

**Ball visibility state:**
- VISIBLE
- OCCLUDED
- OUT_OF_FRAME
- UNKNOWN

**Rally activity state:**
- ACTIVE_RALLY
- NON_RALLY
- TRANSITION
- UNCERTAIN

A ball can be outside the frame during an active rally.

A volleyball can also be clearly visible while no rally is occurring.

These concepts must not share a single target or be inferred from each other.

### Heatmap-model negative supervision

Before changing the trainer:

1. Audit exactly how the nine-frame model constructs targets and loss masks.
2. Determine whether targets apply to the center frame, all frames, or another temporal arrangement.
3. Inspect the existing treatment of hidden and no-ball labels.
4. Determine when an empty heatmap is valid supervision for an out-of-frame ball.
5. Avoid converting uncertain or occluded targets into false-negative supervision.
6. Evaluate whether verified background-only frames improve false-detection rates without impairing recovery when the ball reenters the frame.
7. Compare current training with a controlled negative-supervision experiment.
8. Validate on independent sessions and report results by surface, visibility state, and ball reentry scenarios.

Do not enable new negative-supervision behavior by default until it is supported by experimental evidence.

### Non-rally ball handling

Include a category of challenging non-rally examples where a volleyball is present or moving but no rally is active.

Examples:

- Tossing or passing the ball to the server between points.
- Retrieving a ball after a point.
- Casual throws and warmup activity.
- Players bouncing or holding volleyballs before a serve.
- Other ball movements outside organized rally play.

These should be used to evaluate and train the rally classifier, not automatically treated as negative ball-detection examples.

Preserve the distinction between missed serves, actual rally events, and non-rally handling in the product's event taxonomy.

### Evaluation

Report at least:

- Visible-ball detection accuracy.
- Occluded-ball handling.
- Out-of-frame recovery and false positives.
- Complete-rally recall.
- False rally starts caused by non-rally ball motion.
- Dead-time retention and removal.
- Performance by surface and recording/camera condition.

## Immediate execution order

**Task A — Documentation and review setup**

Create the first documentation-only pull request covering the review workflow, current decisions, updated instructions, and documentation index.

Stop before merging and provide the PR URL for independent ChatGPT review.

**Task B — Dataset and evaluation integrity**

After the workflow is approved, execute the dataset provenance, annotation review, scoring, and holdout corrections in separately reviewable phases.

**Task C — Retraining and architecture experiments**

After establishing a trustworthy baseline, run controlled detector and classifier experiments with reproducible datasets and evaluation reports.

## Required final output for Task A

Provide:

- PR URL and commit SHA.
- List of created and modified files.
- Summary of updated Claude instructions.
- Exact review process for the owner.
- Any unresolved conflicts between existing rules and these decisions.
- Confirm that no detector, training, or production-processing code was changed.

Stop at the review gate. Do not proceed to implementation Task B until the owner approves the workflow.
