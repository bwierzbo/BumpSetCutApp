---
name: stage1-testflight-direction
status: accepted
created: 2026-10-26T21:22:24Z
updated: 2026-10-26T21:22:24Z
source: owner, delivered to Claude Code on 2026-10-26 (afternoon, MDT) after PR #100's Codex review came back clean
---

> Verbatim record of the owner's direction. It covers: PR #99 approved for merge at its reviewed head (merged 2026-10-26T21:06Z as `8e2dfd9`); PR #100 to be finished, including source identity during sync, protected-holdout read security on the server, and server-side recording identity; a read-only inventory of server footage; frame identity of the iPhone copies checked before TestFlight; PR #101 to be finalised; PR #102 finished without freezing the pilot; migration 048 prepared for the owner's approval and not applied; and an owner-only internal TestFlight build once PRs #99–#101 are merged and 048 is approved, applied and verified. Each of #100, #101 and #102, the live migration and the pilot freeze needs separate explicit approval. L2 training is untouched. Reproduced as received; the heading is the owner's.

BumpSetCut — Complete Mac + iPhone Rally Boundaries and Prepare TestFlight

Our immediate priority is to get RallyLab Rally Boundaries working on my iPhone through TestFlight, while preserving full compatibility with the Mac.

I am remote and want to begin testing the annotation interface on my phone as soon as safely possible.

L2 training must continue independently and without interruption.

1. PR #99 — Approved to merge

I approve merging PR #99 (shared annotation logic) at reviewed commit dd42c9f, provided the head remains unchanged, required checks pass, and Codex remains clean.

This also approves the controlled documentation changes and owner-direction record included in PR #99.

After merging, rebase PR #100 onto main and update its dependent branches as appropriate.

2. PR #100 — Resolve remaining issues

Continue working through Codex findings until PR #100 is completely clean.

Pay particular attention to:

Source identity during synchronization

A server record must never be adopted into an unrelated or replaced video.

Before accepting any pulled record, verify its video identity, original source fingerprint, and relevant project/session identity against the current recording.

Apply these checks before:

* Writing the record locally.
* Replacing an existing annotation.
* Updating the open editor.
* Accepting a server record when no local sidecar exists.

An identity mismatch must refuse synchronization, preserve both records, and display an actionable error.

Add regression tests.

Protected-holdout read security

Migration 048 currently protects writes through rally_events_save, but the SELECT policy for label_rally_events appears to permit authorized labelers to read protected records.

Audit this and fix it.

Both read and write access must enforce protected-recording restrictions on the server, including aliases and recordings that become withheld after initially being published.

Do not rely exclusively on client filtering.

Check that an authorized labeler cannot retrieve protected rally-event content through direct table reads or an alternate API path.

Server-side recording identity

Assess and implement appropriate checks linking the submitted annotation’s sourceFingerprint to the canonical original fingerprint in label_videos.

Missing, stale, or inconsistent identity must fail closed rather than silently accept an annotation for potentially different footage.

Make sure older records are handled without destructive migration.

Preserve concurrency protections

Retain all the fixes already made:

* No overwriting unreadable records.
* No lost in-flight edits.
* No stale editor drafts committed silently.
* No revision regression on undo.
* Serialized phone saves.
* Correct project binding across asynchronous operations.
* Explicit conflict resolution.
* Reviewer and second-review provenance preserved.

Run regression tests on each of these cases.

3. Audit existing server footage

Before deploying the migration, perform a read-only inventory of the existing private labeling bucket and its associated video records.

Determine whether any currently protected recordings, aliases, or copies were previously uploaded under the older unrestricted publishing logic.

Report any findings, including which data or access path is affected.

Do not download protected content unnecessarily, delete files, change permissions, or perform cleanup without my approval.

If exposure cannot be ruled out, report the uncertainty explicitly.

4. Verify iPhone video frame identity before TestFlight

The iPhone uses re-encoded H.264 copies.

I want to know whether our existing copies actually support frame-accurate annotation.

Use representative approved development recordings to compare:

1. Original Mac video frame count and presentation timestamps.
2. Re-encoded copy frame count and presentation timestamps.
3. Frame-times digests.
4. Actual decoded visual correspondence at matching timestamps.
5. Source orientation, trimming, and variable frame-rate behavior where applicable.

Include representative H.264 and HEVC recordings, including a previously problematic HEVC source if it is eligible and can be tested safely.

Use existing accessible files and approved paths. Do not perform new bulk uploads.

