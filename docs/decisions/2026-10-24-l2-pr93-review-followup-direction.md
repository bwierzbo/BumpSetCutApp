---
name: l2-pr93-review-followup-direction
status: accepted
created: 2026-10-24T23:50:37Z
updated: 2026-10-24T23:50:37Z
source: owner, delivered to Claude Code on 2026-10-24 after the independent review of PR #93
---

> Verbatim record of the owner's follow-up after PR #93 (`fix/l2-undecodable-leading-pictures`) had its Codex review: the HEVC exception, first numbered D-024 in that PR, is renumbered D-025 because D-024 is the progressive RallyLab review decision of PR #90; the rebase, re-review and the remaining gates are set out. Reproduced as received; the heading is the owner's.

# L2 PR #93 — Independent Review Follow-up

The technical approach in PR #93 is acceptable for the L2 export recovery, subject to one documentation conflict and the existing execution gates.

PR #90 is already open for the progressive RallyLab review roadmap and assigns D-024 to that decision. PR #93 independently assigns D-024 to the HEVC exception.

Preserve the RallyLab decision as D-024 and renumber the HEVC exception as D-025.

After PR #90 is independently approved and merged:

1. Rebase PR #93 on the updated main.
2. Update all HEVC decision references from D-024 to D-025, including the D-022 amendment, journal comments, documentation, and reports.
3. Preserve the verbatim owner-direction text; update only its explanatory metadata and references.
4. Recheck CI, controlled-document compliance, builds, and tests.
5. Obtain a clean Codex review on the new head and resolve or document the older review threads.
6. Return the revised commit for final merge authorization.

Do not restart the export until the revised PR is approved and merged and both SMB shares are verified accessible under an approved network configuration.

When authorized to resume, preserve the current journal and 34,515 existing frames, retain strict identity and frame validation, and report every accepted omission.

If omissions affect unexpected recordings or validation clips, pause for owner review.

L2 training and protected-holdout evaluation remain separate authorization gates.
