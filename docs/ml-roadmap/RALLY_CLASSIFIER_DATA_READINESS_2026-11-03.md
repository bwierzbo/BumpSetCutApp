---
name: rally-classifier-data-readiness
status: read-only audit of the Scratch project metadata, 2026-11-03; a dated report, superseded by a new file when re-run
created: 2026-11-03T18:50:00Z
updated: 2026-11-03T18:50:00Z
decision: D-001, D-002, D-010, D-016, D-017, D-021, D-023, D-024, D-031 (applied); D-029, D-030 (proposed, read for compatibility only)
---

# Rally classifier — training-data readiness, leakage and provenance audit (2026-11-03)

**Method.** A Python script (`scratchpad`, reproduced in §8) read `project.json`, `pipeline_tuning/validation.json`, `manifests/manifest.json`, `manifests/exposure-log.json`, every `sessions/*.json` and the `*.rallylabels.json` sidecars of the live Scratch project on the Mac. **No video file was opened, decoded or fingerprinted; nothing was written under the project.** For the 21 withheld recordings only the sidecar's existence and the session's declaration flag were read, never a rally time. The withheld closure was computed as the listed names expanded through the manifest's `aliasGroup`, which is the same closure `ReservedVideos.lineageWithheldNames` applies; it adds no alias (21 listed = 21 withheld, as the Phase 0 audit found).

