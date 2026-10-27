---
name: next-owner-decisions
status: accepted
created: 2026-10-27T06:13:07Z
updated: 2026-10-27T06:13:07Z
source: owner, delivered to Claude Code on 2026-10-27 (just after midnight, MDT) after #99–#101 and #103 merged and migration 048 was verified live
---

> Verbatim record of the owner's decisions, reproduced as received; the heading is the owner's. In summary:
> - An owner-only internal TestFlight upload of the merged RallyLab Labeler app is approved, for the owner's account only.
> - Migration 049 is supported but not yet authorised for deployment. Two review concerns come first: the storage update policy must protect the destination name, and the test stand-in must carry the live `label_videos.status` constraint.
> - Rebasing PR #102 onto main is authorised. Its merge, migration 050, the pilot freeze, a published draw and pilot annotation are not.
> - L2 training continues unchanged.
>
> Note on item 1, recorded when received: the RallyLab app's internal TestFlight group "Labelers" (three testers) has access to all builds, as does the owner's group "Me". An upload as configured would also be installable by those three testers. The upload is held until the owner decides how to keep it owner-only.

# BumpSetCut — Next Owner Decisions

I authorize the following.

**1. Owner-only internal TestFlight**

I approve building and uploading the current merged RallyLab Labeler iPhone application to TestFlight for my account only.

No external testers, public release, new footage uploads, bulk copy remakes, or protected-recording annotation are authorized.

Verify the final iOS build, target membership and submission configuration before uploading. Report the TestFlight build number and installation instructions.

I will personally perform the physical-device UI and functionality checks.

**2. Migration 049 — Final corrections before deployment**

I support deploying migration 049 to restrict protected-footage access, but deployment is not yet authorized.

First address two independent-review concerns:

- Ensure the storage UPDATE policy also protects the destination object name, not just the source. Add a regression test for unauthorized renames/moves.
- Make the PostgreSQL test stub reproduce the live `label_videos.status` CHECK constraint. Replace the invalid `labeled` test value with an allowed status.

Run the complete 048 and 049 test suites, ci_check, and independent review on the resulting head. Preserve the existing functionality and lead-only privileges.

Return the corrected PR for final merge and live deployment authorization.

Do not delete, move or alter existing protected footage or historical annotation evidence.

**3. PR #102**

I authorize rebasing the pilot infrastructure PR #102 onto the latest main.

Run the affected tests, verify migration 050 follows migration 049, and obtain a clean independent review on the final head.

Do not merge #102, apply migration 050, freeze the pilot selection, publish a draw, or begin pilot annotation without separate approval.

**4. L2**

Continue the existing L2 training run unchanged. Preserve logs and checkpoints. No additional seed, protected-holdout evaluation, or promotion is authorized.

Return a concise deployment and TestFlight readiness report, with any remaining blockers.
