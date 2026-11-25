---
name: d017-lineage-correction-authorization
status: accepted (owner authorisation); its decision is D-036
created: 2026-11-10T19:52:08Z
updated: 2026-11-10T19:52:08Z
source: owner, delivered to Claude Code on 2026-11-10 (midday, MST)
---

> Verbatim record of the owner's authorisation, reproduced as received. In summary:
> - Option A is approved: the withheld recordings stay reserved and the duplicate training recordings are excluded; the holdouts are not un-reserved to enlarge the training pool.
> - The work is non-destructive, auditable, reproducible and independently reviewed: backup with hashes first, developed against an isolated project copy, the correction prepared for owner review before it is applied to the live project.
> - Root cause, a content-lineage audit that proposes and never decides, an audit of every consumer, a package-to-checkpoint ancestry report, a check of the completed classifier dataset, and an assessment of the ProcessedMetadata issue.
> - No merge, training, deployment, change to live Scratch or regeneration of the classifier dataset without a separate owner decision. No new decoding of protected footage to improve the audit.

# BumpSetCut — Owner Authorization: D-017 Lineage Correction & Content-Leakage Audit

Date: 2026-11-10
Repository: bwierzbo/BumpSetCutApp
Starting point: Current main, including merged PRs #168–#171
Scope: Dataset integrity, model lineage, withheld-footage protection, and classifier training readiness
Owner decision: Option A approved

## 1. Objective

Resolve the newly discovered lineage-holdout contamination and strengthen the protections that allowed re-encoded duplicates to escape the existing identity checks.

The goal is to ensure that future training, evaluation, exports, and model comparisons cannot accidentally use footage reserved for evaluation.

The owner approves Option A: preserve the withheld recordings and exclude the two duplicate training recordings.

Do not un-reserve the holdouts to increase the training pool.

This work must be non-destructive, auditable, reproducible, and independently reviewed.

## 2. Confirmed Findings

Two training recordings contain the same visual footage as two lineage-holdout recordings:

| Training recording | Protected recording |
|---|---|
| grs_ele_sun_land_self_01 | grs_extra_self_06 |
| grs_sid_sun_port_self_01 | grs_extra_self_12 |

Evidence:

* Decoded frames at 5, 150, and 290 seconds were visually identical in each pair.
* The files have different encodings, sizes, and fingerprints.
* The holdout files’ current content fingerprints match the fingerprints originally registered to the corresponding training cards.
* Stored card fingerprints have become stale.
* Both training copies appear in historical training-package exposure records.

Affected historical packages include:

* Scratch-multiframe-20261016-2018
* Scratch-L2-multiframe-20261021-1917
* Two net-model packages created November 2.

The available evidence establishes package exposure but does not yet establish which model checkpoints trained on those packages.

Do not claim more than the evidence supports.

## 3. Protect Existing Work First

Before changing project metadata:

1. Inspect AGENTS.md, CLAUDE.md, the working agreement, D-017, D-018, the split manifest, ReservedVideos, LineagePackage, DatasetAudit, ExposureLog, SourceRegistry, and all consumers of withheld identities.
2. Check the working tree and preserve the uncommitted Xcode project.pbxproj re-sort. Do not reset, overwrite, or accidentally include it.
3. Create a verified backup of the relevant Scratch project metadata, manifests, labels, source registry, and exposure logs.
4. Record SHA-256 hashes of the original files.
5. Develop and test the correction against an isolated project copy.

Do not silently modify live Scratch during implementation.

Prepare the verified correction for owner review before applying it to the live project.

## 4. Implement Option A

Create a documented, non-destructive metadata correction that links both training copies to their corresponding protected recordings.

Requirements:

* Both training copies must inherit withheld status through authoritative identity relationships.
* Preserve all existing rally marks, ball annotations, source records, and exposure history.
* Do not delete recordings or erase historical mistakes.
* Do not rewrite exposure-ledger dates or change their original meaning.
* Keep all 16 lineage-holdout names reserved.
* Keep all five legacy holdouts protected.
* Preserve existing source identities and provenance unless a correction is explicitly justified and recorded.
* Apply the correction through the project’s established identity and alias mechanisms rather than adding two special-case filename exclusions.

