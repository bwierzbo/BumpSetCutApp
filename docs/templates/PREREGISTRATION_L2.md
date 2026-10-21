# Lineage preregistration template (D-017 §4, D-018 §2)

One file per lineage training run at `docs/ml-roadmap/experiments/EXP-YYYYMMDD-<slug>.md`, plus a row in [`EXPERIMENT_REGISTRY.md`](../ml-roadmap/EXPERIMENT_REGISTRY.md). It is written **before** the package is sent to the trainer and **approved by the owner before** training starts; the protected holdout is not looked at until every section below is filled and the dataset preflight has passed. A field that is not known is written `not fixed` and the record is not approvable until it is. Never write `0` for a number that was not measured.

Rules the record must satisfy (they are checked at review, not assumed):

- The training package is one written by `RallyLab --project <name> --package-l2` whose `l2-manifest.json` preflight **passed**; its digest and the plan's manifest hashes are copied here. The project's `data.yaml` dataset is not an input.
- Initialisation is **independent**: random init, or weights that never saw a withheld recording (named, with their own lineage). A checkpoint of any L1 model (every detector trained before 2026-10-21, including the shipped `ball_heat`) is not an allowed initialisation for a model described as trained from scratch.
- Model selection, early stopping, hyperparameter choice and any comparison between runs use **dev_val + tune only**. No number from the protected holdout (`lineage_holdout`) enters any of those decisions, and the holdout is evaluated **once per final candidate**, by the procedure written in §8, after the candidate is named in writing.
- Results are reported per surface and per recording group with sample sizes and intervals; a claim the sample cannot support is written as such.

```markdown
---
id: EXP-YYYYMMDD-slug
lineage: L2
status: proposed | approved | running | done | abandoned
created: YYYY-MM-DDTHH:MM:SSZ
updated: YYYY-MM-DDTHH:MM:SSZ
approved_by: <owner, date> | not yet
decision: D-017, D-018
pr: <#n or n/a>
---

# EXP-YYYYMMDD-slug — <title>

## 1. Objective and hypotheses
<What question this run answers. Each hypothesis as control → treatment → expected effect → metric → the
sample that can show it. State what result would make the hypothesis false.>

## 2. Data
| Field | Value |
|---|---|
| Split manifest hashes (project.json / sessions / validation.json) | |
| Lineage plan (manifests/l2/<stamp>-plan.json SHA-256) | |
| Package name | |
| Package digest (l2-manifest.json `preflight.digest`) · windows.jsonl SHA-256 | |
| Preflight | passed on <date>, <n> checks (copy the check table) |
| Train recordings / windows (labeled, dead) | |
| Val recordings / windows (dev_val, tune) | |
| Withheld recordings (lineage_holdout, legacy_holdout, final test, candidates) | |
| Provenance summary | venues/sessions confirmed vs unknown among train and val; soft audit findings carried |
| Label sets | ball_track_truth_vN (tracks), rally_event_truth_vN (marks) |
| Exposure ledger rows this run adds | training_package <package name> |

## 3. Model and initialisation
<Architecture, input (frames, colour/grey, size), output heads, parameter count. Initialisation: random
(seed) | named weights with their lineage. Code revision of the trainer and of the model source.>

## 4. Training
| Field | Value |
|---|---|
| Trainer command, exactly | |
| Epochs · batch · learning rate · optimiser · schedule | |
| Augmentations (each flag and what it does) | |
| Random seed(s) | |
| Stopping criterion | |
| Mixed precision / determinism settings | |

## 5. Development validation and checkpoint selection
<The val set (dev_val + tune by name), the metric that picks the checkpoint and its exact definition, how
often it is computed, tie rules, and the rule for comparing two runs (e.g. 90 % intervals from resampling
val videos must not overlap). No holdout number is used here.>

## 6. Metrics
<Detector: hit definition (px at 512 width), precision/recall/F1 on balls in play, resting-ball recall,
occluded handling, dead-time fire rate. End-to-end rally: boundary error (start/end MAE, raw vs padded),
complete-rally recall, false rallies, dead time, from which scorer and config hash. Each with its sample.>

## 7. Reporting by surface and uncertainty
<Tables per surface (beach / grass / indoor) and per recording group; interval method and width; the
minimum sample below which a number is reported as "indicative only".>

## 8. Protected-holdout access and evaluation
<Which recordings (by name) and which of their annotations exist and are trustworthy at the time of
writing; who runs the evaluation, with which command, on which candidate(s) — named before running; the
number of evaluations allowed (one per final candidate); what is reported (per surface / group) and what
is never done (selection, tuning, repeated looks). How the exposure ledger row is written.>

## 9. Reproducibility
| Field | Value |
|---|---|
| Code SHA (repo) · trainer script SHA-256 · model source commit | |
| Hardware (machine, GPU, driver) · OS | |
| Python · torch · CUDA · opencv · numpy · onnx · coremltools versions | |
| Package transfer and verification (digest re-checked on the training machine) | |
| Run folder and artefact hashes (best.pt, best.onnx, metrics.json, .mlpackage canonical digest) | |

## 10. Success, failure and limitations
<Success criteria (numbers on dev_val/tune that would make the run a candidate); failure criteria (what
stops the lineage or sends it back to data); known limitations (unknown provenance relations, sample sizes,
what the holdout cannot show, what the planned new-footage final test is still needed for).>

## Approval
- [ ] Owner approved this preregistration on <date> (quote the authorisation).
- [ ] Dataset preflight passed (package name, digest).
- [ ] Training started on <date>; holdout not yet evaluated.
```
