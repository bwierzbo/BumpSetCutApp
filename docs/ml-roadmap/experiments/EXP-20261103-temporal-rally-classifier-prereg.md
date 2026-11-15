---
id: EXP-20261103-temporal-rally-classifier-prereg
status: proposed — not approved, not run; conditional on the data-readiness gate (§2a)
created: 2026-11-03T19:05:00Z
updated: 2026-11-03T23:06:45Z
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
| G2 | Each of the three scanner-flagged recordings has reached one of four outcomes, decided by a person, never by the scanner and never by the gate: (a) confirmed `continuous` where genuinely supported; (b) confirmed `edited` with valid cut ranges (D-030, PR #135 on `main`) excluding the non-continuous spans — **positives only**: the cuts keep the timeline and the `ACTIVE_RALLY`/`EXCLUDED` labelling clean, but its negatives stay `restricted` (`UNKNOWN`) because `TrainingEligibility.assess` assigns an edited recording restricted negatives unconditionally (`RallyLab/TrainingEligibility.swift:148-151`) and the dataset validator refuses `standard` negatives for any non-continuous recording; promoting them would need a reviewed eligibility amendment plus a contract/validator change, which this record does not assume (owner decision D10 in the readiness plan); (c) restricted positives-only use with its non-rally time `UNKNOWN` (the default when nothing is confirmed); (d) excluded from the candidate list when source timing or eligibility cannot be established. A recording is never classified `continuous` to satisfy this gate (owner 2026-11-03 §4; amended in [RALLY_CLASSIFIER_DATA_READINESS_PLAN_2026-11-03.md](../RALLY_CLASSIFIER_DATA_READINESS_PLAN_2026-11-03.md)) | not met (all three at outcome c by default) |
| G3 | An exporter that writes `rally_classifier_dataset_v1` from the split manifest, the withheld closure, eligibility and the marks, and records the ledger row (a reviewed RallyLab PR) | not met (no exporter) |
| G4 | A fresh split manifest and audit (0 hard findings) at the export commit | re-run at export |
| G5 | The validator reports 0 errors on the written dataset, with the external closure file | at export |
| G6 | At least 12 of the 18 groups contribute negatives (otherwise the negative class is too thin for grouped folds) — a count, not a target; below it the experiment is *need data* before it starts | `not fixed` |
| G7 (proposed, owner decision D8) | Every recording that supplies `NON_RALLY` steps is `audited_clean` under the [coverage-audit protocol](../RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md) (stage 1 bound met and the recording itself audited) or `stage1_complete`; a recording without either contributes positives only; G6 is counted over such recordings | not met (no audit drawn) |

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