Matching timestamps alone does not prove matching video content.

If the re-encoded copies pass, document the evidence.

If they fail, propose the smallest safe correction to the video-delivery pipeline as a separate PR.

Never relax the frame-identity commit gate merely to make annotation work.

5. PR #101 — Finalize the iPhone interface

Once PR #100 is corrected and approved, rebase PR #101 onto the merged implementation.

Retain:

* Original-frame-accurate event placement.
* Shared Mac/iPhone annotation rules.
* Serve-contact and dead-ball marking.
* Reviewed/unreviewed coverage.
* Missed-serve and non-rally activity spans.
* Persistent rally IDs.
* Uncertainty and second-review support where approved.
* Conflict detection and explicit resolution.
* Offline annotation and safe synchronization.
* Playback-only behavior whenever the commit gate fails.

Check the complete user experience on an iPhone-sized display.

Prioritize usability for touch interaction, quick frame stepping, and resuming unfinished recordings.

Run cross-platform tests and request final Codex review.

6. PR #102 — Finish pilot tooling, but do not freeze yet

Resolve all remaining Codex findings and prepare the pilot for approval.

One issue needs special attention:

Formal blind review on iPhone must be enforced, not just enabled by default.

When a selected pilot rally is undergoing its first blind review, legacy boundaries and model predictions must remain hidden until the required annotations are committed.

The Mac and iPhone must enforce equivalent blind-review rules.

Also determine how the frozen pilot selection and review windows will reach the phone reliably. I do not want the formal Mac/iPhone comparison to depend on manually copying timestamps from a Markdown document if an auditable, read-only distribution mechanism can be implemented safely.

Preserve:

* The 24-rally stratified selection.
* Recording-group separation.
* Original hashes and model configuration.
* Independent second-review evidence.
* The 24-hour repeat-review rule.
* Consistent reviewer identity across devices.
* Mac/iPhone agreement reporting.
* boundary_audit.csv.

The real --pilot-freeze remains unauthorized.

Do not run the production pipeline over the pilot pool or record its exposure until I explicitly approve the freeze.

7. Migration 048 — Prepare for owner deployment

Do not apply migration 048 to the live Supabase project yet.

Provide:

* The exact migration SQL and any corrections.
* A summary of new tables, functions, privileges, RLS policies, and triggers.
* Tests of direct-read and RPC authorization.
* Tests for stale revision conflicts.
* A safe deployment and verification checklist.
* A rollback or recovery plan that preserves annotations.
* Instructions for granting the necessary lead role without broadening unrelated privileges.

Return the migration for my explicit approval.

8. TestFlight — Make this the next delivery milestone

After PRs #99–#101 have been individually reviewed, approved, and merged, and migration 048 has been explicitly approved, applied, and verified:

1. Run Mac and iOS build/test checks.
2. Verify a real end-to-end Mac ↔ iPhone annotation sync.
3. Verify offline save and subsequent synchronization.
4. Verify a genuine concurrent-edit conflict.
5. Verify protected-recording refusal on both platforms and through direct server access.
6. Verify the frame-identity gate on actual downloaded video files.
7. Confirm original annotation and L2 dataset isolation.

If all gates pass, use the previously authorized owner-only internal TestFlight release workflow through scripts/rallylab_ios_release.sh.

Do not invite external testers or submit a public release.

Report the uploaded build number and how I can access it.

9. PR approvals and order

PR #99: merge authorized above.

PRs #100, #101, and #102: continue development, testing, rebasing, and Codex review, but return each for my explicit merge approval.

The live migration and actual pilot freeze each require separate explicit approval.

Do not confuse a successful CI run or clean Codex review with owner authorization.

10. L2 training

Leave the L2 process, watcher, dataset, model recipe, checkpoints, and experiment protocol unchanged.

No second seed, protected-holdout evaluation, model promotion, or deployment.

Artifact fetching continues to use --no-score.

Final handoff

Give me:

1. PR #99 merge confirmation.
2. Current review status of PRs #100–#102.
3. All remaining blockers to the iPhone build.
4. Results of the existing video-copy frame-identity checks.
5. Results of the protected-footage inventory.
6. Migration 048 deployment readiness.
7. The shortest safe path to my internal TestFlight build.
8. The exact owner approvals required next.

Our immediate milestone is a working, safe Rally Boundaries editor on my iPhone that synchronizes correctly with RallyLab on Mac.

Prioritize achieving that milestone over polishing the pilot infrastructure. Do not wait for L2 training to finish.
