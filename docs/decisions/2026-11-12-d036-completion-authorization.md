---
name: d036-completion-authorization
status: accepted (owner authorisation); its decision is D-037
created: 2026-11-13T01:04:25Z
updated: 2026-11-13T01:04:25Z
source: owner, delivered to Claude Code on 2026-11-12 (afternoon, MST)
---

> Verbatim record of the owner's authorisation, reproduced as received. In summary:
> - The four corrective PRs (#172, #173, #175, #174, in that order) may be merged after verification; the full RallyLab suite is rerun on #172's final head.
> - The prepared D-036 correction is applied to live Scratch: all three holdout/train pairs and the six train/train pairs, through `--set-provenance`; nothing is deleted.
> - The remaining consumer gaps are fixed in focused follow-up PRs (stale manifests, reserved-card registration, the legacy holdout in every model-run guard, existing artefacts, server and fingerprint-bound records, the unexplained pre-tracking rows); those PRs are not merged without a further decision.
> - One bounded, logged content audit of the protected recordings is authorised, for duplicate identification only, as a separately scoped operation.
> - The affected L2 model is retained and annotated as exposed; its D-017 lineage-isolation claim is void.
> - The ProcessedMetadata leak may be deleted once; the unreadable grass recording may be fetched again; a new classifier dataset is exported under the corrected manifest (`rc-v1-20261108` is preserved, with no exception for its stale record); the classifier experiment is prepared up to, and not past, the training gate.

# BumpSetCut — Owner Authorization: Complete D-036, Correct the Exporter, and Prepare Classifier Training

**Date:** 2026-11-12  
**Repository:** `bwierzbo/BumpSetCutApp`  
**Scope:** Dataset integrity, withheld-footage protection, exporter completion, classifier data readiness  
**Owner direction:** Proceed with Option A and the corrective work described below.

## 1. Primary Objective

Complete the current dataset-integrity workstream and get BumpSetCut ready for its first learned rally-classifier experiment.

We have successfully exported our first real classifier dataset, but the discovery of three training/holdout content aliases requires correcting the project's authoritative source identities, strengthening the remaining protections, and producing a new validated classifier dataset.

The immediate objective is a defensible ball-only classifier experiment, not perfect historical provenance across every artifact in the project.

Keep the player-detection, pose, and court-calibration research in PR #166 independent of this work.

## 2. Current State

The latest reported state is:

- `origin/main` = `712f048` (#171).
- Four corrective PRs are open, unmerged, mergeable, and reportedly CI-green with no unresolved Codex findings.
- Live Scratch remains unchanged.
- The identity correction has been tested on an isolated project copy.
- No new training, deployment, or dataset regeneration has occurred.

Pending PRs:

| PR | Reviewed head | Purpose |
|---|---|---|
| #172 | `6b6c860` | D-036 identity correction, content-aware audit and preflight |
| #173 | `ec9c7eb` | Stop analysis runs from generating ProcessedMetadata |
| #174 | `271698f` | Content-lineage audit prototype, proposals only |
| #175 | `3797860` | Withheld-footage guards on previously unguarded consumers |

Verify the actual current state before proceeding. Do not assume these heads or checks remain unchanged.

## 3. Owner Authorization — Merge the Four Existing PRs

The owner authorizes merging these four PRs in the following order, subject to the verification requirements below.

### Merge order

1. #172 — identity correction and D-036.
2. #173 — ProcessedMetadata fix.
3. #175 — withheld consumer guards.
4. #174 — content-lineage audit prototype.

### Requirements

Before each merge:

- Verify the actual PR head, mergeability, review status, and required GitHub checks.
- Confirm that no unresolved blocking or substantive Codex findings remain.
- Verify that the current code has been tested against the relevant updated base.
- Resolve conflicts without dropping either branch's intended protections.
- Request a fresh independent review when conflict resolution or subsequent changes alter reviewed code.
- Verify green CI on the final merge candidate.

For #172, rerun the full RallyLab test suite on the final head. The previous full suite preceded the last fix; the targeted tests alone are insufficient for final acceptance of this identity change.

### Known conflict

#173 and #175 conflict in `HeadlessTrainingExport`.

Preserve both:

- The withheld admission check and exposure-ledger protections.
- The use of `analyzeVideo` instead of the metadata-writing processing path.

Do not resolve the conflict by choosing one side wholesale.

After all four merges, run the applicable combined build, test, and CI checks.

Preserve the unrelated uncommitted Xcode `project.pbxproj` re-sort. Do not overwrite it or include it accidentally.

Record the final merge commits and test evidence.

## 4. Apply D-036 to Live Scratch

The owner explicitly authorizes applying the prepared non-destructive correction to live Scratch after the relevant corrective PRs have merged and passed verification.

### Confirmed protected aliases

Include all three pairs:

| Protected recording | Training copy |
|---|---|
| `grs_extra_self_06` | `grs_ele_sun_land_self_01` |
| `grs_extra_self_12` | `grs_sid_sun_port_self_01` |
| `bch_extra_self_18` | `bch_tri_sun_land_self_01_v4` |

Keep the original 16 lineage-holdout recordings reserved, along with the five legacy holdouts.

The third pair is supported by cut history and fingerprint evidence. Treat it conservatively as protected even before picture comparison.

Use the established confirmed `sourceId` mechanism through `--set-provenance`.

Do not implement filename-specific exceptions.

### Train/train source relationships

The owner also authorizes correcting the six train/train pairs identified by the audit, where the shared underlying source is supported by the documented cut history.

These recordings must share appropriate source identity and evaluation grouping.

Do not automatically discard all clips from the same source. Distinct time ranges may contain useful, non-overlapping rallies.

Identify overlapping ranges separately so they cannot unintentionally overweight repeated footage.

### Application safety

Before changing live Scratch:

1. Close RallyLab and prevent concurrent project writers.
2. Verify the footage share and relevant project files are accessible.
3. Verify the prepared backup and SHA-256 sums.
4. Confirm live metadata matches the correction script's expected inputs.
5. If the project has changed, reassess the correction against the new state rather than blindly applying the old script.
6. Use the tested correction script.
7. Regenerate the authoritative split manifest.
8. Run the corrected dataset audit.

Expected results, subject to current project verification:

- Withheld closure: 21 → 24 recordings.
- Detector train pool: 133 → 130 recordings.
- Lineage-holdout membership including aliases: 16 → 19.
- No hard dataset-audit findings.
- Historical exposure ledger preserved byte-for-byte during the identity correction.
- All existing annotations preserved.

If any expected invariant fails, stop, preserve evidence, and report the discrepancy.

Do not delete recordings, labels, training artifacts, or historical ledger entries.

## 5. Correct the Remaining Consumer Gaps

The four PRs improve protections but do not establish that every consumer is safe.

Address the remaining known training-relevant gaps in focused follow-up PRs.

### A. Stale manifests

Fix `DeciderRetune` and `train_net_model.py` so they cannot silently accept outdated dataset manifests.

Requirements:

- Verify the manifest against the authoritative current project state.
- Refuse stale or unverifiable identities.
- Require a valid package and corresponding provenance where training depends on a previously exported package.
- Add regression tests.

Audit other relevant consumers for the same assumption.

### B. Reserved recording ingestion

The Projects-tab `enqueueClip` path still runs the pipeline and pre-labeling when creating a session for a reserved card.

Separate session creation from model execution.

A protected recording may receive the metadata necessary for registration, provenance, and authorized manual labeling without running a detector or generating machine labels.

Ordinary ingest must not expose reserved footage to models.

Add tests demonstrating that reserved metadata-only session creation succeeds while unauthorized model execution is refused.

### C. Legacy holdout policy

The owner authorizes extending routine model-run protection to the full withheld closure, including the five legacy-holdout recordings.

This applies to:

- Training and package generation.
- Pretracking and model-generated labels.
- Debug processing.
- Routine model scoring.
- Tuning and comparison.
- Player and pose research.
- Net proposals.
- Other model-running GUI and headless consumers.

Do not prohibit legitimate manual annotation where the relevant workflow allows it.

Any explicitly authorized diagnostic evaluation of legacy or lineage holdouts must use a separately controlled, logged evaluation path.

Do not add a general-purpose bypass that weakens ordinary admission checks.

### D. Existing generated artifacts

Identify previously generated data that contains the newly protected aliases, including:

- `images/train`.
- `data.yaml` and related legacy training manifests.
- Existing L2 packages.
- Previously exported `.trainingdata.json` files.
- Other cached model evidence or generated datasets.

Prevent current trainers from treating these artifacts as newly eligible training data.

Quarantine or mark affected artifacts historical, exposed, or ineligible as appropriate.

Preserve them for provenance unless the owner separately authorizes deletion.

### E. Phone-server and fingerprint-bound records

Audit affected phone/server records, existing published video identities, net labels, footage properties, and AI proposals.

Ensure newly protected aliases cannot enter new ordinary labeling/model-exposure workflows through outdated server state.

Preserve historical annotation and exposure records.

Do not automatically invalidate a valid human label simply because the source identity was corrected. Determine whether the record remains bound to the actual footage.

Report any backend migration, storage-permission change, or destructive reconciliation as a separate owner decision.

### F. Unexplained pretracking exposure

Investigate the six `pre_tracking` rows dated after the lineage cutover.

Determine:

- Which recordings and model runs they refer to.
- Whether they indicate actual protected-footage exposure.
- Whether they were written through an old unguarded path.
- Which model or evaluation claims are affected.

Preserve the original ledger entries.

Do not guess or rewrite history.

### Follow-up review policy

Prepare focused PRs for these fixes.

The owner authorizes implementation, synthetic testing, and independent review, but not automatic merging of additional PRs beyond #172–#175.

Clearly identify which follow-up PRs are blockers for the corrected classifier export and which can remain independent cleanup work.

## 6. Controlled Content-Lineage Audit

The owner authorizes one bounded audit of the currently protected recordings for the sole purpose of duplicate-content identification.

This is an identity-verification operation, not training, model evaluation, tuning, or annotation generation.

### Requirements

- Use deterministic image or temporal fingerprints and the existing cut-history evidence.
- Compare potentially related recordings to identify re-encodes, excerpts, overlapping ranges, and other content aliases.
- Include verification of the third D-036 pair.
- Record exactly which protected recordings were opened, why, when, and with which audit configuration.
- Record access before decoding.
- Preserve source fingerprints, audit inputs, and reproducible comparison evidence.
- Keep results as proposals until a human confirms identity relationships.
- Do not run ball, net, player, pose, or rally-classifier models over protected footage.
- Do not inspect rally labels or use protected footage to improve model behavior.
- Do not remove or weaken existing reservations.
- Do not include genuinely untouched final-test candidates outside the identified audit scope without further approval.

Implement the audit as a separately scoped operation rather than adding a general bypass to the normal content-lineage tool.

If additional confirmed aliases are discovered, report them and their implications before modifying further authoritative metadata.

The purpose is to catch material leakage, not to claim perfect duplicate recognition.

Record limitations, including transformations the current prototype cannot reliably detect.

## 7. Disposition of Historical L2 and Other Models

The audit confirmed training exposure for:

- `l2_scratch_768_color_s20261021`.
- Four October 16 L1 training runs.

The net-model packages included affected footage in validation only, based on current evidence.

The shipped `ball_heat` checkpoint's ancestry remains unknown because its package is unavailable.

### Owner decision

Retain the affected L2 model and historical artifacts.

Annotate the model and its experiment as exposed.

Void the claim that this model satisfies the original D-017 lineage-isolation requirement.

It may remain available as a development comparator, but it must not be presented as a clean lineage model.

Update the relevant lineage and experiment documentation.

Where accessible, inspect desktop training manifests and checkpoints to resolve unknown ancestry.

Do not claim that a model trained on a package without evidence that the run actually consumed it.

Do not claim that remaining holdouts are pristine final-test recordings.

Future corrected L2 training is a separate experiment requiring a validated package and owner-approved preregistration. It is not authorized here.

## 8. ProcessedMetadata Cleanup

The owner authorizes the one-time cleanup of the approximately 5.5 GB generated `ProcessedMetadata` leak after #173 is merged and verified.

Before deletion:

- Identify the exact directory and contents.
- Verify they are disposable analysis-generated metadata.
- Confirm no active processing job is using them.
- Confirm no user annotations, authoritative provenance, production video metadata, or irreplaceable model evidence are included.
- Record the file inventory and size.

Delete only the confirmed generated cache.

Report recovered disk space.

Do not delete unrelated experiment artifacts, models, source footage, or historical datasets.

Verify that a subsequent bounded analysis run no longer recreates the unwanted metadata.

## 9. Recover the Unreadable Grass Recording

Investigate `grs_gnd_shade_land_self_02`.

The owner authorizes attempting to recover or re-fetch the recording from its documented original source.

Verify the recovered footage's identity and time range before reusing existing labels.

Do not silently substitute a different recording under the same identity.

If recovery is impossible, mark the recording unavailable or ineligible with a reason.

Preserve its existing records.

Do not delete the card without a separate owner decision.

## 10. Produce a Corrected Rally-Classifier Export

The owner authorizes a new classifier export once the training-relevant integrity blockers are resolved, the required corrective PRs are merged, and the corrected project passes audit.

### Existing artifact

Preserve this dataset unchanged:

- Name: `rc-v1-20261108`.
- Export commit: `712f048`.
- 49 recordings.
- Train: 38.
- Development validation: 5.
- Tune: 6.
- 25 reported recording groups.
- Dataset digest: `1b1e6898…`.
- Manifest digest: `237f2fb7…`.
- Original validator result: 0 errors, 0 warnings.

Its contents reportedly exclude all three affected training aliases, but its frozen withheld record predates the corrected closure.

The owner does not accept an exception for that stale record.

### New export requirements

Create a new versioned dataset under the corrected authoritative manifest.

Verify:

- Full corrected withheld closure.
- Current source and content identities.
- Current split-manifest hashes.
- Zero hard audit findings.
- Confirmed recording eligibility.
- Complete rally-marking coverage where required.
- Correct excluded spans and cut ranges.
- Correct treatment of continuous versus edited footage.
- No duplicate or related source group crossing evaluation folds.
- Detector identity and configuration.
- Baseline output identities and scoring parity.

Preserve the `rally_classifier_dataset_v1` and `rcf_v1` contracts unless a separately reviewed contract revision is genuinely necessary.

### Evidence reuse

Investigate whether verified existing ball evidence can be reused to avoid another expensive full detector run.

Reuse is permitted only if a supported, tested operation establishes that:

- The underlying footage content is unchanged.
- The feature and label contracts are unchanged.
- Detector and pipeline configurations match.
- The evidence belongs to the correct recording and source identity.
- The current eligibility and withholding checks pass.
- Baseline outputs remain valid.
- The new package is independently validated.
- The new package has its own version, provenance, hashes, and ledger record.

Do not edit the previous dataset's manifest or hashes to make it appear current.

Do not bypass normal package admission using cached evidence.

If safe evidence reuse is unavailable, perform a normal fresh export.

### Execution

Before the export:

- Ensure the footage share is mounted and readable.
- Close competing RallyLab writers.
- Verify sufficient disk space.
- Use a clean, reproducible build from the correct merged revision.
- Generate and inspect the candidate/exclusion plan.

If the plan is consistent with the corrected dataset expectations and no new material identity finding appears, proceed with the authorized export.

If a new material discrepancy appears, stop and report it.

Afterward, run the external validator against the current authoritative withheld closure.

Report the new dataset name, paths, counts, group identities, digests, validation results, and differences from `rc-v1-20261108`.

Do not overwrite the historical package.

## 11. Prepare the First Classifier Training Experiment

Update the existing experiment:

`EXP-20261103-temporal-rally-classifier-prereg`

Use the actual corrected dataset rather than the old provisional 34-recording estimate.

### A. Dataset readiness

Resolve the outstanding data-readiness decisions from PR #138 and the existing preregistration, including:

- Confirmed footage types.
- Negative-label coverage auditing.
- Minimum number of independent recording groups contributing valid negatives.
- Handling of edited, restricted, and uncertain footage.
- Independent evaluation-footage acquisition.

Do not assume a declared-complete pass establishes perfect negative ground truth.

Do not count missed serves, excluded spans, unknown intervals, or time-breaking footage as ordinary negatives contrary to the existing contract.

### B. Grouped cross-validation

Recompute the actual recording groups using the corrected identities.

Prepare the five-fold grouped development evaluation.

Requirements:

- All related recordings stay in the same fold.
- No duplicate content crosses folds.
- Stratify by beach, grass, and indoor where feasible.
- Report group count, recording count, rally count, positive duration, and valid negative duration per fold.
- Meet the existing preregistration's negative-coverage requirements or explicitly report a failure.
- Report restricted recordings separately.
- Keep nested hyperparameter selection, calibration, and decoding-parameter selection inside the training folds.

The old `train`, `dev_val`, and `tune` assignments are historical development roles, not the complete classifier evaluation pool.

Use every eligible development recording through the approved out-of-fold protocol.

Do not force five folds if the corrected grouping makes the protocol infeasible. Report the problem and propose an amended preregistration.

Freeze fold assignments in an immutable, versioned experiment input linked to the dataset digest. Do not silently modify an already sealed dataset.

### C. Models

Prepare the existing planned comparison:

- R0: committed deterministic FSM.
- R0′: previously evaluated D-029 reference settings, with exposure caveats.
- R1: regularized logistic regression over temporal ball features.
- R2: small temporal convolutional network.

Preserve the approved feature, look-ahead, calibration, and scoring contracts.

Prepare the trainer implementation and synthetic tests where needed.

Do not substitute the older within-video logistic-regression script for the new grouped evaluation protocol.

### D. Success criteria

Use the established metrics:

- Complete-rally recall.
- Missed and clipped rallies.
- False clips.
- Merged and split rallies.
- Start/end boundary errors.
- Dead-time retention.
- Per-surface and per-group performance.
- Paired group-level uncertainty intervals.

Clearly distinguish development evidence from independent final evaluation.

The first experiment must establish whether a learned classifier improves the existing pipeline, not merely whether it achieves high frame-level classification accuracy.

### Training gate

No actual model training, hyperparameter sweeps, calibration fitting, or real candidate scoring is authorized.

Prepare the complete preregistration, trainer, fold assignment, dataset hashes, and readiness report for the owner's final approval.

## 12. Keep the Workstream Focused

The critical path is:

1. Merge and verify the four corrective PRs.
2. Apply D-036.
3. Close training-relevant guard gaps.
4. Complete the bounded identity audit.
5. Produce the corrected classifier dataset.
6. Freeze the grouped evaluation and preregistration.
7. Obtain owner approval to train.

Do not delay this entire workstream because some historical desktop artifact cannot be located or because perfect duplicate detection is not possible.

Document unknowns honestly.

If an issue does not threaten the corrected classifier dataset, keep it as a separately tracked follow-up.

Do not expand into player-pose research, court calibration, production iOS integration, backend deployment, or TestFlight.

## 13. Required Final Status Report

Provide a concise owner-facing report containing:

### Completed

- PRs merged and exact merge commits.
- Final build, test, and CI evidence.
- D-036 application results.
- Corrected withheld and training counts.
- Confirmed identity relationships.
- Disk cleanup results.
- Corrected classifier export results and hashes.

### Outstanding

- Any remaining consumer protection gaps.
- Additional proposed content aliases.
- Unresolved historical model ancestry.
- Backend or phone-server reconciliation issues.
- Any new PRs awaiting owner review.
- Any limitations affecting classifier evaluation.

### Classifier readiness

Answer directly:

1. Is the corrected project free of known hard identity leakage?
2. Does the new classifier dataset pass validation against the corrected withheld closure?
3. How many eligible recordings and independent groups are available?
4. Are the proposed folds feasible?
5. How many groups contribute trustworthy negatives?
6. Is the negative-coverage audit complete?
7. Is the preregistration ready for approval?
8. What exactly remains before training can begin?

Include links to relevant PRs and experiment records.

**Stop at the owner training-approval gate. Do not start training, merge additional unapproved PRs, or deploy anything.**
