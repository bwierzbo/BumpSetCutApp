---
name: rally-classifier-trainer
status: tooling prepared, synthetic tests only — no model has been trained, tuned, calibrated or scored on a real recording; the owner's training gate is closed
created: 2026-11-13T01:54:00Z
updated: 2026-11-13T02:02:07Z
decision: D-001, D-007, D-018 (preregistration before training), D-021 (scoring contract); owner requirements of 2026-11-12 (grouped out-of-fold evaluation over every eligible development recording, folds frozen in their own file)
---

# Rally classifier trainer and fold tooling

The tools that will run [EXP-20261103-temporal-rally-classifier-prereg](experiments/EXP-20261103-temporal-rally-classifier-prereg.md) once the owner approves it: the fold draw, the feature functions, the decode contract and the nested training and evaluation protocol, for the candidates R1 (logistic regression) and R2 (small TCN) against the stored decider outputs R0 and R0′. They read a dataset of the [dataset contract](RALLY_CLASSIFIER_DATASET_CONTRACT.md) and nothing else. **Everything here has been run on synthetic data only.** The one command meant for the real dataset before approval is the dry run (§2), which fits nothing and scores nothing.

This page states what each module does, the exact commands, every place where the specification was silent or ambiguous and what was chosen (§4), and the places where the preregistration cannot be run as written, each with a proposed amendment (§5). The preregistration and the contract are not edited by this change.

## 1. Modules (`scripts/rally_classifier/`)

