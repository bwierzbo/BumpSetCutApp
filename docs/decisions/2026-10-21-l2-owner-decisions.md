---
name: l2-owner-decisions
status: accepted
created: 2026-10-21T20:19:11Z
updated: 2026-10-21T20:19:11Z
source: owner, reviewed with ChatGPT, delivered to Claude Code on 2026-10-21
---

> Verbatim record of the owner's two remaining L2 decisions after [D-017](DECISION_LOG.md#d-017). The normalised entry is [D-018](DECISION_LOG.md#d-018). This file is the primary source; do not edit it.

# BumpSetCut — Remaining L2 Owner Decisions

I've reviewed the two remaining decisions with ChatGPT.

## Decision 1 — L2 dataset isolation

Approve physical isolation through a manifest-generated L2 dataset.

Do not rely exclusively on name-based exclusions or a policy saying the existing data.yaml should not be used.

Generate a separate training dataset with its own data.yaml, using the authoritative versioned split manifest.

Requirements:

* Exclude all 16 protected recordings from L2 training, validation and tuning.
* Ensure the nine previously trained recordings and their frames are physically absent from the L2 training export.
* Preserve all original datasets, labels and historical artifacts.
* Add a preflight audit verifying source identities, file hashes, split membership and exclusion closure.
* Fail closed if any protected recording or related frame is discovered.
* Explicitly mark the original data.yaml as unsupported for L2 training.
* Store the generated dataset manifest and hashes with the experiment record.

Do not execute training yet.

## Decision 2 — L2 preregistration

Approve the requirement for mandatory preregistration before any L2 training.

Create a reusable L2 preregistration template covering:

1. Research objective and hypotheses.
2. Dataset versions, sample counts, provenance and hashes.
3. Model architecture and initialization.
4. Training hyperparameters, random seeds, augmentations and stopping criteria.
5. Development-validation and checkpoint-selection rules.
6. Detector and end-to-end rally evaluation metrics.
7. Surface-specific reporting and uncertainty.
8. Protected-holdout access and evaluation rules.
9. Reproducibility information, including hardware, code revision and dependencies.
10. Success criteria, failure criteria and limitations.

No protected-holdout results may be used for model selection or hyperparameter tuning.

The L2 model must use independently initialized weights, not checkpoints derived from the existing exposed detector, if it is to be described as trained from scratch.

Prepare the template and proposed L2 training configuration for my review.

Do not begin training until I explicitly approve the completed preregistration and the dataset preflight passes.

Continue the previously agreed evaluation-integrity work in sequence.

Follow the established PR and Codex review workflow. Stop at the next owner approval gate.
