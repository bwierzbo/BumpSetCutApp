---
id: EXP-20261101-l2-decider-retune-r2
status: done — need data (acceptance bars failed on the evaluation pool); no production change; the owner decides the next step
created: 2026-11-01T19:39:30Z
updated: 2026-11-01T19:56:20Z
decision: owner 2026-11-01 ("go for the second plan same data"), applying owner decisions 2026-10-31 §2 (bounded L2 decider retune on eligible development tune data only); D-002, D-017 honoured; D-001 (the FSM decider is the benchmark and fallback)
roadmap_phase: L2 ship decision (PR #110 held)
pr: exp/l2-decider-retune-r2
issue: n/a
---

# EXP-20261101-l2-decider-retune-r2 — the decider retune for L2, second plan: the same passes, the same grid, false clips priced at the acceptance bar's rate

**Status: done.** §0–§6 were written and committed before the search ran (32ea72e); §7–§9 after. The plan file beside this record, `EXP-20261101-l2-decider-retune-r2.plan.json` (sha256 `abc2ffd970b1ebdd2c0bc3a62daa28f19b351de28befcc41c5a15ff4a5f387bf`), is what `RallyLab --retune-decider` reads; the command copies it into its output folder and writes its hash into `report.json`.

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

## 7. Results (run 2026-11-01; replay only, from the first plan's cached passes)

**Where.** `~/Movies/RallyLab/Reports/l2-retune-r2-20261101/`: `--retune-decider plan.json --out search`, 2026-11-01T19:40:39Z–2026-11-01T19:55:52Z, 144 candidates × 26 replays, from the build of `exp/l2-decider-retune-r2` at `3babef9` (`search.log` names the binary; a first invocation with an older RallyLab that did not know the command printed the project header and exited — `search.log.wrong-binary`, nothing written). No detector pass: the log has no pass line; the 52 evidence files are the first plan's. Plan sha256 in `search/report.json` = §3's `abc2ffd970b1ebdd…`.

| file | sha256 |
|---|---|
| search/report.json | `9d259039169326407d08ef979e7e3cde6be1eef82cad8034bee56fde269f8959` |
| search/report.md | `df9761beb0e1e53c6cc0c9ae546cfe6609a71d67e1084ed6a4afbb5b71c04dbd` |
| search/plan.json | `abc2ffd970b1ebdd2c0bc3a62daa28f19b351de28befcc41c5a15ff4a5f387bf` |
| search.log | `3c0fb741fb11619cd2547ff08bb0daa0f189bc1022e41d168ee5814f20d830a2` |
| plan.json (the input) | `abc2ffd970b1ebdd2c0bc3a62daa28f19b351de28befcc41c5a15ff4a5f387bf` |

**Replay parity at the committed settings:** every one of the 52 passes matches its replay within 0.2 s (as after PR #123). Every number below is a replay.

### Tune pool (settings chosen here; 9 recordings, 4 groups)

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| L1 committed | 128 | 68 | 25 | 27 | 0 | 1 | 7 | 116 | 12 | 2.8 | -1.0 / +0.2 | +0.9 / -0.2 | 26 | 0 (0) | 0.2754 |
| L2 committed | 128 | 61 | 25 | 35 | 0 | 1 | 6 | 111 | 11 | 2.9 | -1.0 / +0.2 | +0.9 / -0.2 | 21 | 0 (0) | 0.1944 |
| L2 chosen (join 0, postroll 1, preroll 2, min clip 1.5) | 128 | 83 | 19 | 18 | 0 | 2 | 6 | 125 | 14 | 3.3 | -1.1 / +0.6 | +0.9 / -0.3 | 20 | 0 (0) | 0.4025 |

By surface (tune):

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bch · L1 committed | 54 | 26 | 6 | 16 | 0 | 1 | 5 | 39 | 1 | 2.0 | -1.1 / +0.4 | +0.7 / -0.0 | 9 | 0 (0) | 0.2740 |
| bch · L2 committed | 54 | 22 | 7 | 19 | 0 | 1 | 5 | 38 | 1 | 2.1 | -1.1 / +0.5 | +0.5 / +0.0 | 7 | 0 (0) | 0.1718 |
| bch · L2 chosen | 54 | 33 | 6 | 9 | 0 | 1 | 5 | 44 | 1 | 2.2 | -1.5 / +0.8 | +0.4 / -0.1 | 6 | 0 (0) | 0.4645 |
| grs · L1 committed | 34 | 21 | 8 | 5 | 0 | 0 | 0 | 34 | 3 | 4.1 | -1.2 / +0.5 | +0.7 / +0.0 | 7 | 0 (0) | 0.3754 |
| grs · L2 committed | 34 | 16 | 8 | 10 | 0 | 0 | 0 | 31 | 3 | 4.4 | -1.2 / +0.1 | +0.8 / +0.0 | 5 | 0 (0) | 0.1488 |
| grs · L2 chosen | 34 | 23 | 5 | 6 | 0 | 0 | 0 | 34 | 3 | 4.8 | -1.3 / +0.8 | +0.7 / +0.0 | 5 | 0 (0) | 0.4058 |
| ind · L1 committed | 40 | 21 | 11 | 6 | 0 | 0 | 2 | 43 | 8 | 2.7 | -0.6 / -0.2 | +1.1 / -0.7 | 10 | 0 (0) | 0.1927 |
| ind · L2 committed | 40 | 23 | 10 | 6 | 0 | 0 | 1 | 42 | 7 | 2.9 | -0.8 / +0.1 | +1.1 / -0.4 | 9 | 0 (0) | 0.2641 |
| ind · L2 chosen | 40 | 27 | 8 | 3 | 0 | 1 | 1 | 47 | 10 | 3.3 | -0.8 / +0.4 | +1.1 / -0.5 | 9 | 0 (0) | 0.3161 |

### Evaluation pool (not used to choose; 17 recordings, 11 groups — development evidence, second look)

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| L1 committed | 321 | 127 | 10 | 159 | 0 | 6 | 19 | 191 | 29 | 3.8 | -1.9 / +1.7 | +0.1 / +1.2 | 11 | 36 (8) | -0.0844 |
| L2 committed | 321 | 121 | 6 | 169 | 0 | 8 | 17 | 192 | 35 | 4.2 | -1.9 / +1.6 | +0.1 / +1.1 | 11 | 36 (7) | -0.1512 |
| L2 chosen (join 0, postroll 1, preroll 2, min clip 1.5) | 321 | 137 | 5 | 150 | 2 | 10 | 17 | 230 | 48 | 4.4 | -1.9 / +2.1 | +0.0 / +1.1 | 5 | 36 (7) | -0.1216 |

By surface (eval):

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bch · L1 committed | 125 | 65 | 5 | 44 | 0 | 2 | 9 | 98 | 20 | 4.4 | -1.7 / +1.8 | +0.3 / +1.3 | 3 | 11 (3) | 0.0431 |
| bch · L2 committed | 125 | 65 | 2 | 46 | 0 | 4 | 8 | 99 | 21 | 4.8 | -1.8 / +1.7 | +0.2 / +1.2 | 3 | 11 (3) | 0.0131 |
| bch · L2 chosen | 125 | 72 | 3 | 37 | 0 | 5 | 8 | 113 | 28 | 5.2 | -1.8 / +2.1 | +0.2 / +1.2 | 2 | 11 (3) | 0.0359 |
| grs · L1 committed | 93 | 24 | 0 | 68 | 0 | 1 | 0 | 32 | 2 | 3.2 | -2.1 / +1.7 | -0.1 / +1.2 | 1 | 8 (0) | -0.2696 |
| grs · L2 committed | 93 | 23 | 0 | 67 | 0 | 2 | 1 | 31 | 2 | 3.5 | -2.4 / +1.5 | -0.4 / +1.1 | 0 | 8 (1) | -0.2880 |
| grs · L2 chosen | 93 | 26 | 0 | 65 | 1 | 0 | 1 | 43 | 4 | 3.6 | -2.4 / +2.0 | -0.4 / +1.1 | 0 | 8 (1) | -0.2687 |
| ind · L1 committed | 103 | 38 | 5 | 47 | 0 | 3 | 10 | 61 | 7 | 3.6 | -1.9 / +1.5 | +0.1 / +1.0 | 7 | 17 (5) | -0.0721 |
| ind · L2 committed | 103 | 33 | 4 | 56 | 0 | 2 | 8 | 62 | 12 | 4.0 | -1.8 / +1.5 | +0.1 / +1.0 | 8 | 17 (3) | -0.2271 |
| ind · L2 chosen | 103 | 39 | 2 | 48 | 1 | 5 | 8 | 74 | 16 | 4.2 | -1.8 / +2.0 | +0.1 / +1.0 | 3 | 17 (3) | -0.1782 |

### Acceptance (§5), evaluation pool, L2 chosen against L1 committed

| bar | value | bar | met |
|---|---|---|---|
| preserved ≥ L1 | 137 | ≥ 127 | **yes** |
| merged ≤ L1 | 150 | ≤ 159 | **yes** |
| false clips ≤ L1 + 2 | 48 | ≤ 31 | **no** |
| dead time per rally ≤ 1.1 × L1 | 4.43 s | ≤ 4.19 s | **no** |
| objective > L2 committed | -0.1216 | > -0.1512 | **yes** |

By recording group (evaluation pool; L1 committed → L2 chosen): **8 of 11 groups** preserve at least as many rallies under L2 chosen.

| group (recordings) | preserved | merged | false clips | missed |
|---|---|---|---|---|
| bch_ele_ovc_land_self_02 (5) | 40 → 44 | 42 → 37 | 12 → 16 | 6 → 5 |
| bch_ele_sun_land_self_01 (1) | 10 → 9 | 0 → 0 | 3 → 3 | 3 → 3 |
| bch_ele_sun_port_self_03 (1) | 9 → 13 | 2 → 0 | 2 → 5 | 0 → 0 |
| bch_gnd_ovc_land_self_01 (1) | 6 → 6 | 0 → 0 | 3 → 4 | 0 → 0 |
| grs_ele_dusk_port_self_03 (1) | 1 → 1 | 35 → 34 | 0 → 0 | 0 → 1 |
| grs_ele_shade_land_self_02 (1) | 0 → 1 | 33 → 31 | 0 → 0 | 0 → 0 |
| grs_ele_sun_land_self_01 (2) | 23 → 24 | 0 → 0 | 2 → 4 | 0 → 0 |
| ind_ele_dim_land_self_04 (1) | 1 → 1 | 31 → 32 | 0 → 0 | 3 → 2 |
| ind_gnd_bright_land_self_01 (2) | 16 → 20 | 14 → 12 | 4 → 6 | 3 → 2 |
| ind_gnd_bright_port_self_03 (1) | 10 → 9 | 0 → 2 | 3 → 6 | 4 → 4 |
| ind_onl_bright_land_onl_01 (1) | 11 → 9 | 2 → 2 | 0 → 4 | 0 → 0 |

### The 449 marked rallies, each in one class (both pools)
- L1 committed: 449 = preserved 195 + clipped 35 + merged 186 + split 0 + partial 7 + missed 26; of these, 36 are missed-serve marks (S then N), 8 of them missed; excluded: 0 (every mark of the 26 recordings is in a pool).
- L2 committed: 449 = preserved 182 + clipped 31 + merged 204 + split 0 + partial 9 + missed 23; of these, 36 are missed-serve marks (S then N), 7 of them missed; excluded: 0 (every mark of the 26 recordings is in a pool).
- L2 chosen: 449 = preserved 220 + clipped 24 + merged 168 + split 2 + partial 12 + missed 23; of these, 36 are missed-serve marks (S then N), 7 of them missed; excluded: 0 (every mark of the 26 recordings is in a pool).

### The grid on the tune pool under the new objective (top of 144; the full table is in `search/report.json`)

| rank | candidate | objective | preserved | merged | false | dead s/rally |
|---|---|---|---|---|---|---|
| 1 | join 0, postroll 1, preroll 2, min clip 1.5 | 0.4025 | 83 | 18 | 14 | 3.3 |
| 2 | join 0, postroll 1, preroll 2, min clip 2.6131 | 0.4025 | 83 | 18 | 14 | 3.3 |
| 3 | join 0, postroll 1, preroll 1.5, min clip 1.5 | 0.3928 | 81 | 16 | 15 | 3.0 |
| 4 | join 0, postroll 1, preroll 1.5, min clip 2.6131 | 0.3928 | 81 | 16 | 15 | 3.0 |
| 5 | join 0.25, postroll 1, preroll 1.5, min clip 1.5 | 0.3693 | 79 | 18 | 15 | 3.0 |
| 6 | join 0.25, postroll 1, preroll 1.5, min clip 2.6131 | 0.3693 | 79 | 18 | 15 | 3.0 |
| 7 | join 0.5, postroll 0.5, preroll 2, min clip 2.6131 | 0.3639 | 75 | 18 | 12 | 2.8 |
| 8 | join 0, postroll 0.5, preroll 2, min clip 2.6131 | 0.3567 | 75 | 16 | 14 | 2.8 |

The two best candidates tie exactly ({'minGapToMerge': 0, 'minSegmentLength': 1.5, 'postroll': 1, 'preroll': 2} and {'minGapToMerge': 0, 'minSegmentLength': 2.6131, 'postroll': 1, 'preroll': 2} give identical clips); the tie-break (earlier in grid order) named the first. Under this objective the first plan's choice (join 0, postroll 1.0, preroll 2.0, min clip 1.5) ranks **1 of 144** at 0.4025; the committed settings (preroll 2.0, postroll 0.5, join 1.3513, min clip 2.6131) rank 109 at 0.1944.

## 8. Decision

**Need data — no production change.** 3 of five bars are met on the evaluation pool; **false clips ≤ L1 + 2: 48 against ≤ 31**; **dead time per rally ≤ 1.1 × L1: 4.43 s against ≤ 4.19 s** fail. Tune pool: false 12 → 14, dead 2.8 → 3.3 s per rally. Development evidence, and a second look: the evaluation pool's first-plan result set this objective's false-clip price, so this result is weaker than a first look would be; every recording is in both models' training packages. No third plan on these pools without the owner.

**The finding: the price did not matter, the pools did.** The search chose the first plan's candidate again (join 0, postroll 1.0, preroll 2.0; rank 1 of 144 under the new objective, 0.4025 on the tune pool against 0.2754 for L1 committed), because on the tune pool that candidate buys 15 preserved rallies (68 → 83) for 2 false clips (12 → 14) — a good trade at any price the objective could put on a false clip. On the evaluation pool the same candidate costs 19 false clips (29 → 48) for 10 preserved rallies, spread over 10 of the 17 recordings (`bch_ele_ovc_land_self_02_v2` 3 → 5, `_v4` 4 → 7, `bch_ele_sun_port_self_03` 2 → 5, `ind_gnd_bright_port_self_03` 3 → 6, `ind_onl_bright_land_onl_01_v2` 0 → 4, …), not one outlier. The tune pool — three online beach recordings of one card, three Grace Qian grass recordings, three elevated indoor — has no self-shot beach, no ground-camera recording and one handheld; postroll 1.0 with join 0 is harmless there and costly where the evaluation pool's cameras are. So a second objective could not have changed the answer, and H1 was not refutable on this tune pool. What a third step would need is a tune pool that contains the cameras where the false clips arise — a re-split of the 26 by recording group, written before any search, which would make every earlier evaluation-pool number development-contaminated for that plan — or the product call of §8 of the first record (accept 19 more false clips over 17 recordings for 10 more preserved rallies and 9 fewer merged). Both are the owner's; this record makes neither. The committed settings rank 109 of 144 on the tune pool under this objective.

## 9. Test results

RallyLabTests: DeciderRetuneTests 8/8, ScoringExposureTests 8/8, TunerEligibilityTests 2/2 (18 of 18, 0 failures) on `exp/l2-decider-retune-r2`. Parity on the real passes: 52 of 52 within 0.2 s.
