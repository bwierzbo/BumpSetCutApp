---
name: stage1-phone-validation-l2-comparison
status: accepted
created: 2026-10-30T21:19:06Z
updated: 2026-10-30T21:19:06Z
source: owner, delivered to Claude Code on 2026-10-29 (MDT) after PR #107 was Codex-clean and L2 training had finished
---

> Verbatim record of the owner's decisions, reproduced as received; the heading is the owner's. In summary:
> - PR #107 is approved for merge at `185d0ca`, including the updated Stage 1 plan. It was merged 2026-10-29 as `af2a74c`.
> - A new internal TestFlight build is authorised under the existing distribution arrangement. Build `202610292132` (from `af2a74c`) was uploaded 2026-10-29. Apple first refused the upload until the owner accepted an updated Program License Agreement. The build is VALID in the Me and Labelers groups. The physical-iPhone tests are the owner's and are not recorded as done.
> - Only the preregistered development-validation comparison of L2 against L1 (H1) is authorised. It ran 2026-10-30; results in `docs/ml-roadmap/experiments/EXP-20261021-l2-scratch-prereg.md` §11.
> - Not authorised: protected-holdout evaluation, a second seed, promotion, Core ML deployment or dataset changes. PR #102, the pilot freeze and migration 050 stay on hold.

# BumpSetCut — Stage 1 Phone Validation and L2 Comparison

I approve merging PR #107 at reviewed head `185d0ca`, provided the head remains unchanged, the checks are satisfactory, and no unresolved review findings exist. This includes the updated Stage 1 plan.

After merging, build and upload a new internal TestFlight release using the existing approved distribution arrangement. Report the build number. I will perform the physical-iPhone tests; do not mark them complete in advance.

For L2, I authorize **only the preregistered development-validation comparison against L1**:

- Score the existing shipped L1 checkpoint against the exact L2 validation package using the approved `--score-only` procedure.
- Preserve the checkpoint identity, data hashes, window digest, and complete output.
- Fetch with `--no-score`.
- Run the preregistered paired comparison on identical validation windows, reporting video-level and recording-group-level intervals, overall and by surface.
- Record the findings without claiming equivalence merely because an interval includes zero.

This is not authorization for protected-holdout evaluation, a second training seed, model promotion, Core ML deployment, or changes to the dataset.

Keep PR #102 and the pilot freeze on hold until the phone's integration checks are complete. Do not apply migration 050.

Preserve the completed L2 checkpoints, metrics, logs, and training-recovery history.

Return the paired comparison results and the new TestFlight build details for my review.
