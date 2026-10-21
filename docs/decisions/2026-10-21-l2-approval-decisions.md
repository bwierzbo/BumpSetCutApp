---
name: l2-approval-decisions
status: accepted
created: 2026-10-21T23:41:40Z
updated: 2026-10-21T23:41:40Z
source: owner, delivered to Claude Code on 2026-10-21 after Codex's final clean review of PR #73
---

> Verbatim record of the owner's decisions on PR #73 and the first L2 preregistration, after [D-018](DECISION_LOG.md#d-018). The normalised entry is [D-019](DECISION_LOG.md#d-019). This file is the primary source; do not edit it.

Owner decisions for PR #73 and EXP-20261021-l2-scratch-prereg:

**1. Merge PR #73.**

I explicitly authorize: **merge PR #73**, provided the final merge checks pass. This does not authorize L2 training.

**2. L2 preregistration: technical recipe approved, with amendments required before final experiment authorization.**

Approve the proposed from-scratch VballNetV4c configuration: 768×432, color, nine frames, 60 epochs, batch size 8, seed 20261021, and no pseudo-labels.

Amend H1. Do not use the historical L1 confidence interval from a different validation dataset as a formal success/failure criterion. Establish a paired, methodologically compatible comparison using the same eligible development-validation data. Historical results can remain descriptive.

Record that the ball tracks were initially proposed by L1 but personally reviewed and corrected by the owner to cover entire rallies. These are human-verified complete-rally ball labels. Potential model-assisted rally-selection bias remains a separate limitation.

Authorize only the first seed in the proposed experiment. A second training run requires separate approval.

**3. Confirm legacy-holdout exclusion.**

All 16 lineage-holdout and five legacy-holdout recordings, including identity-linked aliases, must remain excluded from L2 training and development-validation packages.

After merging, complete the preregistration amendments, export the isolated package, perform the full preflight, fill in package hashes and reproducibility information, and return the completed record for final approval.

**Do not start training or evaluate the protected holdout until I explicitly authorize those actions.**
