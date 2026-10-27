---
name: stage1-integration-approvals
status: accepted
created: 2026-10-26T23:50:30Z
updated: 2026-10-26T23:50:30Z
source: owner, delivered to Claude Code on 2026-10-26 (evening, MDT) after PRs #100–#103 were Codex-clean
---

> Verbatim record of the owner's approvals, reproduced as received; the heading is the owner's. In summary:
> - PR #103 is approved for merge at `754485c`; it was merged 2026-10-26T23:44Z as `e0e4b27`.
> - PR #100 is approved for merge after integration and a clean review of its final head.
> - Applying migration 048 to the live project is authorised separately, to be followed by the security checks and the lead Mac client's publication of the withheld list and identities.
> - PR #101 is approved after #100 and the 048 verification, with the end-to-end checks required before the owner-only TestFlight build.
> - New owner decision on the protected-footage findings: restrict access, do not delete. A non-destructive access-control fix is to be prepared, tested and returned for separate deployment authorisation, taking migration-number priority over #102.
> - PR #102 stays prepared; its migration, the pilot freeze and pilot annotation are not authorised.
> - L2 training is untouched.

# BumpSetCut — iPhone Stage 1 Integration Approvals

I approve the following sequence.

**1. PR #103**

Approve merging PR #103 at reviewed head `754485c`, including the frame-identity evidence and documentation changes, provided its head and review status remain unchanged.

Do not relax the exact frame-identity commit gate.

**2. PR #100**

After #103 merges, integrate PR #100, run the affected tests and checks, obtain a clean review if its head changes, and merge it.

I approve its documented changes, including the Stage 1 synchronization rules, deployment documentation, and protected-footage inventory.

**3. Migration 048**

I separately authorize applying migration `048_label_rally_events` to the live Supabase project, using the approved deployment and rollback procedure.

Before applying, verify the exact migration contents, dependency state and recovery procedure. Afterward, run the security checks and have the lead Mac client publish the withheld closure and eligible original-footage identities.

Do not proceed to mobile rollout if those checks fail.

**4. PR #101**

After #100 is merged and migration 048 is verified, integrate the iPhone UI PR #101 against main.

Run both affected builds and tests. Obtain a clean review on its final head if rebasing changes the code, then merge it.

Verify the real sync, offline-save, concurrency-conflict, protected-refusal and downloaded-frame-identity workflows before releasing an owner-only internal TestFlight build.

**5. Protected footage — new owner decision**

I authorize preparing a narrowly scoped, non-destructive access-control fix for the protected-footage findings.

My decision is to restrict access, not delete the footage or historical annotations.

The fix must address direct storage access, signed URL creation, labeling video metadata and relevant legacy annotation reads. It must refuse protected identities and aliases for ordinary labelers, including direct API access.

Also restrict the unreferenced object until its identity is established.

Preserve the original objects, their hashes, historical annotation records and evidence of possible exposure.

Document any residual exposure risk from previously issued signed URLs.

Prepare and test the change, then return it for separate deployment authorization. Do not change live storage permissions yet.

Coordinate migration numbering with PR #102, which already contains migration 049. Prioritize protecting the existing footage over deploying pilot infrastructure.

**6. PR #102**

PR #102 may remain prepared and Codex-reviewed, but do not apply its migration, freeze the 24-rally selection, or begin pilot annotation without separate approval.

**7. L2 training**

Do not interrupt the existing L2 training process.

Keep automatic recovery and checkpoint preservation enabled. No protected-holdout evaluation, additional seed, or model promotion is authorized.

Return the merge results, migration 048 deployment evidence, security findings and remaining steps to the first owner-only iPhone TestFlight.
