---
name: classifier-readiness-authorization
status: accepted (owner authorisation); its decision is D-038
created: 2026-11-15T06:45:31Z
updated: 2026-11-15T06:45:31Z
source: owner, delivered to Claude Code on 2026-11-14 (evening, MST)
---

> Verbatim record of the owner's authorisation, reproduced as received. In summary:
> - PRs #179, #176, #177, #180, #181, #178 and #182 may be merged, in that order, after their heads, checks and reviews are verified; the #177/#180 conflict is resolved keeping both protections.
> - The preregistration's amendments A1–A13 are accepted as proposed, with reporting requirements on A4, A8, A9, A10 and A13.
> - Negative-label verification is **not** waived: the coverage-audit protocol of PR #138 is adapted to `rc-v1-20261112`, frozen before the draw, and started with a 12-recording pilot that the owner reviews; only reviewed-clean intervals or eligible Stage 1 coverage supply trusted negatives (G7).
> - Both existing exports are preserved; a change to the negative-label contract means a new versioned export after the reviewed changes are approved.
> - Operational work in parallel: the server's withheld list, phone model tasks, device acceptance for #181, a read-only audit of server rows and row-level security, the recovered grass recording, a plan for new final-test footage.
> - No model is trained, tuned, calibrated or scored; nothing is deployed or released; no PR beyond the seven is merged.

# BumpSetCut — Owner Authorization: Merge Remaining Corrective PRs and Complete Classifier Readiness

**Date:** 2026-11-14  
**Repository:** `bwierzbo/BumpSetCutApp`  
**Scope:** Complete data integrity, merge reviewed trainer tooling, conduct negative-coverage audit, and finalize the first classifier experiment.

## Owner decisions

The owner authorizes merging PRs #176–#182 in this order:

1. #179 — D-037 completion record.
2. #176 — Protected-content audit.
3. #177 — Full withheld closure and metadata-only registration.
4. #180 — Stale manifest/package protections.
5. #181 — Labeling sync and phone withheld protections.
6. #178 — Classifier trainer tooling.
7. #182 — Preregistration update and frozen folds.

Verify the exact current heads, required CI checks and independent reviews before each merge.

Resolve the #177/#180 conflict while preserving both protections. Request fresh Codex review on changed heads. Check the overlapping #177/#181 TrackLabelModel changes and #177/#179 MODEL_LINEAGES changes.

Run the applicable combined builds, full tests and CI after merging.

No actual model training is authorized.

## Preregistration amendments

Accept A1–A13 as proposed, with these reporting requirements:

- A4: retain eligible continuous handheld footage, but report handheld recordings separately and include a sensitivity analysis excluding them.
- A8: report whenever the decoder-selection fallback is used, including why the recall constraint was not met.
- A9: document the calibration limitation caused by class-balanced logistic regression.
- A10: retain the production FSM as the primary baseline and explicitly report its above-net-rule advantage. Investigate a matched baseline without this rule where practical, without changing the primary baseline or silently altering the existing dataset.
- A13: preserve all historical exposure caveats. This is development evaluation, not independent final-test evidence.

Record the accepted amendments and incorporate any necessary reviewed tooling changes.

## Negative-coverage audit

The owner does not waive negative-label verification.

Adapt the protocol and sample-draw tool from PR #138 to the actual corrected dataset `rc-v1-20261112`.

Update the old sample constraints for the current 49 recordings, 25 groups, 31 continuous recordings and corrected withheld closure. Do not blindly retain constraints based on the obsolete 34-recording inventory.

Before drawing:

- Freeze the audit protocol, sample selection and pass/fail criteria.
- Preserve group independence.
- Sample four eligible continuous recordings per surface where feasible.
- Refuse all protected recordings and aliases.
- Bind the draw to the dataset, current marks and source identities.
- Prepare the necessary inventory adapter and audit-recording mechanism.
- Reconcile the existing G6 requirement with the proposed G7 coverage requirement.

Provide an efficient RallyLab review workflow or queue that lets the owner review only the intervals between existing marks.

Hide ball-path and pipeline predictions during the audit. Do not fabricate human review or automatically certify unmarked intervals.

Record missed rallies, missed serves, boundary errors, non-rally activity, edited footage and uncertainty separately.

Start with the 12-recording pilot.

Arrange the blind repeat sample and document reviewer independence accurately.

If the pilot fails the agreed threshold, report the findings and prepare targeted corrective labeling.

If the pilot passes, proceed to review the remaining eligible continuous recordings supplying negative labels. A passing sample does not automatically certify unaudited recordings.

Only explicitly reviewed clean intervals or eligible Stage 1 verified coverage may supply trusted negatives under the adopted G7 policy.

Do not allow edited footage to supply full-video negative labels.

Prepare the reviewed coverage sidecar, exporter and validator changes required by the adopted protocol.

Do not merge additional PRs beyond the seven explicitly authorized here without owner approval.

## Corrected classifier dataset

Preserve both existing exports:

- `rc-v1-20261108`
- `rc-v1-20261112`

If the coverage audit changes the negative-label contract, existing marks or training masks, create a new versioned export after the reviewed changes are approved.

Never modify a sealed dataset or frozen folds file in place.

Recompute eligibility, group counts, valid-negative coverage, fold feasibility and baseline parity against the corrected artifact.

Reuse verified detector evidence only through a supported and tested operation.

Verify that the final negative-coverage gate is met. If fewer than the required groups contribute trusted negatives, report the exact deficiency rather than weakening the gate.

## Parallel operational work

1. Open RallyLab on corrected Scratch and verify that the server withheld list updates from 21 to 24 names.
2. Verify that newly protected aliases cannot receive ordinary phone model tasks.
3. Prepare #181 for physical-device acceptance and a subsequent separately approved TestFlight build.
4. Audit existing server clips, tracks and lead RLS behavior. Do not change RLS or apply migrations without explicit approval.
5. Restore `grs_gnd_shade_land_self_02` only after verifying the recovered source identity and time range. Preserve its records.
6. Prepare a new independent final-test footage acquisition plan. Reserve recordings before development-model exposure.

Keep player-pose and court-calibration research separate.

## Final deliverable

Return a concise classifier-readiness report with:

- All seven merge commits and final CI/test evidence.
- Accepted amendments A1–A13.
- Audit protocol and frozen sample.
- Owner labeling workload and outstanding audit tasks.
- Verified negative-coverage results when completed.
- Final dataset name, manifest hash, digest and withheld closure.
- Frozen grouped folds and counts.
- Baseline parity and trainer dry-run results.
- Remaining historical exposure limitations.
- Any operational or server issues that still need an owner decision.

Update the preregistration using the final validated dataset and exact merged script hashes.

Stop at the owner training-approval gate.

**Do not fit R1 or R2, run real hyperparameter sweeps, calibrate candidates, perform candidate scoring, deploy, release TestFlight or merge additional unapproved PRs.**
