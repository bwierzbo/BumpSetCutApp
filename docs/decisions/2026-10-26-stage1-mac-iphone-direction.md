---
name: stage1-mac-iphone-direction
status: accepted
created: 2026-10-26T18:34:12Z
updated: 2026-10-26T18:34:12Z
source: owner, delivered to Claude Code on 2026-10-26 (midday, MDT) after PR #98 (S1-b) passed its Codex review
---

> Verbatim record of the owner's direction: PR #98 approved for merge at its reviewed head (merged 2026-10-26T18:26Z as `50b4a5f`); the same Stage 1 rally-boundary review on the existing Labeler iPhone app with Supabase synchronisation, one shared schema and one set of boundary rules, iPhone commits refused until the phone's copy is proven frame-identical to the original, an owner-only internal TestFlight build after the code PRs are merged, the 24-rally pilot prepared in parallel, four separate PRs each needing the owner's merge approval, the L2 training run untouched. Reproduced as received; the heading is the owner's.

BumpSetCut — Parallel Mac + iPhone Rally Boundaries Development

I want RallyLab Stage 1 rally-boundary annotation working on both Mac and iPhone as soon as practical, while L2 training continues independently.

I am currently remote and want to test and eventually annotate footage from my iPhone through TestFlight.

Priority: deliver a usable iPhone version without compromising our existing annotation and holdout safeguards.

1. PR #98

I approve merging PR #98 at reviewed commit 2e0e468, provided the head is unchanged, the checks remain passing, and Codex still reports no unresolved findings.

This authorizes the S1-b Mac implementation and its merge only. The Mac GUI still requires hands-on testing.

2. Begin parallel iPhone development

Extend the existing RallyLab Labeler iPhone application. Do not create another app.

Use docs/ml-roadmap/STAGE1_RALLY_BOUNDARIES_PLAN.md and D-024 as the specifications.

Implement the same Stage 1 experience on both platforms:

* Choose an eligible recording.
* Play and scrub video.
* Step backward and forward by individual source frames.
* Mark serve contact and first dead-ball frame.
* Adjust uncertain boundaries.
* Identify missed serves.
* Mark non-rally ball activity, transition, and uncertain spans.
* Record reviewed and unreviewed coverage.
* Edit existing rallies without changing their persistent IDs.
* Resume an incomplete recording.
* Explicitly confirm a fully reviewed recording.

Design touch-friendly controls for iPhone while retaining the Mac’s keyboard-first interface.

3. Shared code and exact-frame requirements

Extract or adapt the reusable Stage 1 annotation data model, validation rules, and editor logic into shared code compiled for both targets.

Maintain one canonical annotation schema and compatible semantics.

Do not create two independent implementations of the boundary rules.

Before enabling iPhone annotation commits, verify that the video delivered to the phone has a trustworthy mapping to the original recording’s presentation timestamps and frames.

Review the current Labeler video delivery path and determine whether it uses the original video or a transformed copy.

If exact frame identity cannot be verified, allow playback but refuse boundary commits until the limitation is resolved.

Do not silently round timestamps, substitute video frames, or use an unverified proxy as ground truth.

4. Mac ↔ iPhone synchronization

Extend the existing Supabase Labeler synchronization infrastructure to support the new versioned rally-event annotations.

Requirements:

* Same recording and persistent rally IDs across platforms.
* Versioned annotation records and reviewer attribution.
* Offline annotation with queued synchronization.
* No silent overwriting of independent edits.
* Optimistic concurrency or equivalent revision checks.
* Detect and present conflicts rather than using last-write-wins.
* Preserve second-review evidence and coverage provenance.
* Enforce protected-holdout restrictions on both client and server.
* Preserve the original legacy rallylabels.json.
* Do not modify L2 training data or dataset splits.

Assess the required database migration, authorization policies, and synchronization design before implementing them. Keep changes small and independently reviewable.

No new bulk footage uploads or permission changes are authorized. Begin with already approved, accessible development recordings.

5. Get the iPhone build to me

Prioritize a working internal TestFlight build.

Use the existing Labeler target and scripts/rallylab_ios_release.sh rather than introducing a new release system.

Before uploading:

* Build and test both iOS and macOS targets.
* Verify annotation round trips and schema compatibility.
* Test protected-recording refusal.
* Test offline edits and concurrent-review conflicts.
* Test frame accuracy against known source recordings.
* Obtain clean Codex review for the implementation.
* Ensure no unapproved production data or protected footage is exposed.

Once these checks pass, prepare an internal TestFlight build for my account. An owner-only TestFlight upload is authorized after the necessary code PRs are separately approved and merged; no public or external-tester release is authorized.

Tell me when the build is available to install.

6. Prepare the 24-rally pilot in parallel

While the iPhone work proceeds, prepare S1-c:

* Frozen selection of 24 eligible development rallies.
* Blind first review.
* Independent second review.
* The established reviewer-consistency protocol.
* Reporting with boundary_audit.csv.
* Comparison of Mac and iPhone annotations on identical source frames.

Do not alter the protected holdout or begin formal pilot annotation before the selection, tooling, and protocol gates are satisfied.

7. PR structure and execution

Use separate PRs for:

1. Shared annotation logic and cross-platform compatibility.
2. Secure synchronization and storage.
3. iPhone UI and frame-accurate playback.
4. Pilot infrastructure.

Some independent preparation may proceed in parallel, but preserve dependencies and do not bypass review.

Every PR needs tests, ci_check, Codex review, and my merge approval. The authorization above applies only to merging PR #98.

8. L2 training

Keep the Windows training process running independently.

Do not modify its package, configuration, checkpoints, seed, evaluation protocol, or watcher.

No protected-holdout evaluation or model promotion is authorized.

Handoff

Give me:

1. Confirmation that PR #98 merged.
2. Cross-platform implementation plan and PR dependencies.
3. Any blocker to original-frame playback on iPhone.
4. The fastest safe route to an internal TestFlight build.
5. The first PR prepared for review.

The objective is one interoperable Rally Boundaries annotation system, accessible from both Mac and iPhone, while the L2 detector continues training.
