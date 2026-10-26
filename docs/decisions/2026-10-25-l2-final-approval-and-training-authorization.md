---
name: l2-final-approval-and-training-authorization
status: accepted
created: 2026-10-26T01:26:49Z
updated: 2026-10-26T01:26:49Z
source: owner, delivered to Claude Code on 2026-10-25 (evening, MDT) after PR #95 and PR #94 were merged on the owner's instruction
---

> Verbatim record of the owner's final approval of the completed preregistration `EXP-20261021-l2-scratch-prereg` (as merged in PR #95, including the revised §10 preservation policy) and the authorisation to start the first L2 training run. The run `l2_scratch_768_color_s20261021` started 2026-10-26T01:17Z after the package digest was re-verified on the desktop. Reproduced as received; the heading is the owner's.

# BumpSetCut — Final L2 Preregistration Approval and Training Authorization

As project owner, I grant the following approvals.

**1. Final preregistration approval**

I give final approval of `EXP-20261021-l2-scratch-prereg` as merged in PR #95.

This includes explicit approval of the revised §10 preservation policy: if a protocol violation occurs, the experiment is invalidated, but the dataset package, journals, records, logs, checkpoints, and other evidence must be preserved until I separately authorize their disposition.

**2. L2 training authorization**

I explicitly authorize starting the first L2 training run using the approved preregistered configuration:

- Model: VballNetV4c, initialized from scratch.
- Input: nine RGB frames at 768×432.
- Epochs: 60.
- Batch size: 8.
- Seed: 20261021.
- Dataset: `Scratch-L2-multiframe-20261021-1917`.
- Package digest: `04e3551b1cf929658e39770bf1d368c8932234fdb895c03b050a13028fb375ca`.
- No pseudo-labels or unapproved augmentations.

Before launching, verify the package digest, environment, available GPU resources, and exact approved command. Abort if a required check fails.

Record my final approval, confirm the completed preflight in the Approval block, record the training start date, and update the experiment registry appropriately.

Run training through all 60 epochs unless an actual failure requires stopping. Preserve logs, metrics, intermediate checkpoints, and the best checkpoint.

Once training completes, report the development-validation results and prepare the preregistered paired comparison against L1.

All artifact fetches must use `--no-score` unless scoring is separately authorized.

**Still unauthorized:** a second training seed, protected-holdout evaluation, model promotion, iOS deployment, dataset modifications, and unrelated experiments.

Proceed with this approved first training run without requesting another start authorization.