The corrected withheld closure must reject both copies across every relevant consumer.

If the existing identity model cannot safely represent re-encoded duplicates, propose the smallest backward-compatible schema extension necessary.

Do not allow the correction to create a train/holdout identity conflict that downstream consumers silently ignore.

## 5. Investigate the Root Cause

Determine precisely why the L2 package protections failed to recognize the duplicates.

Investigate:

1. Stored fingerprint versus current content fingerprint.
2. Changes in original video files after source registration.
3. Re-encoding and proxy identity differences.
4. Alias-closure behavior.
5. Cache invalidation and stale identity records.
6. Package-generation preflight behavior.
7. Whether any consumer assumes a stored fingerprint proves current content identity.
8. How protected footage could appear under a different card identity.

Produce a root-cause report with file paths, relevant code locations, reproducible evidence, and recommended fixes.

Do not settle on stale fingerprints as the explanation merely because they are the leading hypothesis.

## 6. Strengthen Content-Lineage Protection

The existing leakage audit relies heavily on stored fingerprints and recorded identities.

That is insufficient for re-encoded duplicates.

Design a complementary content-lineage audit capable of proposing visually equivalent recordings even when their bytes differ.

Evaluate practical approaches such as:

* Frame perceptual hashing.
* Multiple timestamp samples.
* Temporal fingerprint sequences.
* Video duration and aspect-ratio comparisons.
* Normalized frame similarity.
* Existing provenance relationships.
* Confirmed source, session, and venue metadata.

The system should distinguish:

* Byte-identical duplicates.
* Re-encoded duplicates.
* Cropped or resized versions.
* Partial excerpts.
* Shared source videos containing different time ranges.
* Unrelated recordings that happen to look similar.

A proposed content match is not automatically an authoritative alias.

Require human confirmation for uncertain identity relationships, with recorded evidence and provenance.

Data-safety constraint: Do not newly decode protected footage merely to improve the audit. Use the existing confirmed evidence and authorized metadata first. If additional protected-video access is required, report the exact need and stop at the owner approval gate.

Do not modify the protected recordings or their evaluation labels.

## 7. Audit Every Consumer

Find every code path that uses split, alias, fingerprint, reserved, excluded, or withheld metadata.

Include at minimum:

* Dataset exporters and validators.
* L2 package generation.
* Rally-classifier exporter.
* Training and evaluation scripts.
* Model scoring.
* Pipeline tuning and comparison.
* Ball-path generation and pretracking.
* Player Lab research.
* Net-model proposals and exports.
* GUI labeling/review paths.
* Any shared processing code that can open reserved recordings.

For each consumer, document:

* Which identity source it trusts.
* Whether it uses current or stored fingerprints.
* Whether it honors the withheld alias closure.
* Whether a renamed or re-encoded protected copy is refused.
* What happens if a file is unavailable or unreadable.
* Whether the consumer fails closed.

Add regression tests for the two known duplicated pairs using synthetic fixtures wherever possible.

Also test missing files, stale metadata, renamed aliases, incomplete reads, and changed encodings.

Do not weaken existing fail-closed protections to improve convenience.

## 8. Trace Historical Model Exposure

Construct a package-to-checkpoint provenance report.

For each affected package, determine:

1. Whether the package was successfully completed and validated.
2. Which specific footage or labeled windows it contained.
3. Whether a training run consumed it.
4. Which resulting model checkpoints, if any, came from that run.
5. Whether those checkpoints were evaluated against the affected holdouts.
6. Whether historical model-comparison claims need to be qualified or withdrawn.

Use training manifests, checkpoint metadata, experiment records, and hashes.

Distinguish clearly between:

* Package exposure.
* Actual gradient-training exposure.
* Pretracking or inference exposure.
* Model-selection exposure.
* Final evaluation exposure.

