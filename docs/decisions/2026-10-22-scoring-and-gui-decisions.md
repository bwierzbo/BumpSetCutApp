---
name: scoring-and-gui-decisions
status: accepted
created: 2026-10-22T04:54:05Z
updated: 2026-10-22T04:54:05Z
source: owner, via independent review, delivered to Claude Code on 2026-10-22
---

> Verbatim record of the owner's decisions on the scoring contract (PR #79) and the Dataset Review & Repair GUI (PR #82). The normalised entry is [D-020](DECISION_LOG.md#d-020). This file is the primary source; do not edit it.

Independent review — BumpSetCut scoring and RallyLab GUI

The following technical decisions are approved for implementation planning.

1. Excluded-time masking

Accept the scoring contract's masked-boundary approach. Boundary errors use scorable prediction boundaries, not intervals that have been excluded from evaluation.

Add separate diagnostics for whether predictions enter excluded time, the number of excluded seconds overlapped, and partially masked predictions. These diagnostics do not affect primary detection scores.

Preserve disconnected scorable pieces for matching and add regression tests.

2. False clips

Accept that an exported clip containing no legitimate rally and 1.8 seconds of scorable dead time counts as one false clip.

Count by original exported segment, not the number of pieces after masking. Report scorable dead time and excluded time delivered separately.

Never infer verified dead time from unknown or partially annotated footage.

3. Complete-rally criterion

Accept the initial 0.98 retained-fraction threshold, with both serve-contact and ball-dead events required inside the actual exported interval.

Preserve the half-open event-containment convention and video-end exception. Track merged rallies separately even when both are completely retained.

Treat 0.98 as a provisional operational threshold to revisit using the Phase 1A calibration evidence.

4. Dataset Review & Repair GUI

Approve C1 first, followed by the health queue and controlled correction capabilities.

Every application of a proposed repair must be explicit, logged, backed up or source-preserving, and validated.

Trimming produces a separately identified derived recording linked to the original. The original remains untouched; all split and holdout restrictions carry through the parent-source relationship.

All GUI and headless operations must refuse protected recordings by default. Historical legacy-holdout diagnostic exceptions require separate owner authorization and an exposure-ledger entry. Lineage-holdout access remains separately gated.

Do not clean up the 54 dangling frame records yet.

5. Existing export

Do not interrupt or alter the running L2 export.

After successful preflight, perform desktop package verification, complete the preregistration with hashes and reproducibility evidence, and return for final training approval.

No L2 training or protected-holdout evaluation is authorized by these decisions.

Continue with separate scoped PRs and independent Codex review for the post-export implementation work.
