---
id: EXP-20261101-l2-decider-retune-r2
status: planned
created: 2026-11-01T19:39:30Z
updated: 2026-11-01T19:39:30Z
decision: owner 2026-11-01 ("go for the second plan same data"), applying owner decisions 2026-10-31 §2 (bounded L2 decider retune on eligible development tune data only); D-002, D-017 honoured; D-001 (the FSM decider is the benchmark and fallback)
roadmap_phase: L2 ship decision (PR #110 held)
pr: exp/l2-decider-retune-r2
issue: n/a
---

# EXP-20261101-l2-decider-retune-r2 — the decider retune for L2, second plan: the same passes, the same grid, false clips priced at the acceptance bar's rate

**Status: planned.** Written and committed before the search runs. The plan file beside this record, `EXP-20261101-l2-decider-retune-r2.plan.json` (sha256 `abc2ffd970b1ebdd2c0bc3a62daa28f19b351de28befcc41c5a15ff4a5f387bf`), is what `RallyLab --retune-decider` reads; the command copies it into its output folder and writes its hash into `report.json`.

## 0. Why

[EXP-20261031-l2-decider-retune](EXP-20261031-l2-decider-retune.md) (frozen, *done — need data*) chose join 0 / postroll 1.0 / preroll 2.0 for L2 on the tune pool and, on the evaluation pool, met three of five bars: preserved 137 against L1's 127, merged 150 against 159, objective above L2 committed — but **false clips 48 against a bar of ≤ 31** and **dead time 4.43 s per rally against ≤ 4.19 s**. Its §8 names the cause as a methodology finding: the objective priced a false clip at 0.25 of a preserved rally while the bar allows two in total, so the search bought ten preserved rallies with nineteen false clips the bar then rejected; on the tune pool too (false 12 → 14), so the pool did not mislead it. The owner's direction on 2026-11-01: *"go for the second plan same data"*.

## 1. Hypothesis

**H1.** With a false clip priced at a whole preserved rally in the objective — a false clip is no longer a currency the search can buy preservation with — the settings chosen on the tune pool preserve at least as many marked rallies on the evaluation pool as L1 at its committed settings, with no more merged rallies, no more than two more false clips, no more than 10 % more dead time per rally, and a higher objective than L2 at the committed settings. Each clause is an acceptance criterion (§5); any one failing means *need data*, not promotion.

**H0, stated so it can be the answer.** No grid point preserves more than L1 without paying in false clips; then the top of the grid under the new objective is the committed settings or a near neighbour, and the finding is that joining and padding alone do not close L2's gap on this grid.

**Not claimed.** Generalisation. Every recording is in both models' training packages and was scored in the diagnostic. **Second look:** the evaluation pool's result from the first plan is what motivated this objective, so the evaluation pool has now informed one design choice (the price of a false clip); its result here is development evidence with that caveat, weaker than the first plan's, and no third plan on the same pools follows without the owner saying so.

## 2. Baseline, frozen: the first plan's search

`~/Movies/RallyLab/Reports/l2-retune-20261031/search/` — `report.json` sha256 `9c5d3e4039e03f83e5f4e00d6f5f62aaeb09af62c8196fb16f14be5ac6e43629` (every hash in the first record's §7). The 52 passes it was replayed from (`pipeline_tuning/evidence/<name>__<key>.evidence`, L2 key `53360ad1c959`, L1 `9ee7a442cb15`) are the passes of this plan: same detector settings, so the same evidence files, read from the cache — no detector run, no footage read. Replay parity at the committed settings was 52 of 52 within 0.2 s after the `EvidenceReplayer.ballHeight` fix (PR #123, merged 22b055d); the command checks it again.

| evaluation pool (321 rallies, 17 recordings, 11 groups) | preserved | merged | false clips | dead s/rally | objective (first plan's) |
|---|---|---|---|---|---|
| L1 committed | 127 | 159 | 29 | 3.81 | — |
| L2 committed | — | — | — | — | −0.0694 |
| L2 chosen (join 0, postroll 1.0, preroll 2.0) | 137 | 150 | 48 | 4.43 | −0.0094 |

Tune pool (128 rallies): L1 committed 0.3457, L2 committed 0.2588, L2 chosen 0.4845 under the first objective; false 12 / 11 / 14, dead 2.8 / 2.9 / 3.3 s per rally.

## 3. Inputs (frozen)

| Input | Value |
|---|---|
| Code SHA | `main` at the merge of PR #126 (3babef9): `RallyLab/DeciderRetune.swift` and `EvidenceReplayer.swift` as PR #123 left them, unchanged; the binary is built from the branch `exp/l2-decider-retune-r2` cut there, which adds only this record and plan |
| Plan | `EXP-20261101-l2-decider-retune-r2.plan.json` (CF-BSC-009, frozen), sha256 `abc2ffd970b1ebdd2c0bc3a62daa28f19b351de28befcc41c5a15ff4a5f387bf` — identical to the first plan but for `id` and `objective.falseClipCost` 0.25 → **1.0** (checked by a key-sorted diff before the commit) |
| Dataset manifest SHA-256 | as the first plan: `manifests/manifest.json` `05b8bc4feb279a37…`, `project.json` `65243bca59895a7e…`, `validation.json` `6d160a1ac00254a0…` |
| Tune pool | the same 9 `tune` recordings, 4 groups, 128 marked rallies |
| Evaluation pool | the same 17 recordings, 11 groups, 321 marked rallies (the second look, §1) |
| Pool checks | the command's, unchanged: no reserved or withheld name (closure of 21), every rally marked, no group in both pools |
| Not used | the 5 legacy-holdout and 16 lineage-holdout recordings — never read; no protected-holdout feedback |
| Label set | the same `.rallylabels.json` marks — 449 rallies; missed-serve marks counted separately |
| Control / treatment | L1 `09620ab77519bd9d` committed; L2 `8cb1bbca0c2729a8` committed and at the settings chosen here |
| Pipeline config | as the first plan (`ProcessorConfig()` committed, `heatmapOnly`, no rotation, camera per recording, `minRallySec` 1.1653); detection untouched |
| Candidate grid (144) | **unchanged**: preroll {0.5, 1.0, 1.5, 2.0} × postroll {0.25, 0.5, 1.0} × minGapToMerge {0, 0.25, 0.5, 0.75, 1.0, 1.3513} × minSegmentLength {1.5, 2.6131}. The first record's §8 suggested candidates between the committed and the chosen settings; the grid already holds them (join 0.25 and 0.5, postroll 0.5 and 1.0), and keeping it identical makes the objective the only difference between the two searches. No second stage |
| Objective (chosen before the search) | per rally: (preserved − 0.5 × merged − **1.0** × false clips) / rallies − 0.25 × dead time / rally time. A false clip now costs what a preserved rally gains: the bar (+2 over 17 recordings) says false clips are not to be traded for preservation, and the objective now says the same. Merged and dead-time prices unchanged, so one thing moved |
| Ledger | the command records one `rally_scoring` row per recording per model before replaying, ref `--retune-decider EXP-20261101-l2-decider-retune-r2 heat=<model>@<digest> …` — a new ref, so 52 new rows: the replay is a use of the recordings even without a detector run |
| Compute | this Mac; replay only, minutes |

## 4. Procedure

1. No passes: `RallyLab --project Scratch --retune-decider <plan.json> --out <report>/search` reads the 52 cached evidence files; if any were missing the command would run the detector, which this plan does not authorise — the log is checked for "pass" lines and the run is discarded if one appears.
2. Every candidate replayed on the tune pool only, ranked by the new objective; the best replayed on the evaluation pool beside L1 committed and L2 committed; the first plan's chosen candidate (join 0, postroll 1.0, preroll 2.0, min clip 1.5) is a grid point, so its rank under the new objective is in the table.
3. `report.json` and `report.md`, hashed into §7, written by the first run's record script adapted for this id.

## 5. Acceptance criteria (set before the search)

On the **evaluation pool**, L2 at the chosen settings against L1 at the committed settings — the first plan's bars, unchanged:

- [ ] preserved rallies ≥ L1's (127)
- [ ] merged rallies ≤ L1's (159)
- [ ] false clips ≤ L1's + 2 (31)
- [ ] dead time per rally ≤ 1.1 × L1's (4.19 s)
- [ ] objective > L2 at the committed settings (under this plan's objective)
- [ ] by recording group (11): groups where L2 chosen preserves ≥ L1, reported; no bar

All five met → *keep as a candidate*, with the second-look caveat stated beside it; the owner decides what it is worth. Any failed → *need data*; the report says which and by how much. If the chosen candidate is the committed settings themselves, the result is H0 and the record says so.

## 6. What is reported

As the first plan: per pool, per surface, per group and per recording, every one of the 449 marked rallies in exactly one class; false clips, dead time, padded and raw boundary offsets, both-ends-within-1-s, missed-serve marks, separately; the full grid on the tune pool in `report.json`; the first plan's chosen candidate's rank and objective under the new price.

## 7. Results

Pending.

## 8. Decision

Pending.

## 9. Test results

Pending.