If model ancestry cannot be proven, mark it unknown rather than declaring it clean.

Update MODEL_LINEAGES.md, D-017, and related experiment documentation.

The affected pair cannot support a claim of independent evaluation for any model actually trained on its duplicate.

Do not claim that the remaining 14 are pristine final-test footage. Their historical exposure status must also be respected.

## 9. Preserve the Completed Classifier Export

The completed dataset is:

rally_classifier_dataset_v1 — rc-v1-20261108

* Export commit: 712f048
* Exported recordings: 49
* Left out: 97
* Train: 38
* Development validation: 5
* Tune: 6
* Validation: 0 errors, 0 warnings
* Dataset digest: 1b1e6898…
* Manifest digest: 237f2fb7…

The exporter reportedly excluded both duplicate training recordings.

Do not delete, rewrite, or silently regenerate this dataset.

After preparing the metadata correction:

1. Revalidate the existing package.
2. Recompute eligibility and withholding against the proposed corrected source identities.
3. Check all 49 recordings for known content-lineage conflicts.
4. Verify that group identities and train/development assignments remain valid.
5. Report whether any previously exported recording would now be excluded.
6. Report whether the original dataset can remain valid or requires a new version.

A validator pass alone is not sufficient evidence of a newly corrected withheld closure if the validator only checks the identities frozen in the original manifest.

If the dataset requires regeneration, explain why and request separate authorization.

No classifier training is authorized by this assignment.

## 10. Additional Known Issue

Investigate the previously reported ProcessedMetadata leak.

Determine:

* Exactly what data is exposed.
* Which consumers are affected.
* Whether it creates train/evaluation contamination.
* Whether it is a blocker for the first classifier experiment.
* Whether it requires a separate corrective PR.

Do not expand the present PR unnecessarily.

If the issue is independent, document it and prepare a separate scoped fix.

## 11. Testing and Acceptance Criteria

The correction is complete only when:

* Both known training copies are excluded by the corrected withheld closure.
* All 21 existing withheld names remain protected.
* Historical annotation and exposure data are preserved.
* Missing or unreadable protected identities fail closed.
* Synthetic re-encoding and stale-fingerprint tests demonstrate the corrected protection.
* No known consumer bypasses the authoritative withheld rule.
* The package-to-checkpoint investigation reports confirmed, unknown, and affected ancestry separately.
* The 49-recording classifier dataset has been checked against the corrected policy.
* Existing RallyLab and relevant Python tests pass.
* The appropriate CI checks are green.
* Codex has independently reviewed the actual changes, with blocking findings resolved or explicitly returned to the owner.

Record any remaining limitations rather than claiming perfect duplicate detection.

## 12. Deliverables

Prepare:

1. A backed-up, non-destructive Option A correction.
2. A decision-record PR documenting the exclusion and historical exposure.
3. A root-cause investigation.
4. A content-lineage audit prototype or scoped implementation, as appropriate.
5. Updated withholding and consumer regression tests.
6. An affected-model ancestry report.
7. A classifier dataset integrity report.
8. An assessment of the ProcessedMetadata leak.
9. Updated lineage documentation, decision log, and experiment registry.
10. A concise owner summary of blockers remaining before classifier training.

Separate the identity-correction PR from larger experimental audit changes if necessary to keep review manageable.

Push only reviewed feature-branch changes. Request Codex review.

Do not merge, train, deploy, modify live Scratch, or regenerate the completed classifier dataset without a separate owner decision.

## 13. Final Owner Report

When finished, answer these questions directly:

1. Are both duplicate recordings now guaranteed to be rejected by every relevant consumer?
2. Why did the original protection fail?
3. Which historical model checkpoints are affected, confirmed or potentially?
4. Are there other suspected re-encoded duplicates?
5. Does the completed 49-recording classifier dataset remain eligible?
6. Are the grouped classifier development folds safe from known identity leakage?
7. Does the ProcessedMetadata issue block training?
8. What remains before we can approve the first R1/R2 classifier training experiment?

Stop at the owner review and merge gate.
