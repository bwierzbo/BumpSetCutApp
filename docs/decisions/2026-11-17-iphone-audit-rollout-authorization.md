---
name: iphone-audit-rollout-authorization
status: accepted (owner authorisation); D-039 accepted
created: 2026-11-17T21:16:03Z
updated: 2026-11-17T21:16:03Z
source: owner, delivered to Claude Code on 2026-11-17
---

> Verbatim record of the owner's authorisation, reproduced as received. In summary: migration 054 applied to the live
> project; PR #189 squash-merged and D-039 accepted; an internal TestFlight build of the Labeler; physical-iPhone
> acceptance on a temporary Accept- draw, removed afterwards; the real pilot prepared for the owner, who gives the first
> legitimate verdict himself. No training, detector, scoring or protocol change; no unrelated PR.

Proceed with the BumpSetCut iPhone Coverage Audit rollout under the following owner authorizations.

1. Migration 054 — APPROVED

* Apply supabase/migrations/054_label_coverage_audit.sql to the live Supabase project.
* Verify the database backup/recovery path before applying.
* Confirm the migration succeeds and existing data, RLS protections, and labeling functionality remain intact.

2. PR #189 — APPROVED

* Accept D-039 and the associated configuration-item updates.
* Squash merge PR #189 into main, provided CI is passing, the latest Codex review is clean, and no unresolved findings remain.
* Verify the resulting main branch and run appropriate post-merge checks.

3. Internal TestFlight — APPROVED

* Build the Labeler iOS app from the verified main branch.
* Distribute through TestFlight to designated internal testers only.
* No external testing, public release, or unrelated application deployment is authorized.

4. Physical iPhone acceptance testing — APPROVED

* Run RallyLab synchronization with the footage share mounted to publish the audit draw and recording states.
* Publish a temporary acceptance-test draw under a separate Accept- project name. This isolated server write is authorized.
* Do not modify or contaminate the real G7 pilot.
* Verify that the iPhone can download footage, play audit intervals, record verdicts, persist progress, and synchronize with RallyLab.
* Verify reviewer identity, viewing evidence, draw identity, timestamps, conflict handling, and synchronization status survive the round trip.
* Remove temporary acceptance-test data after successful verification without touching the real pilot.

5. Real pilot acceptance

* Once the temporary acceptance test passes, prepare the real G7 pilot for my iPhone.
* I will personally review and submit the first legitimate audit verdict on the phone.
* Verify that RallyLab receives that verdict correctly, with all associated evidence and metadata intact.
* Do not fabricate or automatically submit a real pilot verdict.

Restrictions

* Do not begin model training, change detector behavior, modify scoring logic, or alter the frozen G7 audit protocol.
* Do not merge unrelated PRs.
* Preserve all existing withheld-footage and training-eligibility protections.
* Stop and report any blocking failure rather than bypassing safeguards.

Report back with:

* Migration 054 deployment and verification results.
* PR #189 squash-merge SHA and post-merge checks.
* Internal TestFlight build number and distribution status.
* Temporary iPhone acceptance-test results.
* Any remaining blockers before I can begin auditing the real pilot from my iPhone.

Proceed autonomously within these approvals. Do not request additional approval for the actions explicitly authorized above. Stop at the first real pilot verdict for my manual review.
