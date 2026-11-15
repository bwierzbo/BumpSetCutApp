---
id: EXP-20261103-temporal-rally-classifier-prereg
status: proposed — not approved, not run; the dataset is exported and validated (`rc-v1-20261112`), the folds are drawn and frozen, the trainer is written (PR #178) and its dry run passes; what the owner still has to decide is in §11 (updated 2026-11-13)
created: 2026-11-03T19:05:00Z
updated: 2026-11-13T08:44:57Z
approved_by: not yet
decision: D-001 (approved production candidate), D-007 (objective), D-021 (scoring contract), D-010, D-017, D-018 (preregistration before training, applied to this model), D-031 (eligibility); D-029 (proposed, PR #132) names this direction
roadmap_phase: Phase 8 (learned temporal classifier vs FSM; no longer approval-gated, D-001), after the measurement phases
pr: research/temporal-rally-classifier (this record); the exporter and any training are later PRs
issue: n/a
---

# EXP-20261103-temporal-rally-classifier-prereg — the first learned rally-activity classifier against the deterministic FSM (development evidence)

**Status: proposed.** Written before any dataset exists. Every field marked `not fixed` is filled by the exporter's output and this record is not approvable until none remains. Numbers that were not measured are written `not measured`. The method and reasoning are in [TEMPORAL_RALLY_CLASSIFIER_RESEARCH_2026-11-03.md](../TEMPORAL_RALLY_CLASSIFIER_RESEARCH_2026-11-03.md); the data in [RALLY_CLASSIFIER_DATA_READINESS_2026-11-03.md](../RALLY_CLASSIFIER_DATA_READINESS_2026-11-03.md); the dataset shape in [RALLY_CLASSIFIER_DATASET_CONTRACT.md](../RALLY_CLASSIFIER_DATASET_CONTRACT.md).

## 1. Objective and hypotheses

**Question.** On the same cached detector evidence, does a small learned per-step rally-activity model, decoded by a fixed post-processing contract, deliver more complete rallies with no more false clips and no more dead time than the committed deterministic decider, across recording groups it never saw?

**H1 (primary, R1 vs R0).** Regularised logistic regression over causal and bounded-look-ahead window features of the gate/tracker signals (R1), decoded by the fixed contract (§5 of the research document), achieves on the out-of-fold recordings of five grouped folds **complete-rally recall ≥ R0's** (the FSM at the committed settings, same folds, same evidence) **with dead-time retention ≤ R0's and false clips ≤ R0's**, pooled over the folds. Each clause is an acceptance criterion; the paired group-bootstrap 90 % interval of each difference (R1 − R0) is reported; H1 holds when every clause's point estimate meets its bar and no interval lies on the wrong side of zero. An interval that includes zero is reported as "not told apart", never as equivalence.

**H2 (capacity step, R2 vs R1).** The small non-causal TCN (R2) achieves a higher pooled complete-rally recall than R1 at dead-time retention and false clips no worse than R1's, with the paired 90 % interval of the recall difference above zero. If H2 fails, R1 is the only learned candidate carried forward.

**H3 (exploratory, no bar).** Raw start and end boundary errors (signed medians, MAE, within-1-s fraction) of R1 and R2 against R0, per surface; the net-ablated condition of each model against its full condition; the restricted recordings against the standard ones. Reported, not judged — the legacy marks' own uncertainty bounds what these numbers can show.

**What would make H1 false.** R1 preserving fewer rallies than R0, or buying recall with more false clips or more dead time, on the pooled out-of-fold recordings.

**Not claimed.** Generalisation to unseen venues, cameras or recording conditions. Every recording here is in both detectors' training packages and 26 of the 34 carry decider-selection or acceptance exposure (readiness §5). This is **development evidence** under D-001; production adoption needs a later evaluation on recordings with no exposure (§8).

## 2. Data

| Field | Value |
|---|---|
| Split manifest hashes (project.json / sessions / validation.json / manifest.json) | `not fixed` — a new manifest is written by `--audit-dataset` immediately before the export (the live sessions already differ from the 2026-11-03T03:42Z manifest) |
| Dataset name · manifest SHA-256 · digest | `not fixed` (written by the exporter; `rally_classifier_dataset_v1`) |
| Validator | `scripts/rally_classifier/validate_dataset.py <dataset> --withheld <closure.json>` must report 0 errors; the report is pasted here |
| Detector whose evidence the steps hold | `ball_heat` = L1 `scratch_768_1014`, canonical digest `09620ab77519bd9d` (what `main` ships); L2 (`8cb1bbca0c2729a8`) only as a second dataset if the owner asks (research document B5) |
| Pipeline config | `ProcessorConfig()` as committed on `main` at the export commit, `heatmapOnly`, camera position per recording (`withCamera(of:)`), rotation not applied; SHA-256 `not fixed` |
| Candidate recordings (at 2026-11-03) | the 34 declared-complete admitted recordings of the readiness audit §3, 561 truth rallies, 47 missed serves + 1 other as excluded spans; final list `not fixed` until the gate (§2a) is passed, since B1 may remove recordings the owner cannot confirm |
| Recording groups and folds | 18 groups (readiness §4) → **5 folds** of 3–4 groups (the beach side has 5 groups, so 5 is the largest fold count under which every fold can hold one group of each surface without reusing a group — Codex finding on PR #136). Procedure: the groups sorted by their first recording's name, shuffled with `random.Random(20261103)`, dealt per surface round-robin into the 5 folds, re-shuffled until every fold holds a beach, a grass and an indoor group and no fold's rally count is outside ±25 % of the mean; the draw is written into the dataset manifest (`fold` per recording). **Feasibility demonstrated on today's 18 groups** (the 39th shuffle; the final draw is made on the gated candidate list and listed here when made): fold 0 — ind_gnd_bright_land_self_01, ind_ele_dim_land_self_04, grs_ele_sun_land_self_01, grs_gnd_sun_land_self_01_v3, bch_ele_sun_land_self_01 (137 rallies); fold 1 — ind_ele_bright_land_self_01, ind_onl_bright_land_onl_01_v2, grs_ele_dusk_port_self_03, bch_ele_sun_port_self_03 (85); fold 2 — ind_ele_dim_land_self_02, grs_hnd_shade_port_self_02, bch_gnd_ovc_land_self_01 (95); fold 3 — ind_hnd_dim_land_self_02, grs_ele_shade_land_self_02, bch_onl_ovc_land_onl_02 (124); fold 4 — ind_gnd_bright_port_self_03, grs_tri_sun_land_self_01, bch_ele_ovc_land_self_02 (120); groups named by their first recording, mean 112.2 rallies per fold |
| Restricted recordings | handheld (`grs_hnd_shade_port_self_02`, `ind_hnd_dim_land_self_02`) and scanner-flagged (`bch_ele_sun_port_self_03`, `grs_ele_shade_land_self_02`, `grs_ele_dusk_port_self_03`) enter with `restrictedUse: true`: trained on, scored in their fold, reported apart, excluded from the headline per-surface tables when they would be the only recording of a surface in a fold; their non-rally time is `UNKNOWN` unless the owner confirms the recording continuous |
| Withheld | the full closure at export (21 today: 16 lineage holdout, 5 legacy holdout, aliases) carried in the manifest; the validator refuses any presence by name, source id or fingerprint; **no withheld recording is read, decoded or scored** |
| Label sets | `rally_activity_truth_v1` from the legacy marks (`legacy_declared`; the 128 nil-kind marks as `legacy_nil_kind`); `boundaryIgnoreSec` 0.5 (owner decision D1); Stage 1 records used when they exist at export (today 0) |
| Negatives | only steps of recordings whose `fullVideoNegatives` verdict is `standard` and whose coverage is complete (contract §5): **0 recordings today**; see §2a |
| Exposure ledger rows this experiment adds | one `training_package` row per packaged recording (ref `--export-rally-classifier-dataset <name>`), written by the exporter after validation |

### 2a. Data-readiness gate (all must hold before the dataset is exported; the owner confirms each)

| Gate | Condition | State 2026-11-03 |
|---|---|---|
| G1 | A confirmed `recordingType` (footage-properties record) for every candidate recording; `continuous` recordings supply negatives, `edited` ones supply positives only | **not met** (0 records) |
| G2 | The three scanner-flagged recordings either carry cut ranges (D-030, PR #135 on `main`) or are confirmed `continuous`; otherwise they stay restricted with no negatives | not met |
| G3 | An exporter that writes `rally_classifier_dataset_v1` from the split manifest, the withheld closure, eligibility and the marks, and records the ledger row (a reviewed RallyLab PR) | not met (no exporter) |
| G4 | A fresh split manifest and audit (0 hard findings) at the export commit | re-run at export |
| G5 | The validator reports 0 errors on the written dataset, with the external closure file | at export |
| G6 | At least 12 of the 18 groups contribute negatives (otherwise the negative class is too thin for grouped folds) — a count, not a target; below it the experiment is *need data* before it starts | `not fixed` |

## 3. Models and initialisation

| Candidate | Definition | Initialisation / determinism |
|---|---|---|
| **R0** | `RallyDecider` + `SegmentBuilder` at the committed `ProcessorConfig` (preroll 2.0, postroll 0.5, join 1.3513, min 2.6131, serve-primed start on), replayed **by the exporter at export time** with `EvidenceReplayer.decidedRallies` on the full `FrameEvidence` (parity with the pipeline within 0.2 s, EXP-20261031 §7) and stored as the dataset's `baseline/<recordingId>.json` variant `r0` with the config hash (contract §3a). `rcf_v1` does not hold the detection boxes `ServeWatch` reruns on nor a serve's toss/end that `noteServe` backdates with, so the FSM is never re-run by the trainer: the benchmark is the stored output (Codex round 2 on PR #136) | deterministic |
| **R0'** (reference only) | R0 with the D-029 settings (join 0, postroll 1.0, preroll 2.0, min 1.5), stored the same way as variant `r0_prime` with its own config hash | deterministic; reported with its selection exposure stated; never the benchmark |
| **R1** | logistic regression, L2 penalty, class-balanced, over `derived_v1` features (trailing 1 s and 3 s windows, forward 2 s windows, serve coverage from serves emitted within the bound, `lookaheadSec` 2.0) of `rcf_v1` (18 causal raw columns); standardisation from the training folds' weighted steps | full-batch gradient descent, deterministic; penalty chosen from {1e-4, 1e-3, 1e-2} by nested CV on the training folds |
| **R2** | non-causal TCN: linear 18→32 (+ the `cell_missing` indicator → 19 inputs), five residual blocks (1-D conv kernel 5, dilations 1, 2, 4, 8, 16, 32 channels, GELU, dropout 0.1), 1×1 head → logit; input is the **30 Hz uniform-grid view** of each segment (contract §4.4, `grid_v1`), so the receptive field of 125 cells is ±2.07 s **of time** regardless of the processed-frame spacing and lies under the declared `lookaheadSec` 2.1 (Codex round 2 on PR #136); trained on 600-cell windows (20 s) with 300-cell hop, scored with the same windows and ±63-cell margins so every cell is scored once with full context; a raw step takes its cell's prediction; ≈ 27 k parameters | PyTorch, random init with seed 20261103, **one seed** (a second needs separate approval); AdamW 1e-3, weight decay 1e-2, 40 epochs, batch 16 windows, weighted BCE with the contract's `w`, early stopping on the nested validation fold's loss |
| R3 (ablation only) | bidirectional GRU, hidden 32 | run only if H2 fails, same seed, reported as an ablation |

Net features: each of R1 and R2 is trained and scored twice, with `y_above_net` present and with it null everywhere (the ablation of H3); the **net-ablated** model is the candidate carried forward unless the owner decides the net dependency is acceptable.

## 4. Training

| Field | Value |
|---|---|
| Trainer command, exactly | `not fixed` — `scripts/rally_classifier/train.py <dataset> --candidate {r1,r2,r3} --folds 5 --seed 20261103 --net {present,ablated} --out <run>` (the trainer is written after this record is approved; its SHA-256 goes here) |
| Augmentation | R2 only: correlated detection dropout (contiguous runs of 0.1–0.5 s with `has_ball`, `max_conf`, `sel_*`, `r2`, `grav` nulled and `n_*` zeroed, probability 0.1 per window), confidence jitter ±0.05, time-stretch not applied (labels are ticks) — roadmap Phase 8 step 4 |
| Loss | weighted binary cross-entropy over steps with `w = 1`; `TRANSITION`, `UNKNOWN`, `EXCLUDED` contribute nothing; `NON_RALLY_ACTIVITY` is a negative |
| Seeds | 20261103 (R2, R3); R1 deterministic |
| Determinism | PyTorch deterministic algorithms on CPU (the models are small enough); the Mac; versions in §9 |
| Stopping | R2: epoch with the lowest nested-validation loss, maximum 40 |

## 5. Development validation and selection rule (fixed before any result)

- **Folds.** Five grouped folds (§2). For each fold *k*: train on the other four; inside those four, one nested fold (the same draw rotated) picks the penalty (R1), the stopping epoch (R2) and the **calibration and decode parameters**; the model is then refit on all four and scores fold *k*. Fold *k*'s recordings never influence any choice made for them.
- **Calibration.** Temperature scaling (one scalar) on the nested fold's steps with `w = 1`.
- **Decode grid.** θ_on ∈ {0.5, 0.6, 0.7, 0.8}, θ_off ∈ {0.2, 0.3, 0.4}, sustain_on ∈ {0.1, 0.2, 0.4} s, sustain_off ∈ {0.4, 0.8, 1.2} s; raw floor 1.1653 s; then the trainer's port of `SegmentBuilder.finalizeWithRaw` at the committed settings, which must first reproduce every stored R0 clip's padded span from that clip's stored **pre-merge** raw spans exactly — including clips that joined short raw rallies, whose pre-roll is capped before the merge (the contract §3a parity fixture) — a port that fails that check stops the run. The grid point is chosen on the nested fold by the **D-007 objective**: minimise dead-time retention subject to complete-rally recall ≥ R0's on that nested fold; ties → fewer false clips → earlier grid order. One grid point per fold per candidate; the chosen points are reported.
- **Winner.** The candidate carried forward is the one whose H (H1 for R1, H2 for R2) holds; if both hold, R2; if only H1 holds, R1; if neither, none (§10). No holdout number enters any of this; there is no holdout.

## 6. Metrics (the scoring contract, v1, as implemented by `scripts/scoring/reference_scorecard.py` and the Swift scorers)

Per fold (5), per surface, per group, pooled; each with its sample (rallies, recordings, groups) and a paired group-bootstrap 90 % interval (1,000 draws, seed 0, groups as units) for every candidate − R0 difference:

- raw-boundary scorer: tp / fp / fn at IoU ≥ 0.5 (and 0.3 reported), `startMAE`, `endMAE`, signed medians, within-1-s fractions, `split`, `merged`, `excludedTimeDiagnostics`;
- padded-export scorecard: **complete-rally recall** (0.98, provisional), clipped, missed, **dead-time retention** and seconds, **false clips** per exported segment, `mergedRallies`, `scorableDeadSecondsDelivered`, `excludedSecondsDelivered`;
- per recording: every truth rally in exactly one class (preserved / clipped / merged / split / partial / missed), as EXP-20261031 §6 reports;
- diagnostics of the learned path: calibration (reliability diagram per surface), `uncertain time` per recording (steps with calibrated p ∈ [0.3, 0.7] for ≥ 2 s), `unprimed` decoded intervals (no serve within 3 s), decoded intervals dropped by the raw floor;
- restricted recordings: all of the above, apart;
- missed-serve marks: how many excluded spans each candidate's clips enter (diagnostic);
- **on-device**: processing time per minute of video with the switch at `fsm` and `learned`, peak memory, bundle delta — measured by the owner on the physical iPhone for the carried-forward candidate only, after conversion (§8 of the research document); bar: no measurable increase per minute of video, < 5 MB added. `not measured` until then.

Dead-time metrics are null for any recording that is not `declared_complete`/`stage1_complete` or whose negatives are not `standard` (the contract's `fullyMarked` rule) — those recordings contribute recall, false clips and boundary errors only.

## 7. Reporting by surface and uncertainty

Tables per surface (beach / grass / indoor), per recording group (18) and pooled; the minimum sample for a number to be reported without the "indicative only" mark is 3 groups and 30 rallies; per-surface intervals rest on 5–7 groups and are expected to be wide — a surface result is never a claim on its own. Restricted recordings in a separate table. Every table states the fold draw and the dataset digest.

## 8. Protected-holdout access and the future independent test

**None in this experiment.** No lineage-holdout, legacy-holdout, final-test or candidate recording is read, exported, scored or compared. The seven lineage-holdout candidates have no rally marks; if the owner has them marked later (a labeling task that is not model exposure), a **separate** preregistered record names the one carried-forward candidate and evaluates it once, by the D-017 §4 procedure, with a `rally_scoring` ledger row written before the run. The planned new-footage final test is the other route. This record claims nothing about either.

## 9. Reproducibility

| Field | Value |
|---|---|
| Code SHA (repo) at export · at training · trainer script SHA-256 | `not fixed` |
| Dataset: name · manifest SHA-256 · digest · split-manifest hashes · detector digest · pipeline config SHA-256 | `not fixed` (§2) |
| Fold draw (seed 20261103, 5 folds, the resulting fold per group) | `not fixed` (the demonstration draw in §2 is on today's groups) |
| Feature schema · derived set · grid view | `rcf_v1` · `derived_v1` · `grid_v1` (research document §3.2, contract §4.4; the trainer's `features.py` SHA-256 `not fixed`) |
| Hardware · OS · Python · numpy · torch versions | `not fixed` (the Mac suffices; no GPU) |
| Run folder and artefact hashes (per candidate: weights, calibration, decode parameters, out-of-fold predictions `oof.jsonl`, scorecards `evaluation_v2.json` per recording, `report.{json,md}`) | `not fixed` |
| Evaluation code revision (reference scorecard SHA-256, Swift scorer commit) | `not fixed` |

## 10. Success, failure and limitations

- **Keep (as a candidate for the next step, not for production):** H1 holds, and the carried-forward candidate's net-ablated condition also holds H1. Next step: the Core ML runner PR behind `ProcessorConfig.rallyDecision = .fsm` (default), parity test, owner's on-device measurement, then the independent evaluation (§8) before any default change.
- **Revert:** H1 fails and the learned models' recall difference intervals lie below zero, or they buy recall with more false clips or dead time: the FSM stays; the record closes with what the out-of-fold errors show (which rallies, which surfaces, which failure class), as the input to the next plan.
- **Need data:** H1 not told apart (intervals include zero), or G6 fails, or the per-surface tables disagree in sign: no production change; the owner decides between Stage 1 truth, more marked recordings, or confirming negatives for more of the corpus.
- **Limitations stated in advance:** development evidence only (detector-training and decider-selection exposure of the 34); 0 confirmed venues or sessions among them (relations unknown, not cleared); legacy marks' timing (toss-or-contact ± snap, press-time ends, proxies on VFR footage) — boundary numbers are bounded by it; no Stage 1 non-rally-activity spans (hard negatives); three edited recordings as restricted positives; two handheld; the online groups (5, 10) are single-uploader channels whose venue composition is unknown; one seed for R2; the evidence of one detector (L1); R2 reads the 30 Hz grid view and so misses about one processed frame in eight on the `1/30 − 0.004` s feed while R1 sees every step (contract §4.4).

## Approval

- [ ] Gate §2a passed (each row initialled by the owner with the date).
- [ ] Owner approved this preregistration on `<date>` (quote the authorisation).
- [ ] Dataset validated (name, digest, validator report pasted in §2).
- [ ] Training started on `<date>`; no protected recording evaluated.

## 11. Update of 2026-11-13: the dataset, the frozen folds, readiness, and what needs the owner's decision

Written on the owner's authorisation of 2026-11-12 (§11, [verbatim](../../decisions/2026-11-12-d036-completion-authorization.md)): "Update the existing experiment … Use the actual corrected dataset rather than the old provisional 34-recording estimate." Sections 1–10 above stand as proposed on 2026-11-03 and are not rewritten; where this section differs from them it says so and asks for the amendment. **Nothing was trained, tuned, calibrated or scored.** The only programs run on the dataset were the validator, the fold draw and the trainer's dry run, which fits nothing.

### 11.1 The dataset (fills §2 and §9)

| Field | Value |
|---|---|
| Dataset | `rc-v1-20261112` (`rally_classifier_dataset_v1`, `rcf_v1`, `rally_activity_truth_v1`, `boundaryIgnoreSec` 0.5) · manifest SHA-256 `eaa95c08d2fd010b75cca1b88b9c52b487206f34561f70515efc45553911af74` · digest `1b1e68986311e7cef4e02a04dd248259d07aef03ebbd567a39464c0e414a180f` |
| Where | `~/Movies/RallyLab/Datasets/rally-classifier/rc-v1-20261112` on the Mac (74 MB). `rc-v1-20261108` is preserved unchanged on the staging share |
| Export | `RallyLab --project Scratch --export-rally-classifier-dataset rc-v1-20261112`, code `284a8d1` (`main` after PRs #172–#175), executable SHA-256 `a5108de154716f30…`; started 2026-11-13T03:09Z, stopped once on a video read failure after 8 recordings (the share), resumed with `--resume` (those 8 kept by the journal, their files re-hashed), finished 08:36Z. Report `Scratch/manifests/rally-classifier/20261113-042226-export.{md,json}` |
| Split manifest at export | project.json `bc6a5fccdb55e3f3…` · sessions `91a398ca88617f77…` · validation.json `cc22cd32c5f7aee5…` · manifest.json `6e71f352fc925600…`; audit 0 hard findings |
| Withheld closure | 24 names, 8 confirmed sourceIds, 45 fingerprints (`closureSha256` `ff4f7f7b89bcd724…`; file `20261113-042226-closure.json`, SHA-256 `cb166a46612a0564…`): the 16 lineage holdouts, their 3 train copies (D-036, applied 2026-11-12) and the 5 legacy holdouts. No withheld recording was read, decoded or scored by the export |
| Validator | `python3 scripts/rally_classifier/validate_dataset.py <dataset> --withheld <closure.json>` → `OK: 0 error(s), 0 warning(s)`; 49 recordings, 25 groups |
| Detector | `ball_heat` — the bundled L1 `scratch_768_1014`. The manifest records the compiled model's digest in this build, `3fed1407533a5484`; that digest differs from build to build (`rc-v1-20261108` recorded `d4aeac1583ab4cec`) and is not a stable model identity. The model files are unchanged between the two export commits, and every steps file of the two datasets is byte-identical (below) |
| Pipeline config | SHA-256 `5be93ef689c9e95de2b0164bfb2232ca1ff44af551b50636c5b2f289bd02ef87` (unchanged) |
| Baseline | `EvidenceReplayer.decidedRallies`: `r0` (join 1.3513, min 2.6131, pre-roll 2, post-roll 0.5, serve-primed start; config `5be93ef6…`) and `r0_prime` (join 0, min 1.5, pre-roll 2, post-roll 1; config `6251c4da…`) — 588 and 677 stored clips |
| Recordings | **49** (beach 18, grass 14, indoor 17): **31 continuous** (standard: negatives usable) and **18 edited** (`restrictedUse`: positives only, no full-video negatives), each type confirmed by a person (D-032, D-033). 736 truth rallies; 73 missed-serve marks as excluded spans; 17 recordings carry cut ranges; no time-breaking span; no Stage 1 record (`NON_RALLY_ACTIVITY` 0) |
| Steps | 439,277: `ACTIVE_RALLY` 172,746 · `NON_RALLY` 170,171 · `TRANSITION` 45,374 · `UNKNOWN` 36,556 · `EXCLUDED` 14,430. Positive time 5,793.8 s; valid negative time 5,674.9 s |
| Left out | 94 project recordings: 90 whose pass is not complete, 4 whose marks overlap a cut range or each other. The three train copies are no longer candidates (withheld) |
| Ledger | 49 `training_package` rows, ref `--export-rally-classifier-dataset rc-v1-20261112`, written by the exporter after validation (ledger now 836 rows) |

**Against `rc-v1-20261108`.** The same 49 recordings, the same 25 groups and splits (train 38, dev_val 5, tune 6), and **every steps file and every baseline file byte-identical** (so the digest is the same). What differs is the record: the withheld closure (21 → 24 names, 5 → 8 sourceIds, 42 → 45 fingerprints), the split-manifest hashes, the code and executable, the build's detector digest, a confirmed `sourceId` on two recordings (`bch_extra_self_04` `IMG_3606`, `bch_gnd_ovc_land_self_01` `IMG_0080`), and the new ledger rows. Evidence was not reused from the older dataset: the supported `--resume` requires the same dataset name, code and executable, and no reviewed operation exists that would vouch for evidence across them; the detector was run again over all 49, and the identical bytes show that PRs #172–#175 changed nothing in the evidence.

**No duplicate crosses a fold.** No pair of D-036 has both members in the dataset (one member each of `IMG_0080`, `IMG_0492`, `IMG_3606`). The content audit of the protected recordings ([EXP-20261112](EXP-20261112-protected-content-lineage-audit.md)) found no copy of a withheld recording among the dataset's recordings.

### 11.2 The folds (replaces §2 "Recording groups and folds" and §9 "Fold draw" — amendment A1, A2)

Drawn once with `scripts/rally_classifier/folds.py` (PR #178; procedure `fold_draw_v1`, seed 20261103, the 6th shuffle, `--stratify every-fold`, rally balance ±25 %) from the manifest's `groupId`, and frozen as [`EXP-20261103-temporal-rally-classifier-prereg.folds-rc-v1-20261112.plan.json`](EXP-20261103-temporal-rally-classifier-prereg.folds-rc-v1-20261112.plan.json) (SHA-256 `b5e4b4ef3c6ce1cdd7c5d24a7284a1a66f82e05b02d332d93cc5301884355c9d`). The file names the dataset, its manifest SHA-256 and digest; the trainer refuses it for any other dataset, and re-derives the draw so an edited file is refused. The dataset itself carries no fold. Every one of the 49 recordings is scored once, out of fold: the dataset's `train` / `dev_val` / `tune` are historical roles and play no part.

| Fold | Groups (beach / grass / indoor) | Recordings (restricted) | Rallies | Positive s | Valid negative s | Groups with valid negatives | Standard recordings: n, rallies |
|---|---|---|---|---|---|---|---|
| 0 | 5 (2 / 1 / 2) | 13 (6) | 170 | 1,947.7 | 1,032.8 | 2 | 7, 80 |
| 1 | 5 (2 / 1 / 2) | 8 (3) | 121 | 814.2 | 1,036.4 | 4 | 5, 47 |
| 2 | 5 (1 / 2 / 2) | 8 (2) | 124 | 921.9 | 1,031.5 | 4 | 6, 77 |
| 3 | 5 (1 / 2 / 2) | 8 (4) | 154 | 854.3 | 862.9 | 4 | 4, 43 |
| 4 | 5 (1 / 1 / 3) | 12 (3) | 167 | 1,255.6 | 1,711.4 | 4 | 9, 93 |
| all | 25 (7 / 7 / 11) | 49 (18) | 736 | 5,793.8 | 5,674.9 | 18 | 31, 340 |

Groups, by their first recording — fold 0: `bch_ele_sun_port_self_03`, `bch_onl_ovc_land_onl_02`, `grs_hnd_shade_port_self_02`, `ind_ele_bright_land_self_01`, `ind_onl_bright_land_onl_01`; fold 1: `bch_extra_self_12`, `bch_gnd_ovc_land_self_01`, `grs_tri_sun_land_self_01`, `ind_extra_self_08`, `ind_gnd_bright_land_self_01`; fold 2: `bch_gnd_sun_land_self_02_v3`, `grs_ele_sun_land_self_01_v2`, `grs_onl_sun_land_onl_04`, `ind_ele_dim_land_self_02`, `ind_tri_bright_land_self_01_v3`; fold 3: `bch_extra_self_04`, `grs_ele_dusk_port_self_03`, `grs_gnd_sun_land_self_01`, `ind_gnd_bright_port_self_03`, `ind_hnd_dim_land_self_02`; fold 4: `bch_ele_ovc_land_self_02`, `grs_extra_self_04`, `ind_ele_dim_land_self_04`, `ind_extra_self_07`, `ind_tri_dim_port_self_02`.

Five folds are feasible: every fold holds every surface and five groups, and the rally counts (121–170, mean 147) are within ±25 %. The restricted recordings are a large part of the pool (18 of 49, 396 of 736 rallies) and are reported apart; the headline tables rest on the 31 standard recordings and their 340 rallies — per fold 43 to 93 rallies, and in fold 3 only four standard recordings.

### 11.3 The data-readiness gate (§2a) as it stands

| Gate | State on 2026-11-13 |
|---|---|
| G1 confirmed `recordingType` for every candidate | **met**: 49 of 49 (31 continuous, 18 edited), confirmed in the marking pass (D-032, D-033) |
| G2 scanner-flagged recordings | settled by G1: `bch_ele_sun_port_self_03` edited (7 cut ranges, restricted), `grs_ele_dusk_port_self_03` continuous and its `_v2` edited; `grs_ele_shade_land_self_02` is not in the dataset (its pass is not complete) |
| G3 the exporter | **met** (on `main`) |
| G4 fresh split manifest and audit, 0 hard findings | **met** at the export |
| G5 validator 0 errors with the external closure | **met** |
| G6 "at least 12 of the 18 groups contribute negatives" | 18 of 25 groups contribute valid negatives (72 %); every fold has at least two such groups (fold 0 has two, the others four). Met as a count and as the same fraction; the wording needs restating for 25 groups (amendment A3) |
| G7 (proposed on PR #138, not adopted): every recording that supplies `NON_RALLY` steps is audited for coverage | **not met — the negative-coverage audit has not been run.** Every recording's `coverage.state` is `declared_complete` with no verified coverage: the 5,674.9 s of negatives are "the owner declared the pass complete on a continuous recording", not "a second look found no unmarked rally" |

### 11.4 The trainer and its dry run

The trainer is `scripts/rally_classifier/{folds,features,decode,evaluate,tcn,train}.py` on PR #178 (described in `docs/ml-roadmap/RALLY_CLASSIFIER_TRAINER.md` there; synthetic tests only). Its dry run on this dataset — validation against the closure, the folds file's identity, the SegmentBuilder-port parity check, feature extraction, the per-fold counts; **no fit, no score** — was made on 2026-11-13 for R1 and R2:

- The digest it computes equals the exporter's.
- The parity check required by §5 first **failed on 14 of 1,265 stored clips** (each a clip reaching the end of a recording): the port clamped to the duration rounded to a tick where the builder truncates. Fixed in the port; all 1,265 (r0 588, r0_prime 677) are now rebuilt exactly.
- 42 inputs for R1; 439,277 steps. Every training side has both classes; every nested fold holds fully marked recordings; **0 problems** for both candidates.

| Outer fold | Nested fold | Test recordings / rallies | Training + / − steps | Nested + / − steps | Fully marked recordings in the nested fold |
|---|---|---|---|---|---|
| 0 | 1 | 13 / 170 | 115,333 / 139,204 | 24,419 / 31,070 | 5 |
| 1 | 2 | 8 / 121 | 148,327 / 139,101 | 27,651 / 30,942 | 6 |
| 2 | 3 | 8 / 124 | 145,095 / 139,229 | 25,615 / 25,869 | 4 |
| 3 | 4 | 8 / 154 | 147,131 / 144,302 | 37,648 / 51,323 | 9 |
| 4 | 0 | 12 / 167 | 135,098 / 118,848 | 57,413 / 30,967 | 7 |

Trainer command (replaces §4's placeholder; amendment A11): `python3 scripts/rally_classifier/train.py <dataset> --folds-file <folds file> --withheld <closure.json> --candidate {r1,r2} --net {present,ablated} --seed 20261103 --out <run>`; R2's H2 needs `--r1-run <run>`. Script hashes go in §9 when PR #178 is merged.

### 11.5 Amendments this record needs before it can be approved

Each is a place where §§1–10 cannot be run as written, or where the owner's requirements of 2026-11-12 differ from them. The trainer implements the reading given; the owner accepts it or changes it.

| # | §§ | As written | Proposed |
|---|---|---|---|
| A1 | §2, §9 | the fold draw "is written into the dataset manifest (`fold` per recording)" | the folds live in their own frozen file tied to the dataset's digest (owner, 2026-11-12); the dataset is never edited |
| A2 | §2 | the procedure is described in a sentence, and its demonstration draw has folds of 3–5 groups | the exact procedure `fold_draw_v1` (the deal carries on across surfaces; re-shuffle until every fold holds every surface and the rally counts balance); 25 groups → five folds of five |
| A3 | §2a G6 | "at least 12 of the 18 groups contribute negatives" | at least two-thirds of the groups, and at least two groups with valid negatives in every fold (today 18 of 25; 2, 4, 4, 4, 4) |
| A4 | §2 | 34 recordings, 18 groups, 561 rallies; restricted = two handheld and three scanner-flagged recordings | 49 recordings, 25 groups, 736 rallies; `restrictedUse` is what `TrainingEligibility` says — the 18 **edited** recordings. The continuous handheld recording `grs_hnd_shade_port_self_02` is standard in the dataset: accept, or have handheld recordings reported apart as §2 said |
| A5 | §3 R1 | "full-batch gradient descent" with no step size or iteration count | Newton's method to the unique minimum of the same penalised, class-balanced loss (deterministic) |
| A6 | §3 R2 | "±63-cell margins so every cell is scored once" with a 300-cell hop | a 150-cell margin (the only one under which a 600-cell window with a 300-cell hop scores every cell once) |
| A7 | §6 | six per-rally classes (preserved / clipped / merged / split / partial / missed) | the four the reference scorecard defines, or the scorecard is extended first in its own reviewed change |
| A8 | §5 | the decode point is the one minimising dead time "subject to recall ≥ R0's on the nested fold" | plus stated fallbacks when no grid point reaches R0's recall, or the nested fold has no fully marked recording (the dry run found neither case in this draw) |
| A9 | §5 | temperature scaling alone | as written; noted that it cannot remove the bias class balancing gives R1 — add a bias term only if the owner asks |
| A10 | §3, §5 | the stored R0 clips passed the pipeline's above-net rule; a candidate's decoded clips cannot be given it by the trainer | stated in every report as a known asymmetry in R0's favour, or a baseline variant without the rule is exported |
| A11 | §4 | `train.py … --folds 5` | the command of §11.4: `--folds-file` and `--withheld` are required; no R3 |
| A12 | §5, §10 | the winner and the keep / revert / need-data reading | read from the four runs' reports by hand; the trainer evaluates H1 and H2 as worded and does not compute the verdict |
| A13 | §2 "Not claimed" | "26 of the 34 carry decider-selection or acceptance exposure" | of the 49: 44 have a detector training-package row on the ledger (`Scratch-multiframe-20261016-2018`, `Scratch-L2-multiframe-20261021-1917`); the five album recordings (`bch_extra_self_04`, `bch_extra_self_12`, `grs_extra_self_04`, `ind_extra_self_07`, `ind_extra_self_08`) have none; which recordings the shipped detector `scratch_768_1014` itself trained on is not on record (its package is gone), so its exposure to any of the 49 is unknown, not cleared; 24 carry `rally_scoring` rows. Development evidence only, as before |

### 11.6 The open data-readiness decisions (PR #138, still unmerged)

| Decision | State | Recommendation |
|---|---|---|
| D5 route for footage-type confirmation | settled in practice: types are confirmed in the marking pass on the Mac and the phone (D-032, D-033); 49 confirmed | none needed |
| D6 coverage-audit sample; D8 contract amendment `coverage.audit` and gate G7 | **open.** No audit has been run; the protocol and its draw tool are on PR #138 | decide before approving: either run stage 1 (12 recordings, 4 per surface, every unmarked interval watched once by a person, about two hours) so the negatives rest on more than the declaration, or approve the first run with G7 explicitly waived and "negatives declared, not audited" as a stated limitation of its dead-time and false-clip numbers |
| D10 an edited recording's time outside its cuts as negatives | not assumed: the 18 edited recordings supply positives only | keep |
| D7 new final-test footage; D9 marking it while reserved | **open.** Nothing acquired. Needed before any production claim, not before this development experiment | plan it alongside; PR #181 keeps by-hand marking of a reserved recording open to the lead |
| The lineage holdout as a later test | three of the 16 are exposed (D-036, D-037); three others now carry the owner's rally marks; `grs_ele_sun_land_self_01_v2` and `_v3` in this dataset are other stretches from the same outing as a withheld recording | no holdout is described as pristine; §8 stands |

### 11.7 What remains before training can begin

1. The owner merges PR #178 (the trainer) and this update; the script hashes then go into §9.
2. The owner decides the amendments A1–A13 (accept as proposed, or change).
3. The owner decides the negative-coverage question (D6/D8/G7): audit first, or waive with the limitation stated.
4. The owner approves this preregistration (the checklist under "Approval"), quoting the authorisation. Until then no model is trained, tuned, calibrated or scored.

