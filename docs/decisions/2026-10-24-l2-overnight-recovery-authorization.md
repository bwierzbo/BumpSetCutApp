---
name: l2-overnight-recovery-authorization
status: accepted
created: 2026-10-25T07:07:19Z
updated: 2026-10-25T07:07:19Z
source: owner, delivered to Claude Code on 2026-10-24 (evening, MDT) after the Codex review of PR #93 revision 3
---

> Verbatim record of the owner's overnight authorisation: merge PR #93 once rebased and clean (done 2026-10-25T06:01Z as `be05c4c`, accepting D-025 and the D-022 amendment), restore the two SMB shares under the approved configuration, resume the L2 Stage D export in place, verify the finished package, prepare the completed preregistration for review, and prepare a read-only Stage 1 plan under D-024. Training, protected-holdout evaluation, promotion, network changes, quarantine deletion and annotation/split changes stay unauthorised. Reproduced as received; the heading is the owner's.

# BumpSetCut — Overnight L2 Export Recovery Authorization

I want to make as much progress as safely possible tonight without requiring me to supervise every step.

**Priority: get the corrected L2 export running overnight.**

PR #90 has merged into main. PR #93 contains the HEVC undecodable-frame fix, with the export decision renumbered to D-025.

## Phase 1 — Finalize PR #93

1. Fetch the latest main and rebase PR #93 (`fix/l2-undecodable-leading-pictures`) onto it.
2. Resolve the decision-log conflict correctly:
   - D-024 = progressive RallyLab review workflow.
   - D-025 = HEVC undecodable-leading-picture exception.
   - D-022 is amended by D-025.
   - Preserve all existing decisions and historical records.
3. Run the required builds, RallyLabTests, configuration-management checks, and documentation checks.
4. Push the updated branch and obtain a fresh Codex review against the final commit.
5. Resolve any substantive findings and rerun affected tests. Do not bypass failures.

**MERGE AUTHORIZATION:** If the rebase is correct, all required checks pass, Codex reports no unresolved findings on the final commit, and the PR contains no additional material changes outside the reviewed scope, I explicitly authorize you to merge PR #93.

This approval includes D-025, the D-022 amendment, and the controlled documentation changes identified in PR #93.

If any of those conditions fail, do not merge.

## Phase 2 — Restore export connectivity

After merging, verify access to both existing Windows SMB shares used by RallyLab.

You may reconnect using the previously approved configuration, existing credentials, mounts, and network paths.

Do not change firewall rules, network security settings, SMB permissions, router settings, or install anything without separate authorization.

Verify:
- Source footage can be read.
- The staging share is writable.
- Existing package and journal are intact.
- Both volumes remain reachable and stable.
- No existing data has unexpectedly changed.

If the shares cannot be restored using the existing approved configuration, stop the export recovery and report exactly what needs my attention.

## Phase 3 — Resume L2 Stage D overnight

**EXPORT RESUME AUTHORIZATION:** Once the merged binary is built and connectivity is verified, I explicitly authorize resuming the existing L2 Stage D export in place.

Requirements:

1. Preserve all existing source footage, annotations, dataset records, journal history, and quarantine.
2. Resume the existing package and journal. Do not restart the export from scratch.
3. Keep the current strict identity, provenance, and validation protections.
4. Revalidate previously written frames as required by the exporter.
5. Use the approved D-025 HEVC exception only for independently confirmed, narrowly defined undecodable frames.
6. Journal every accepted undecodable frame and exclude every nine-frame window requiring it.
7. Do not generate replacement frames, duplicate adjacent frames, interpolate labels, or treat undecodable frames as no-ball labels.
8. Stop for unexpected decoding errors, changes to source identity, protected-data violations, or other unapproved failures.
9. No separate full read-only dry-run is needed if it merely duplicates the mandatory export validation.
10. Keep the Mac awake and the export process alive during the unattended run using existing permitted methods.

Authoritative starting plan:
- 89 clips
- 81,273 planned frames
- 34,515 existing journaled frames
- 46,758 frames remaining before accepted undecodable exclusions

Expected HEVC exclusions are concentrated in three train recordings. If exclusions affect unexpected recordings, validation clips, or exceed the supported exception, stop and report the discrepancy.

## Phase 4 — Finish verification if export completes

If the export finishes while I am asleep:

- Run the complete current L2 preflight, including the undecodable-frame integrity check.
- Generate the final package record, checksums, manifest, and ZIP.
- Perform independent Windows package verification.
- Record exact included/excluded frame and window counts by recording and split.
- Record how many human-verified labels no longer contribute to any training window.
- Confirm machine-generated training labels remain zero.
- Confirm protected holdout recordings remain physically excluded.
- Prepare the completed preregistration and experiment report for my review.

If verification fails, preserve the package and report the failure without modifying the integrity rules.

## Phase 5 — Next work, if time remains

Once the export and verification work are complete, you may prepare a read-only implementation plan for RallyLab Stage 1 boundary review under D-024.

Do not start modifying the live dataset or collecting annotations automatically.

Stage 1 remains the MVP priority: exact serve-contact and dead-ball labels for every rally in every eligible development video.

## Authorization limits

The following are NOT authorized:
- L2 model training
- Protected-holdout evaluation
- Model promotion or iOS deployment
- Network or security configuration changes
- Deleting the quarantine
- Changing existing annotations or dataset splits
- Merging unrelated PRs

Do not stop after every successful phase merely to ask for confirmation when the next phase is expressly authorized above.

**Work through the approved stages automatically. Stop only at an actual blocker, failed safety condition, or operation outside these permissions.**

Provide a concise final status report with the PR merge SHA, export progress, package integrity results, and remaining approvals.