| File | What it does |
|---|---|
| `validate_dataset.py` (existing) | The fail-closed validator. Three small readers were added for the trainer (`load_manifest`, `read_steps`, `read_baseline`), plus `dataset_identity` (folder name, manifest SHA-256, the contract's digest) and a `specs` argument on the synthetic writer so tests can build a larger dataset with the same builder. No rule changed. |
| `folds.py` | Draws the grouped folds (`fold_draw_v1`) and writes them, once, to their own file with the dataset identity they were drawn for and the per-fold report. `load` is the trainer's reader: it refuses a file drawn for another dataset or edited after it was written. |
| `features.py` | `derived_v1` (R1's 42 inputs: the 18 raw columns and 24 derived ones) and the 30 Hz `grid_v1` view with R2's windows. The one function the Swift extractor will have to reproduce. |
| `decode.py` | Probabilities → raw intervals (hysteresis, raw floor) → clips (the SegmentBuilder port), the 108-point grid, and `parity`, which rebuilds every stored baseline clip from its pre-merge raw spans and stops the run on one mismatch. |
| `evaluate.py` | Builds the reference scorecard's input from a recording and a set of clips, pools per-recording scorecards into tables, runs the paired group bootstrap and evaluates H1 and H2 as worded. Every rally metric is `scripts/scoring/reference_scorecard.py`'s. |
| `tcn.py` | R2 in PyTorch (CPU, deterministic): model, windows, augmentation, loss, training. Imported only for `--candidate r2`. |
| `train.py` | The checks that precede a fit, the dry run, the nested protocol, the artefacts and the report. |

`scripts/train_rally_classifier.py` (the July within-video script) is not used, imported or extended.

## 2. Commands

```bash
D=<dataset folder>                 # e.g. ~/Movies/RallyLab/…/<name>; its folder name is the dataset's name
C=<withheld closure .json>         # the external closure the exporter validated against

# 1. Draw and freeze the folds (writes nothing if five folds are infeasible; never overwrites)
python3 scripts/rally_classifier/folds.py "$D" --out folds-<dataset>-s20261103.json --withheld "$C"

# 2. Readiness — the only run for the real dataset before approval: fits nothing, scores nothing
python3 scripts/rally_classifier/train.py "$D" --folds-file folds-….json --withheld "$C" \
    --candidate r1 --net present --seed 20261103 --out runs/readiness-r1 --dry-run

# 3. After approval: each candidate in each net condition (four runs)
python3 scripts/rally_classifier/train.py "$D" --folds-file folds-….json --withheld "$C" \
    --candidate r1 --net present --seed 20261103 --out runs/r1-present
python3 scripts/rally_classifier/train.py "$D" --folds-file folds-….json --withheld "$C" \
    --candidate r2 --net present --seed 20261103 --out runs/r2-present --r1-run runs/r1-present
# … and the same two with --net ablated
```

`folds.py` options: `--folds N` (default 5, at least 3: one fold held out, one chosen on, the rest trained on), `--seed` (default 20261103), `--stratify every-fold|where-feasible` (default `every-fold`), `--max-shuffles` (default 1000). `train.py` refuses, before any fit: a missing or unreadable closure file; a dataset the validator does not pass; a baseline `r0` that is not at the committed settings (preroll 2.0, postroll 0.5, join 1.3513, minimum 2.6131, serve-primed start on) or an `r0_prime` not at the D-029 ones; a folds file whose dataset name, manifest SHA-256 or digest is not this dataset's, or whose assignment is not what its seed draws; a SegmentBuilder port that fails parity; a run folder that is not empty.

A run folder: `fold<k>/weights.json` (R1) or `weights.pt` + `weights.json` (R2), `fold<k>/calibration.json`, `fold<k>/decode.json`, `oof.jsonl` (one line per step: recording, fold, tick, logit, calibrated p), `scorecards/<r0|r0_prime|candidate>/<recording>.evaluation_v2.json`, `report.json`, `report.md`. A dry run: `readiness.json`, `readiness.md`. The report's identity block carries the dataset identity, the folds file's SHA-256 and draw, the SHA-256 of every script involved and the Python / numpy / torch versions — what the preregistration's §9 asks for.

Tests: `python3 -m unittest discover -s scripts/tests -p 'test_rally_classifier_*.py'` (folds: standard library; the rest need numpy; R2's need torch and are skipped without it). They build their datasets with the validator's synthetic writer (`scripts/tests/rally_classifier_synthetic.py`).

## 3. What a run does

1. Validates the dataset with the external closure, checks the baseline settings, loads and verifies the folds file, runs the parity check.
2. For each outer fold k of K: the nested fold is (k + 1) mod K. On models fitted to the other K − 2 folds it chooses, on the nested fold: R1's penalty from {1e-4, 1e-3, 1e-2} or R2's stopping epoch (≤ 40) by loss; one temperature; one decode grid point by the D-007 objective against R0 on the same recordings. It then refits on the K − 1 training folds and predicts, calibrates, decodes and scores fold k. Nothing of fold k is read before that last step (a test replaces fold k with nonsense and shows every choice unchanged).
3. Scores the candidate's clips and the stored `r0` / `r0_prime` clips of every recording with the reference scorecard, and reports per fold, per surface, per group and pooled over the standard recordings, restricted recordings apart, with paired group-bootstrap 90 % intervals (1,000 draws, seed 0, groups as units) for every difference from R0.

Labels: only steps with `w` = 1 enter a loss, a class weight, a standardisation or a temperature. `TRANSITION`, `UNKNOWN` and `EXCLUDED` steps contribute nothing (tests show their targets and measurements can be replaced without moving a gradient or a fit). Steps inside a cut range or a time-breaking span are never decoded; missed serves and other excluded spans are masked by the scorecard, never counted as negatives.

## 4. Choices where the specification was silent or ambiguous

**Folds (`fold_draw_v1`)**
1. The deal carries on from one surface to the next rather than restarting at fold 0, so folds differ by at most one group (18 groups → 4, 4, 4, 3, 3; §2 says "5 folds of 3–4 groups") and a surface with at least K groups is in every fold by construction. See §5.2.
2. A re-shuffle shuffles the same list again with the same `random.Random(seed)`; the accepted attempt's number is recorded. Limit 1,000 attempts.
3. Rally balance: every fold's rally count within 25 % of the mean, inclusive, counting all recordings of the fold (restricted ones too).
4. A group whose recordings have different surfaces takes the most frequent (ties: alphabetical) and is listed in the report.
5. `--stratify every-fold` (default) is the preregistration's wording; `where-feasible` is the owner's "stratify where feasible" — opt-in, recorded in the file, with the surfaces that are not in every fold listed.
6. Durations are step time: a step stands for the time since the previous step of its segment. Positive = `ACTIVE_RALLY`; valid negative = `NON_RALLY` + `NON_RALLY_ACTIVITY`.
7. Gate G6 is reported as a count, a fraction and two comparisons (count ≥ 12; fraction ≥ 12/18), never as a verdict: with corrected groups the two can disagree and the owner decides which the gate means.
8. `folds.py` validates the dataset before drawing. The manifest's own `fold` field is ignored. A copy of the dataset under another folder name is another dataset (the contract: the folder's name is the dataset's name).

**Features**
9. Window membership is decided on integer ticks: trailing (k − W, k], forward (k, k + L]. Rates and durations use seconds.
10. A null is 0; a null `dt` is the nominal period, and so is the `dt` of every segment's first step (the stored value there is the gap or cut behind the break — another segment's time, and an outlier of seconds in a column that is otherwise nearly constant). Within a segment `dt` still reaches 0.5 s against a usual 0.029 s; nothing clips a standardised input, because the preregistration provides for no clipping. The only presence indicator is `has_y_above_net` (R1), because a 0 there would read as "at the net top". R2 gets none beyond `cell_missing`, since the preregistration fixes its inputs at 19.
11. `derived_v1` is 24 columns (list in `features.py`), 42 inputs with the raw ones; the research document estimated ≈ 45.
12. `mean_speed` averages consecutive step pairs that both lie in the window and both have a selected track; `log_size_rate_1s` is the least-squares slope of ln(size) against time; a window with nothing in it gives 0.
13. Serves are looked up within the step's segment; `t_since_serve_contact` uses the latest contact, at or before the step, among serves emitted no later than the bound.
14. Grid cells are 20 ticks wide on the tick timeline — cell = (tick − first tick) // 20 — so membership is integer-exact. The grid needs 600 / `samplingHzNominal` to be whole.
15. R2's windows: 600 cells, hop 300; a window answers for its middle 300 cells (the first from the segment's start, the last to its end); cells past the segment's end repeat the last cell. See §5.5.

**Decode**
16. An interval starts at the first step of the high run that opened it and ends at the first step of the low run that closed it. A run's length is its last tick minus its first; thresholds are inclusive.
17. An interval is closed at **every** segment break — a frame gap over 0.5 s as well as a cut or a time-breaking span — and ends one cell after the segment's last step, clamped to the duration.
18. Segments inside a cut range or a time-breaking span are never decoded (their predictions are still in `oof.jsonl`).
19. The SegmentBuilder port is the validator's `pad_and_merge` — the function the contract names — not a second transcription. It was read against `SegmentBuilder.swift` line by line: equal for raw rallies inside the recording, which `finalize_with_raw` enforces; it also refuses a pre- or post-roll that is not a whole number of ticks. Parity compares each clip's padded span and its raw spans.

**Training**
20. R1's objective is Σ cᵢ·BCEᵢ + ½·penalty·‖β‖², Σ cᵢ = 1, each class half the weight, intercept not penalised. See §5.4 for the optimiser.
21. R1's penalty is chosen by the nested fold's loss (the same data term, with the inner folds' class weights); a tie goes to the larger penalty.
22. The temperature minimises the plain cross-entropy of the nested fold's weighted steps, by golden-section search over [0.01, 100]; a value at the edge is flagged `atSearchBound`.
23. The decode point is chosen on all recordings of the nested fold, restricted ones included (they are trained on). Dead-time retention and false clips come from its fully marked recordings. See §5.7 for the two cases §5 of the preregistration does not cover.
24. R2: one convolution per residual block (that is what gives 125 cells and ≈ 27 k parameters: 26,433); not class-balanced (the preregistration balances R1 only); loss on the cells a window answers for; window order shuffled per epoch; the earliest epoch on a tie; the refit runs for the chosen number of epochs with the same seed.
25. R2's augmentation: at most one dropout run per window, 3–15 cells, placed uniformly; besides the columns §4 lists, `is_projectile` is zeroed and `ball_y_any` and `y_above_net` nulled, because the contract ties them to the nulled ones; confidence jitter is drawn per cell and clipped to [0, 1].

**Evaluation**
26. Scoring fixture: cut ranges and time-breaking spans are both passed as cuts; the contact is the rally's start; `fullyMarked` is coverage complete and negatives `standard`.
27. Headline tables hold the standard recordings; restricted recordings are scored identically and reported apart, as a group and one by one.
28. Raw boundaries are the contract's (one span per clip, the union of the raws it joined). The clips' pre-merge raw spans are scored as well (`preMergeRawBoundary`) so that the model's own merges can be told from the padding's; IoU ≥ 0.3 is reported beside 0.5.
29. Pooled numbers are ratios of sums over recordings; boundary errors are pooled over matched rallies; medians are pooled and get no interval.
30. Bootstrap: a draw in which a ratio is undefined is skipped and the number of draws used is reported; a table with one group has no interval. A table under 3 groups or 30 rallies is marked indicative only.
31. H1's "false clips" is the pooled count over fully marked standard recordings. H2's "no worse than R1's" is judged on the point estimates.
32. `unprimed`: a decoded interval with no serve contact within 3 s of its start. `uncertain time`: runs of calibrated p in [0.3, 0.7] lasting at least 2 s. Calibration is reported as a ten-bin table per surface, not a drawn diagram.

## 5. Where the preregistration cannot be run as written — proposed amendments

1. **Folds in the dataset manifest (§2, §9).** §2 writes the draw into the manifest (`fold` per recording). The owner's 2026-11-12 requirement puts it in an immutable file of its own. *Amend:* the folds file's SHA-256, seed and shuffle number are what §9 records; the manifest's `fold` stays null.
2. **The fold procedure and its demonstration (§2).** The text does not say whether the deal restarts per surface; its demonstration draw has a five-group fold, which contradicts "5 folds of 3–4 groups", and cannot be reproduced without the code that made it. *Amend:* §2 names `fold_draw_v1` as defined in `folds.py`; the demonstration is dropped; the final draw on the corrected groups is listed when made.
3. **Five folds on corrected groups.** If the corrected identities leave a surface with fewer than five groups, `folds.py` refuses and reports the counts. The options are `--folds 4` (or fewer) or `--stratify where-feasible`; both change §2 and are the owner's choice. Gate G6's "12 of 18" likewise needs restating for the new group count (§4.7).
4. **R1's optimiser (§3).** "Full-batch gradient descent" fixes neither a step size nor an iteration count, and the result would depend on both. The objective is strictly convex, so the trainer finds its one minimiser by full-batch Newton steps (gradient under 1e-10). *Amend:* "fitted to the minimum of the objective on the full batch, deterministically".
5. **R2's margins (§3).** "600-cell windows, 300-cell hop, ±63-cell margins so every cell is scored once" cannot all hold: with a 300-cell hop each window must answer for 300 cells, which leaves 150-cell margins. *Amend:* "each window answers for its middle 300 cells (at least 150 cells of context, more than the 63 the receptive field needs)".
6. **Per-rally classes (§6).** "Preserved / clipped / merged / split / partial / missed, as EXP-20261031 §6 reports" is `DeciderRetune`'s classification, which the reference scorecard does not implement; porting it would be a second scorer. The report gives one class per rally from the scorecard's own fields — preserved (complete, alone in its clip), merged (complete, sharing its clip), clipped, missed — and the raw scorer's split and merged counts. *Amend* §6 to those, or add the six-class rule to the reference scorecard first.
7. **Decode selection (§5)** is silent on two cases. No grid point reaches R0's recall on the nested fold: the trainer takes the point with the most complete rallies (then least dead time, fewest false clips, earliest) and reports `constraintMet: false`. The nested fold has no fully marked recording: dead-time retention is undefined, so the earliest feasible grid point is taken and `deadTimeAvailable: false` reported; the dry run lists such folds in advance. *Amend* §5 with both rules, or require every fold to hold a fully marked recording.
8. **Calibration after class-balanced training (§3, §5).** R1 is trained class-balanced and calibrated by temperature alone. A temperature rescales logits around zero; it cannot remove the shift the balancing introduces, so R1's "calibrated" probabilities stay biased towards the rarer class and the reliability table will show it. Implemented as written. *For the owner:* keep it (the decode thresholds are chosen per fold anyway), or allow a temperature and a bias (two scalars) for R1.
9. **The above-net rule.** The stored R0 clips are what `EvidenceReplayer.decidedRallies` returns: after SegmentBuilder they pass the above-net rule, which can drop a clip. `rcf_v1` does not hold what that rule reads, so the learned candidate's clips go through the SegmentBuilder port only. A clip the rule would drop stays in the candidate's export — against the candidate on false clips. The report states it. *Amend:* accept and state it, or have the exporter store a baseline variant without the rule.
10. **Restricted recordings (§2).** "Reported apart" and "excluded from the headline per-surface tables when they would be the only recording of a surface in a fold" describe two rules. The trainer always reports them apart, which satisfies both.
11. **The trainer command (§4).** It is the one in §2 above: `--folds-file` and `--withheld` are required, there is no `--folds`, and R3 is not a candidate.
12. **H2, the winner and §10.** H2 needs the R1 run (`--r1-run`). The winner rule and the keep / revert / need-data verdict need both candidates in both net conditions; no single run computes them — they are read off the four reports.

## 6. Not implemented

R3 (the GRU ablation); the Swift feature extractor, the Core ML conversion and the Python/Swift parity fixture; on-device measurements (reported as not measured); the six-class per-rally taxonomy (§5.6); the winner and §10 verdicts (§5.12); a drawn reliability diagram; a second seed for R2. The trainer writes no exposure-ledger row: the exporter wrote the `training_package` rows when it packaged the dataset.

## 7. Known limits of what was verified

- Every test is synthetic. The synthetic baseline is written by the same `pad_and_merge` the port is, so parity on it cannot fail by itself; the tests therefore also break the port and the fixture on purpose, and check the port against hand-computed cases from the contract.
- `dataset_identity`'s digest was written from `DatasetSplitManifest.canonicalDigest` and not compared with a digest the exporter printed. The first dry run on a real dataset should show the same digest as the export report; if it does not, stop.
- Timings on the synthetic set (18 one-minute recordings, this Mac, other work running): dry run about 1 s; R1 8–16 s; R2 about 8 s with one epoch (the tests' budget) and about 110 s at the preregistered 40. On the real dataset R1 should take minutes and R2 tens of minutes on the CPU; neither was measured.
