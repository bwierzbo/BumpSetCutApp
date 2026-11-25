---
name: l2-tradeoff-and-net-investigation-direction
status: accepted
created: 2026-11-02T20:10:25Z
updated: 2026-11-02T20:10:25Z
source: owner, delivered to Claude Code on 2026-11-02 (midday, MST), after PR #130 and the r2 decider retune report
---

> Verbatim record of the owner's direction, reproduced as received (one message). In summary:
> - §1 is a decision: the L2 decider's rally-cutting tradeoff (EXP-20261031-l2-decider-retune / -r2 evaluation figures) is accepted **temporarily as a product decision**, explicitly **not** as meeting the preregistered acceptance criteria; historical results stay as written; the learned temporal rally classifier is the intended next research direction, not a guaranteed solution; #110 is not merged, production defaults are not changed and nothing is deployed without separate approval. Logged as [D-029](DECISION_LOG.md#d-029).
> - §2–§7 commission a metadata-only investigation (no training, no downloads, no new dataset versions, no annotation changes, no holdout access): the June Ultralytics net detector's provenance, a Roboflow net-annotation audit, the data/model diagnosis of the from-scratch net model, a review of the v1/v2 net work, one recommended next experiment and the list of owner decisions. The report is [NET_DETECTOR_PROVENANCE_AND_DATA_AUDIT_2026-11-02.md](../ml-roadmap/NET_DETECTOR_PROVENANCE_AND_DATA_AUDIT_2026-11-02.md).

BumpSetCut — L2 Decision and Net Detector Dataset Investigation

Continue development in bwierzbo/BumpSetCutApp. Read AGENTS.md, CLAUDE.md, the working agreement, decision log, ML roadmap, experiment registry, and relevant open PRs before proceeding.

1. Owner decision — L2 rally cutting

I accept the current L2 decider performance tradeoff as a temporary product decision.

Known evaluation results:

* Preserved rallies: 137 vs. 127 with L1.
* Merged rallies: 150 vs. 159 with L1.
* False clips: 48, exceeding the acceptance bar of 31.
* Retained dead time: 4.43 seconds per rally, exceeding the 4.19-second bar.

We are accepting these shortcomings temporarily, with the intention of improving rally segmentation through a learned temporal rally classifier.

Important:

* Record this as an explicit owner-accepted performance tradeoff, not as passing the original acceptance criteria.
* Do not alter or erase historical experiment results.
* Prepare the appropriate decision documentation and assess what this changes about PR #110.
* Do not merge #110, change production defaults, or deploy anything without separate approval.
* The rally classifier is our intended next research direction, not a guaranteed solution.

2. Investigate the original Ultralytics net detector

The previous net.mlpackage was trained using Ultralytics YOLO26n on approximately June 19, 2026.

I suspect the original training data may have included Roboflow datasets that we are not currently using.

Investigate its original training provenance as thoroughly as possible.

Find:

* Original training scripts and configurations.
* Training datasets and Roboflow project/version identifiers.
* Original image and annotation counts.
* Dataset class mappings and preprocessing.
* Any available training logs, checkpoints, metadata, or local exports.

Check the repository, existing experiment records, and authorized local training directories.

Do not assume the old and new models used identical training data unless the evidence establishes that.

3. Audit all Roboflow datasets for net annotations

Use the existing Roboflow connection or authorized API credentials. Do not expose credentials.

Inspect every accessible project and relevant dataset version in my BumpSetCut workspace, including private projects where access is available.

Pay particular attention to:

* bumpsetcut/volleyball-ykkmn-grgwy
* bumpsetcut/bumpsetcutmore
* Volleyball01, Volleyball02, Volleyball03
* BumpSetCut and BumpSetCut RallyLab
* Avais Beach Volleyball (avais-beach-volleyball/beach-volleyball-tt2vj)
* tfginfo-gtd2c/volleyball_net
* volleyball-training-data/volleyball-mixed-annotation

Also inspect the external datasets referenced in scripts/desktop_training/get_extra_datasets.py.

For each dataset/version, report:

1. Project name, URL, version, and license.
2. Total original images versus augmented images.
3. All annotation classes.
4. Number of images containing net annotations.
5. Number of net annotations.
6. Whether the annotation represents the full net, net tape, antenna, or something else.
7. Camera and court environments represented.
8. Whether its images are potentially duplicated in another dataset.
9. Whether the dataset can legally and technically be used in our proposed training process.

Distinguish confirmed counts from estimates.

Do not treat an antenna annotation as a full net annotation.

4. Evaluate additional data and model requirements

Our new from-scratch net model has underperformed the geometric acceptance thresholds.

Determine whether the primary issue appears to be:

* Insufficient training data.
* Inaccurate or inconsistent net annotations.
* Limited camera-angle diversity.
* Training resolution.
* Model architecture.
* Bounding-box versus four-corner prediction.
* Inappropriate augmentation.
* Some combination of the above.

Compare the original Ultralytics net detector against the new model conceptually and, if existing artifacts allow, quantitatively.

Use the same reviewed frames and comparable metrics. Clearly distinguish historical results from a new comparison.

Remember that our replacement must remain free of Ultralytics-derived code and weights in the public iOS application.

Important: Standard Roboflow bounding boxes do not provide ground-truth coordinates for the four corners of the net. Explain how that affects training and whether a separate bounding-box detector or a hybrid approach would make more sense.

5. Protect existing research integrity

Preserve:

* All existing datasets and annotations.
* Current split definitions and provenance records.
* The protected holdout and its aliases.
* Exposure history and experiment records.
* Frozen checkpoints and experiment configurations.

Do not inspect, expose, train on, tune against, or evaluate the protected holdout.

Identify potential data leakage before proposing any dataset merge.

Do not retrain a model, download or modify datasets, create new dataset versions, or alter existing annotations without explicit approval. Metadata-only investigation is authorized.

6. Review current net-model work

Check the actual current status of:

* PR #128 — net-model-v1 results.
* PR #129 — net-model-v2 recipe.
* Any subsequent branches or training runs.

Determine whether the currently approved v2 experiment already addresses the most likely weaknesses.

Avoid proposing a redundant training run if one is already underway or has completed.

Do not modify another Claude instance's active worktree or branch.

7. Deliverables

Provide a concise but technically rigorous report containing:

A. Original detector provenance

What actually trained the June Ultralytics net model? Which parts remain unknown?

B. Roboflow dataset inventory

A complete table of accessible datasets, versions, annotation counts, and suitability.

C. Additional training data

Which new net annotations are genuinely useful, and how much usable data would they contribute?

D. Model comparison

Why might the old detector appear more effective than our new architecture? Separate demonstrated findings from hypotheses.

E. Recommended next experiment

Provide one preferred experiment design, including data selection, model approach, comparison baseline, evaluation metrics, leakage controls, and acceptance criteria.

F. Owner decisions required

List only the decisions requiring my approval, with your recommendation for each.

Do not implement or train anything yet. Complete the investigation, clearly identify evidence gaps, and stop at the owner approval gate.

Follow the existing BumpSetCut configuration-management and independent-review procedures throughout.
