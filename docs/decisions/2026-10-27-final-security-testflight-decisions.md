---
name: final-security-testflight-decisions
status: accepted
created: 2026-10-27T06:43:14Z
updated: 2026-10-27T06:43:14Z
source: owner, delivered to Claude Code on 2026-10-27 (early morning, MDT) after PR #104 and PR #102 were Codex-clean
---

> Verbatim record of the owner's decisions, reproduced as received; the heading is the owner's. In summary:
> - The Labelers internal TestFlight group's automatic distribution may be turned off, with current access preserved. The upload must stop if owner-only distribution cannot be verified.
> - PR #104 is approved for merge at `7abcbe4`. It was merged 2026-10-27 as `91cca0b`.
> - Deploying migration 049 to the live project is authorised, with the checks listed. A controlled test upload of a small synthetic video through a non-lead test account is authorised. 049 was applied at 2026-10-27T06:39:52Z and verified (`docs/workflow/MIGRATION_049_PROTECT_FOOTAGE.md` §6).
> - The owner-only TestFlight upload is authorised once the distribution and migration checks pass.
> - PR #102 stays prepared; L2 continues unchanged.
>
> Note on item 1, recorded when it was carried out: App Store Connect's API refuses to change `hasAccessToAllBuilds` on an existing beta group (HTTP 409, "The attribute 'hasAccessToAllBuilds' can not be included in a 'UPDATE' operation"). The Labelers group still receives every build, owner-only distribution could not be verified, and the upload was therefore not made.

# BumpSetCut — Final Security and Owner-Only TestFlight Decisions

As project owner, I authorize the following actions.

## 1. TestFlight distribution

I authorize changing the existing **Labelers** internal TestFlight group's automatic build distribution so it no longer automatically receives every new build.

Keep the **Me** group enabled to receive the new build automatically.

Preserve all three existing labelers' access to the builds they currently have. Re-grant their current build access if needed.

Do not remove testers, delete groups, revoke existing builds unnecessarily, or change external testing settings.

Before uploading, verify that:

- Only my account will receive the new build.
- The three existing labelers retain access to their current build.
- The Labelers group will not automatically receive future builds.

If that configuration cannot be verified, stop before uploading.

## 2. PR #104 — Merge authorization

I approve merging PR #104 at reviewed head `7abcbe4`, including migration 049, the deployment documentation, and the recorded owner decisions.

Confirm the head is unchanged, the latest Codex review has no unresolved findings, and the required checks remain green.

Do not modify or delete existing protected footage or historical annotations.

## 3. Migration 049 — Separate deployment authorization

I explicitly authorize deploying `049_protect_withheld_footage` to the live Supabase project after PR #104 is merged.

Follow the approved deployment document.

Before deployment, verify migration 048 is present, the 21-recording withheld closure is published, and the intended SQL matches the reviewed commit.

After deployment, run the security and performance advisors and verify:

- Non-lead labelers cannot access protected footage, metadata, legacy annotations, or the unreferenced object.
- Direct storage reads and signed URL creation are refused for protected material.
- Eligible videos remain accessible.
- The lead account retains its required access.
- Existing records and objects remain preserved.

I also authorize a controlled upload test using a small synthetic, non-sensitive video through a non-lead test account, followed by deletion of only that newly created test object and record.

No existing footage may be deleted or modified for testing.

Record the results, including any remaining risk from previously issued signed URLs.

If a required security check fails, stop the rollout and report the failure. Do not silently weaken the access policies.

## 4. Owner-only TestFlight upload

Once the distribution and migration checks pass, I authorize uploading the existing verified Release archive of RallyLab Labeler, based on `0bfb30c`, to internal TestFlight for my account only.

No external testers or public distribution.

Report the exact build number, upload status, and installation steps.

The following physical-iPhone checks remain pending my participation:

- Rally Boundaries interface and playback
- Exact frame stepping and serve/dead-ball marking
- Downloaded-copy frame-identity gate
- Offline annotation and synchronization
- Real concurrent-edit conflict
- Protected-recording refusal
- Existing rallylabels and L2 dataset isolation

Do not claim these checks passed until they have actually been performed.

## 5. PR #102 — Pilot

Keep PR #102 prepared and reviewed.

Do not merge it, deploy migration 050, freeze the selection, publish the draw, or begin pilot annotation until I separately approve those actions.

## 6. L2 training

Continue the existing L2 run unchanged, preserving checkpoints, logs, and automatic recovery.

No second seed, protected-holdout evaluation, or model promotion is authorized.

Return a final deployment report and identify anything I need to do on my iPhone.
