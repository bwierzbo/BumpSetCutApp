---
name: l2-labels-people-only-direction
status: accepted
created: 2026-10-23T20:06:35Z
updated: 2026-10-23T20:06:35Z
source: owner, delivered to Claude Code on 2026-10-23 after the provenance audit
---

> Verbatim record of the owner's direction after the read-only provenance audit of the L2 export (2026-10-23), which found 43 unreviewed, pre-tracked recordings in the planned package. Primary source for D-023. Reproduced as received; headings added.

Stage D — Owner Direction Following Provenance Audit

I accept the audit findings. The 43 unreviewed *_extra_self_* recordings were not intended for the human-verified L2 training dataset.

I want to stop wasting processing time on an export expected to fail preflight.

1. Safely interrupt Stage D. First determine the least disruptive, recoverable termination method. Preserve all existing frames, logs, journals, and validation evidence. Do not force-kill the process if package integrity or recoverability cannot be established. Report the result.

2. Preserve the 43 recordings and their annotations. Do not mark their rallies as false or modify their labeling records. They remain potentially useful for future rally-classification work.

3. Prepare a corrective PR implementing an L2-specific eligibility rule that excludes unreviewed machine-generated trajectories. Preserve the approved train/validation/holdout boundaries and prohibition on pseudo-label training.

4. Investigate reusing the existing package. Identify which validated image files can be preserved and propose a reversible method for handling the 43 unwanted clip folders. Do not remove or relocate them without separate authorization.

5. Recalculate the corrected package plan. Report expected unique images, training windows, validation windows, human-reviewed visible-ball targets, and hidden-ball targets.

6. Do not restart the export or train L2. Return the corrective PR, revised counts, and recovery plan for owner review.

The objective is to use our approximately 67,981 human-reviewed points, subject to the existing dataset splits, without contaminating L2 with unreviewed machine annotations.
