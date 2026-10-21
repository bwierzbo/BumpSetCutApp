---
name: model-lineages
status: authoritative
created: 2026-10-21T18:30:00Z
updated: 2026-10-21T18:30:00Z
decisions: D-016, D-017
---

# Model lineages

A **lineage** is a set of detector models that share a training-data boundary: every model in it was initialised and trained only from packages exported after the lineage's cut-over, with the same reserved recordings withheld. A claim like "this model never trained on recording X" is a claim about a lineage, verified from the exposure ledger (`manifests/exposure-log.json`) and the package manifests, never from memory.

Three things are kept apart (D-016 as amended by D-017):

1. **Historical exposure** of a recording during earlier development: permanent, never deleted or rewritten.
2. **Training exclusion** for a named lineage: the recordings withheld from that lineage's training, tuning, model selection and development-time scoring, from its cut-over on.
3. **Eligibility for the independent final test**: recordings with no recorded exposure at all. None of the lineage-holdout recordings is eligible; they are a protected, historically exposed evaluation set.

## L1 — everything up to the D-017 cut-over (historical)

| Field | Value |
|---|---|
| Members | every ball detector trained before 2026-10-21: `ball_v2_small` (YOLO, Ultralytics-derived), `bestv2/3`, the heat models `heat_20261009-*`, `r3_*`, `scratch_512/768/1024_*` (Oct 12–17), incl. the shipped `ball_heat` = `scratch_768_1014` (canonical digest `09620ab77519bd9d`) |
| Training data | Scratch packages up to `Scratch-multiframe-20261016-2018` (94 recordings exposed as `training_package`) |
| Model selection | `Scratch-val-multiframe-20261016-1100` (25 val sessions = the tuning set; not independent) |
| Relation to the lineage holdout | none of the 16 was in any L1 training package (all 16 were imported on 2026-10-17, after the last export). All 16 were **pre-tracked** on 2026-10-17/18 by an L1 heat model (which one is not recorded; the newest in the project at the time). So L1 models have *development exposure* to the 16 (machine tracks written from their output) but no training exposure. |
| Scores on the lineage holdout | **exposed, diagnostic-only**. Report them marked as such; never for selection or claims. |

## L2 — from-scratch lineage after the D-017 cut-over (planned, not started)

| Field | Value |
|---|---|
| Cut-over | 2026-10-21, PR `data/d017-lineage-holdout`: `pipeline_tuning/validation.json` gains `lineageHoldout` (16 names), sha256 `6d160a1ac00254a0` |
| Data manifest at the cut | project.json `65243bca59895a7e` · sessions `06ed23f06ccd23ce` · validation.json `6d160a1ac00254a0` (committed under [`manifests/Scratch/`](manifests/Scratch/)) |
| Withheld recordings | the 16 in `lineageHoldout` and anything that aliases them (same file, confirmed sourceId/sessionId/venueId), enforced by `ReservedVideos.reservedNames` in every package, score, tune, pre-track, ball-path and GUI path |
| Initialisation | from scratch (random init), no weights from any L1 model; no L1 model output (machine tracks, pseudo-labels, scores) in any input |
| Eligible training data | train split minus reservations: **133 recordings** (142 before the cut); packages must be exported after the cut (ledger date > cut-over) |
| Model selection | dev_val (4) + tune (9) as today; **not** the lineage holdout. To be preregistered. |
| Preregistration (required before any L2 holdout evaluation) | training recipe (data package name + hash, resolution, epochs, augmentation, seed), model-selection criterion and the validation set it uses, metrics and their definitions, the holdout evaluation procedure, and the number of holdout evaluations allowed (one per final candidate). Written to `docs/ml-roadmap/experiments/EXP-….md` and linked from the registry **before** the first look at holdout numbers. |
| Holdout evaluation | detector: on reviewed frames of the 16 once people have reviewed them (today: **0 reviewed frames** in all 16; the machine tracks are not ground truth). Pipeline: on rally marks of the seven candidates once marked (today: none). Report by surface (beach 6, grass 8, indoor 2) and by recording group (7 outings + 1 venue pair), with sample sizes and intervals. No repeated evaluations to pick models. |
| Exposure history of the members | `pre_tracking` 2026-10-17 (nine neighbours, two candidates) and 2026-10-18 (five candidates), ref "session tracks (machine)"; nothing else. Kept in the manifest permanently. |

## What the lineage holdout is not

It shares venues with nothing left in training only to the extent provenance is confirmed: 144 train/dev recordings (76 own files, 68 links) have neither a confirmed venue nor session, so their relation to the holdout is **unknown**, not cleared (audit finding `LINEAGE-UNKNOWN-RELATIONS`). Generalisation claims still need the planned new-footage final test at venues outside the eleven named on 2026-10-21.

## Adding a lineage

Record the cut-over commit and `validation.json` hash, the manifest hashes, the withheld set, initialisation, eligible data count, selection set, and the preregistration link. A lineage is closed when its last model is retired; its row stays.