| Input | SHA-256 |
|---|---|
| `project.json` | `1364ee92aa269f71851143d197bf40bc4adc0499bdbc8d0fa48449b7ad41e06d` (= the manifest's `projectJson`) |
| `pipeline_tuning/validation.json` | `6d160a1ac00254a088d8c80d8072ca8f70bc9d1913a1c22ff4cc85a4a23d1602` (= the D-017 cut-over hash) |
| `manifests/manifest.json` (written 2026-11-03T03:42:48Z) | `a963f072a72c47b2753fb4d861b29330ff257eb1097d71d4421ddd92791db1f6` |
| `manifests/exposure-log.json` (711 rows) | `4bece55c9cd98253a38d7285d0cdc840f9d73ea49ae3fb7d7ed54613ca07b33b` |
| `sessions/` (sha256 over the sorted `"<sha256>  ./<file>"` lines of the 167 files) | `0cb89dc7140d25c0b1104a7019cb70dece3354d96b82e040ad3f1d7897d80427` — **not** the manifest's `sessions` digest (`5eac4ee2…`): sessions changed after the manifest was written (marking continued on 2026-11-03), so the counts below are of the live state and a new manifest must be written before any export |

## 1. Inventory

| Fact | Count | Source |
|---|---|---|
| Sessions (recordings) | 167 | `sessions/` |
| Withheld (lineage holdout 16 + legacy holdout 5; aliases add none) | 21 | `validation.json`, manifest `aliasGroup` |
| Admitted (not withheld) | 146 | |
| **Declared complete** (`session.ralliesMarked == true`), admitted | **34** (was 30 at the Phase 0 audit of 2026-11-02; 4 marked since) | sessions |
| Declared complete, withheld | 3 (contents not read) | sessions |
| Admitted recordings with a rally-marks sidecar but no declaration | 2: `grs_gnd_shade_land_self_02_v2`, `grs_sid_sun_port_self_01_v2` (both on the edited-footage scan's clear list) | footage sidecars |
| **Stage 1 records** (`*.rallyevents.json`, verified coverage) | **0** | project folder |
| **Footage-properties records** (confirmed recording type, spans) | **0** (the folder does not exist) | `footage-properties/` |
| Cut ranges in any session | 0 (PR #135 unmerged; the sessions have no `cuts` key) | sessions |
| Marks in the 34 declared-complete recordings | **609**: 561 rally (128 of them with no `kind`, pre-live-tag legacy), 47 `missedServe`, 1 `other`; 476 marks carry `contacts` | sidecars |
| Rally time / declared non-rally time / duration (34 recordings) | 4,761 s / 5,439 s / 10,200 s (every recording is a 300 s cut) | sidecars, `project.json` lengths |
| Human-labeled ball-track rallies (admitted; a finished or confirmed track with ≥ 1 checked point) | 241 in 88 recordings (33 of the 34 declared-complete have ≥ 1) | sessions (the Phase 0 audit's rule; it counted 257 with `LineagePackage.isHumanLabeled`, which also admits a confirmed pre-tracked rally whose checked point is in another field — the difference does not matter here: ball tracks are not classifier labels) |
| Pre-tracked rallies nobody checked (admitted) | 284 in 43 recordings | sessions (D-023: never labels) |
| `notRallies` entries (start times of found rallies a person turned down at finish) | 20 entries in 9 of the 34 | sessions — start times only, no end: not usable as spans |
| Exposure rows, all kinds | training_package 347 · rally_scoring 182 · net_proposal 165 · ball_path 17 | ledger |

## 2. What each label kind is, and what it may be used for

| Label / state | What exists | Trust and use for the classifier |
|---|---|---|
| **Explicitly human-reviewed rally boundaries** (Stage 1, `rally_event_truth_v1`: frame-exact contact and dead instants with uncertainty, coverage, non-rally spans) | **none** (0 records; the 24-rally pilot not frozen, PR #102 held) | the only label class that supports boundary-error claims finer than the legacy marks' uncertainty; **not required** for the first activity-state experiment |
| **Legacy whole-video rally marks** (`<video>.rallylabels.json`: `{startTime, endTime, kind?, contacts?}`, live-tag presses backed up 0.25 s × speed and snapped ±0.4 s to ball-path changes, or arrow-stepped, or auto-from-track; no annotator, timestamp or uncertainty) | 609 marks in the 34 declared-complete recordings | **positive labels** (`ACTIVE_RALLY`) with provenance `legacy_declared`; starts are toss-or-contact ± snap, ends press-time ± snap (protocol §2): a boundary ignore band is mandatory; the 128 nil-kind marks are read as `rally` (contract §1) with provenance `legacy_nil_kind` and reported apart (owner decision D2 in the research document) |
| **Declaration "every rally marked"** (`session.ralliesMarked`) | 34 admitted | a *declaration*, valid development-label evidence (owner, 2026-11-03 §9); on its own it does **not** make the unmarked time a negative: under `TrainingEligibility` the negatives verdict is `not_assessed` until the recording's type is confirmed (`continuous` → `standard`; `edited` → `restricted`; `unknown` → `not_assessed`) |
| **Verified non-rally intervals** (Stage 1 `nonRallyActivity` spans; reviewed coverage with no rally) | none | would be the `NON_RALLY_ACTIVITY` hard negatives (D-010); none exist |
| **Missed serves, other** (`kind` marks) | 47 + 1 | `EXCLUDED` spans (scoring contract §1): never positives, never negatives; the product requires missed serves kept as events, so they stay in the dataset as excluded spans with their kind |
| **Human-reviewed ball trajectories** | 241 rallies | detector labels, not classifier labels; usable only as a *consistency check* that a rally mark and a checked track agree in time (not done here) |
| **Unreviewed tracker predictions, machine-proposed rallies** | 284 pre-tracked rallies | never labels (D-023); the 43 recordings keep them "for future rally-classification work" (D-023 §3) — as *inputs* once marked by a person, not as marks |
| **Unreviewed gaps** (time outside marks in recordings that are not declared complete, or inside declared-complete ones whose type is unconfirmed) | the 112 admitted unmarked recordings entirely; the 34's non-rally time until B1 | `UNKNOWN`, loss weight 0 |
| **Edited footage and cut ranges** | scan proposals for 13 recordings (3 among the 34: `bch_ele_sun_port_self_03` clear, `grs_ele_shade_land_self_02` clear, `grs_ele_dusk_port_self_03` borderline); no cut range, no confirmed span | `restricted` for the rally classifier (`TrainingEligibility.rule`: replay / slow motion excluded from temporal training; no window across a cut); until cuts or confirmations exist the three are **restricted and reported apart**, and their non-rally time is never a negative |
| **Protected and ineligible** | 21 withheld; 112 admitted-unmarked are simply unlabeled | withheld: never in any export (the validator refuses by name, source id and fingerprint); unmarked: not in the dataset |

**Phase 0 audit recheck.** The audit's "30 recordings declared completely marked, zero Stage 1 records" is now **34 and 0**. Nothing has changed in kind: a declaration of completion still establishes no trustworthy negative label by itself, and no recording's timeline coverage has been verified by a Stage 1 record.

## 3. The 34 declared-complete development recordings

By split: train 24 · dev_val 1 · tune 9. By surface: beach 12 · grass 11 · indoor 11. By camera (card field): endline elevated 17 · endline ground 7 · online (CC) 7 · handheld/corner 2 · tripod/corner 1. Orientation: landscape 29 · portrait 5. Origin: link 30 (YouTube or shared) · file 4. Confirmed `sourceId` 30 · confirmed `sessionId` **0** · confirmed `venueId` **0** (every one of the 34 is in D-017 §5's `LINEAGE-UNKNOWN-RELATIONS`: its relation to the lineage holdout is unknown, not cleared).

Rally lengths (561): 5th pct 2.3 s · median 6.4 s · 95th 20.7 s · min 0.5 s · 10 under 1.5 s · 36 under 2.6131 s. Gaps between consecutive rallies (527): median 6.1 s; **46 under 1.3513 s (the merge gap), 185 under 3.85 s (preroll + postroll + merge gap), 233 under 5 s**; one negative (overlapping marks, `ind_ele_dim_land_self_04`). Missed-serve marks last 1.2–4.9 s (median 2.1 s).

| recording | surface | split | camera | rallies | missed | other | nil-kind | rally s | declared non-rally s | gaps < 3.85 s | notRallies | flags |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bch_ele_ovc_land_self_02 | beach | train | endline elevated | 11 | 2 | 0 | 0 | 112.5 | 187.5 | 0 | 3 | |
| bch_ele_ovc_land_self_02_v2 | beach | train | endline elevated | 12 | 1 | 0 | 0 | 88.3 | 211.7 | 0 | 1 | |
| bch_ele_ovc_land_self_02_v3 | beach | train | endline elevated | 29 | 5 | 0 | 0 | 226.1 | 73.9 | 23 | 0 | |
| bch_ele_ovc_land_self_02_v4 | beach | train | endline elevated | 11 | 1 | 0 | 0 | 58.6 | 241.4 | 0 | 1 | |
| bch_ele_ovc_land_self_02_v5 | beach | train | endline elevated | 19 | 1 | 0 | 0 | 153.7 | 146.3 | 0 | 0 | |
| bch_ele_sun_land_self_01 | beach | train | endline elevated | 12 | 1 | 0 | 0 | 78.9 | 221.3 | 1 | 4 | |
| bch_ele_sun_port_self_03 | beach | dev_val | endline elevated | 13 | 0 | 0 | 0 | 156.2 | 143.8 | 0 | 3 | edited-scan: clear |
| bch_gnd_ovc_land_self_01 | beach | train | endline ground | 7 | 0 | 0 | 0 | 68.7 | 231.3 | 0 | 3 | |
| bch_gnd_ovc_land_self_01_v2 | beach | train | endline ground | 27 | 2 | 0 | 0 | 231.0 | 69.0 | 22 | 0 | |
| bch_onl_ovc_land_onl_02 | beach | tune | online | 18 | 0 | 0 | 18 | 224.9 | 75.2 | 5 | 0 | legacy nil kinds |
| bch_onl_ovc_land_onl_02_v2 | beach | tune | online | 22 | 0 | 0 | 22 | 214.9 | 85.2 | 11 | 0 | legacy nil kinds |
| bch_onl_ovc_land_onl_02_v4 | beach | tune | online | 14 | 0 | 0 | 14 | 233.3 | 66.7 | 4 | 0 | legacy nil kinds |
| grs_ele_dusk_port_self_03 | grass | train | endline elevated | 7 | 1 | 0 | 0 | 39.1 | 260.9 | 0 | 0 | edited-scan: borderline |
| grs_ele_dusk_port_self_03_v2 | grass | train | endline elevated | 28 | 8 | 0 | 0 | 164.0 | 136.0 | 13 | 1 | |
| grs_ele_shade_land_self_02 | grass | train | endline elevated | 33 | 0 | 0 | 0 | 222.7 | 77.3 | 27 | 0 | edited-scan: clear |
| grs_ele_sun_land_self_01 | grass | train | endline elevated | 8 | 0 | 0 | 0 | 70.6 | 229.4 | 0 | 0 | |
| grs_ele_sun_land_self_01_v2 | grass | train | endline elevated | 12 | 0 | 0 | 0 | 72.9 | 227.1 | 0 | 0 | |
| grs_ele_sun_land_self_01_v3 | grass | train | endline elevated | 12 | 0 | 0 | 0 | 56.7 | 243.3 | 0 | 0 | |
| grs_gnd_sun_land_self_01_v3 | grass | train | endline ground | 21 | 3 | 0 | 0 | 170.3 | 129.7 | 6 | 1 | |
| grs_hnd_shade_port_self_02 | grass | tune | handheld / corner | 12 | 0 | 0 | 12 | 139.7 | 160.4 | 0 | 0 | handheld, legacy nil kinds |
| grs_onl_shade_land_onl_02 | grass | tune | online | 11 | 0 | 0 | 11 | 175.3 | 124.7 | 0 | 0 | legacy nil kinds |
| grs_onl_sun_land_onl_01 | grass | tune | online | 11 | 0 | 0 | 11 | 118.1 | 181.9 | 0 | 0 | legacy nil kinds |
| grs_tri_sun_land_self_01 | grass | train | tripod / corner | 24 | 3 | 0 | 0 | 157.1 | 142.9 | 6 | 0 | |
| ind_ele_bright_land_self_01 | indoor | tune | endline elevated | 13 | 0 | 0 | 13 | 207.6 | 92.1 | 4 | 0 | legacy nil kinds |
| ind_ele_dim_land_self_02 | indoor | tune | endline elevated | 12 | 0 | 0 | 12 | 125.3 | 174.7 | 0 | 0 | legacy nil kinds |
| ind_ele_dim_land_self_02_v2 | indoor | tune | endline elevated | 15 | 0 | 0 | 15 | 134.9 | 165.2 | 0 | 0 | legacy nil kinds |
| ind_ele_dim_land_self_04 | indoor | train | endline elevated | 28 | 6 | 1 | 0 | 200.2 | 99.5 | 21 | 0 | one overlapping pair of marks |
| ind_gnd_bright_land_self_01 | indoor | train | endline ground | 12 | 1 | 0 | 0 | 94.4 | 205.6 | 0 | 0 | |
| ind_gnd_bright_land_self_01_v2 | indoor | train | endline ground | 9 | 0 | 0 | 0 | 51.1 | 249.0 | 0 | 0 | |
| ind_gnd_bright_land_self_01_v4 | indoor | train | endline ground | 23 | 5 | 0 | 0 | 150.7 | 149.3 | 7 | 0 | |
| ind_gnd_bright_port_self_03 | indoor | train | endline ground | 14 | 1 | 0 | 0 | 97.4 | 202.9 | 0 | 0 | |
| ind_hnd_dim_land_self_02 | indoor | train | handheld / corner | 37 | 0 | 0 | 0 | 238.9 | 61.1 | 35 | 0 | handheld |
| ind_onl_bright_land_onl_01_v2 | indoor | train | online | 11 | 5 | 0 | 0 | 98.6 | 201.4 | 0 | 2 | |
| ind_onl_bright_land_onl_01_v3 | indoor | train | online | 13 | 1 | 0 | 0 | 128.5 | 171.5 | 0 | 0 | |

"Declared non-rally s" is duration minus marked rally time: it is what the declaration *claims*; it becomes `NON_RALLY` label time only for a recording whose negatives verdict is `standard` (§2), which today is none.

## 4. Recording groups (the units of any split)

Groups are the transitive closure of: same clip card, same `aliasGroup` (shared file or confirmed `sourceId`), same uploader, same confirmed session or venue — the rule `DeciderRetune` applied (EXP-20261031 §3). With 0 confirmed sessions and venues among the 34, uploader and card carry the grouping; **two recordings from one match uploaded under different names by different uploaders would not be caught**, which is why the lineage holdout's unknown relations (D-017 §5) also apply here. The 18 groups:

| # | group (recordings) | surface | split | rallies | missed | nil-kind | flags | rally_scoring / training_package exposure |
|---|---|---|---|---|---|---|---|---|
| 1 | bch_ele_ovc_land_self_02, _v2, _v3, _v4, _v5 | beach | train | 82 | 10 | 0 | | 5/5 · 5/5 |
| 2 | bch_ele_sun_land_self_01 | beach | train | 12 | 1 | 0 | | 1/1 · 1/1 |
| 3 | bch_ele_sun_port_self_03 | beach | dev_val | 13 | 0 | 0 | edited-scan clear | 1/1 · 1/1 |
| 4 | bch_gnd_ovc_land_self_01, _v2 | beach | train | 34 | 2 | 0 | | 1/2 · 2/2 |
| 5 | bch_onl_ovc_land_onl_02, _v2, _v4 | beach | tune | 54 | 0 | 54 | | 3/3 · 3/3 |
| 6 | grs_ele_dusk_port_self_03, _v2 | grass | train | 35 | 9 | 0 | borderline | 1/2 · 2/2 |
| 7 | grs_ele_shade_land_self_02 | grass | train | 33 | 0 | 0 | edited-scan clear | 1/1 · 1/1 |
| 8 | grs_ele_sun_land_self_01, _v2, _v3 | grass | train | 32 | 0 | 0 | | 2/3 · 3/3 |
| 9 | grs_gnd_sun_land_self_01_v3 | grass | train | 21 | 3 | 0 | | 0/1 · 1/1 |
| 10 | grs_hnd_shade_port_self_02, grs_onl_shade_land_onl_02, grs_onl_sun_land_onl_01 (one uploader) | grass | tune | 34 | 0 | 34 | handheld | 3/3 · 3/3 |
| 11 | grs_tri_sun_land_self_01 | grass | train | 24 | 3 | 0 | | 0/1 · 1/1 |
| 12 | ind_ele_bright_land_self_01 | indoor | tune | 13 | 0 | 13 | | 1/1 · 1/1 |
| 13 | ind_ele_dim_land_self_02, _v2 | indoor | tune | 27 | 0 | 27 | | 2/2 · 2/2 |
| 14 | ind_ele_dim_land_self_04 | indoor | train | 28 | 6 | 0 | | 1/1 · 1/1 |
| 15 | ind_gnd_bright_land_self_01, _v2, _v4 | indoor | train | 44 | 6 | 0 | | 2/3 · 3/3 |
| 16 | ind_gnd_bright_port_self_03 | indoor | train | 14 | 1 | 0 | | 1/1 · 1/1 |
| 17 | ind_hnd_dim_land_self_02 | indoor | train | 37 | 0 | 0 | handheld | 0/1 · 1/1 |
| 18 | ind_onl_bright_land_onl_01_v2, _v3 | indoor | train | 24 | 6 | 0 | | 1/2 · 2/2 |

Per surface: beach 5 groups / 195 rallies · grass 6 / 179 · indoor 7 / 187. Group 1 alone holds 15 % of the rallies and group 5 holds 54 of the beach rallies with no kinds at all.

## 5. Leakage and exposure analysis

1. **Protected holdouts.** None of the 21 withheld recordings is in the candidate set; the audit read only their names, split and a flag. The seven lineage-holdout candidates have **no rally marks** (3 withheld sessions carry a declaration, their sidecars were not read), so there is nothing to evaluate a classifier on there even if the owner authorised it. Any future classifier evaluation on them follows D-017 §4: preregistered, once per named final candidate, never for selection.
2. **Detector-training exposure.** All 34 are in both detectors' training packages (`training_package` rows; the L2 package holds 88 recordings' human-labeled windows). The classifier's inputs are the detector's outputs on footage the detector trained on, so **in-rally detection density is optimistic** relative to unseen footage. This is a known limitation of every development number and the main reason an unexposed set is needed before adoption (research document B3).
3. **Decider-selection exposure.** 26 of the 34 (every recording in groups 1–3, 5–8, 10, 12–16, 18 in part) were scored by `--score-rallies` and used by EXP-20261031/EXP-20261101: the 9 tune recordings to **choose** decider settings, the other 17 to **judge** them (acceptance), and D-029 accepts a tradeoff on those 17. For the classifier experiment: the FSM baseline's committed settings were not chosen on these recordings (they date from 2026-06-14 / 2026-10-11 tuning on the earlier tune/holdout lists, which overlap group 5, 10, 12, 13 — the `tune` split), the D-029 settings were. Consequently the **FSM at committed settings is the fair benchmark on grouped folds**; the D-029 row is reported as a reference with its exposure stated; and no fold of this experiment is "independent final evidence".
4. **Development-tuning exposure within the experiment.** Calibration, hysteresis thresholds and model selection are chosen on out-of-fold predictions across the 18 groups; every number is a cross-validated development number. Repeating the experiment with a different design later does not make these 34 recordings unseen: the preregistration records that this set is now **classifier development data** and any later classifier must treat it as such.
5. **Edited footage inside the 34.** Three recordings (groups 3, 6, 7) carry scan proposals of replays or zooms; the dev_val recording is one of them. Their rally marks were made over the edited timeline, so a replayed rally may be marked twice and its timing is not live-play timing. They are `restricted`, kept in training folds only with their non-rally time `UNKNOWN`, and never alone in a validation fold.
6. **Label timing on proxies.** Legacy marks were made in RallyLab over the original or a 960 px scrub proxy; proxies are not frame-exact ([STAGE1_RALLY_BOUNDARIES_PLAN.md §3](STAGE1_RALLY_BOUNDARIES_PLAN.md)) and variable-frame-rate iPhone footage keeps its irregular presentation times only in the original ([IPHONE_COPY_FRAME_IDENTITY_2026-10-26.md](IPHONE_COPY_FRAME_IDENTITY_2026-10-26.md)), so a mark's seconds may be offset against the original's timeline on VFR recordings. Stage 1 refuses commits on a proxy for this reason. The contract therefore stores label ticks exactly as the marks say and the ignore band absorbs the offset; the exporter records whether the recording is VFR (`frameTimesDigest` and the frame-time spread from `FrameIdentity`) so the sensitivity can be measured later.
7. **Unknown relations.** 0 confirmed sessions or venues among the 34; the groups rest on cards, aliases and uploaders. Two of the online groups (5 and 10) are single-uploader channels that may contain several venues or one venue across groups — the grouping cannot tell. This is reported, not resolved; a visual provenance review (the D-016 procedure) is the only way to confirm, and it is the owner's.

## 6. Proposed grouped dataset protocol

- **Unit:** the recording group of §4, frozen in the dataset manifest with the split-manifest hashes at export time (a new manifest is written first, §0).
- **Development evaluation:** 6 folds, each a set of whole groups, assigned by a seeded draw stratified so that every fold holds at least one beach, one grass and one indoor group and the rally counts per fold are within ±25 % of each other (18 groups over 6 folds = 3 per fold; the draw and seed are in the preregistration). Every recording in a fold is scored by a model trained on the other five folds; thresholds and calibration are fitted on the out-of-fold predictions of the *training* folds only (nested: the scoring fold's predictions never pick its own threshold). Restricted recordings (handheld, scanner-flagged) are allowed in training folds and are scored in their own fold but reported apart and excluded from the headline per-surface numbers when they would be the only recording of that surface in the fold.
- **No held-out set.** There is none that is both marked and unexposed. The experiment reports development evidence only; the preregistration's decision rule is written for that.
- **Reporting:** per fold, per surface, per group and pooled, with paired group-bootstrap 90 % intervals (1,000 draws, seed 0, groups as units, the `paired_compare.py` convention) for every model-vs-FSM difference. A difference whose interval includes zero is reported as not told apart, never as equivalence.
- **Future independent test:** the seven lineage-holdout candidates once marked (owner-gated, one evaluation per named candidate) and the planned new-footage final test. Neither is part of this experiment.

## 7. Readiness verdict

| Requirement | State | Blocks the first experiment? |
|---|---|---|
| Positive labels (rally intervals) in development recordings | 561 rallies, 34 recordings, 18 groups | no |
| Negative labels (verified non-rally time) | **0 s** — every recording `not_assessed` until its type is confirmed (B1) | **yes** |
| Excluded spans (missed serves, other) | 48, carried as excluded | no |
| Non-rally ball-activity spans (hard negatives) | 0 (Stage 1) | no (reported as a limitation) |
| Cut ranges / confirmed continuous for the 3 scanner-flagged recordings | none | no for the experiment (they stay restricted); yes for using their negatives |
| Frame-exact boundaries (Stage 1) | 0 | no for activity state; yes for boundary claims below ~0.5 s |
| A dataset export of the contract's shape | no exporter | **yes** (B4) |
| Group integrity | 18 groups by card/alias/uploader; 0 confirmed venues | no, with the unknown-relations caveat |
| Independent final test | none | not for a development experiment; yes for production adoption |

**Conclusion.** The corpus supports a credible *grouped development* experiment once the owner confirms the recording type of the 34 declared-complete recordings (turning their declared non-rally time into labels) and an exporter writes the contract. It does not support an independent claim; the preregistration says so.

## 8. Reproduction

The audit script is in the PR's scratch record (`readiness_audit.py`, 120 lines, standard library) and will become `RallyLab --rally-classifier-readiness` only if the owner wants it as a command; it reads the files named in §0, never a video, and prints the tables above. Re-running it after the owner's labeling writes a new dated file beside this one; this file is not edited.
