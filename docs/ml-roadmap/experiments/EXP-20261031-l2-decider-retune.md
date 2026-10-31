---
id: EXP-20261031-l2-decider-retune
status: planned — plan frozen, passes authorised; the search runs on the cached passes once this record is on its PR; results are development evidence, no production change until the owner approves them
created: 2026-10-31T18:39:45Z
updated: 2026-10-31T18:39:45Z
decision: owner decisions 2026-10-31 §2 (bounded L2 decider retune on eligible development tune data only) and §3 (model-specific scoring ledger rows, PR #120); D-002, D-017 honoured; D-001 (the FSM decider is the benchmark and fallback)
roadmap_phase: L2 ship decision (PR #110 held)
pr: feat/l2-decider-retune (stacked on PR #120)
issue: n/a
---

# EXP-20261031-l2-decider-retune — a bounded retune of the decider's joining and padding for the L2 detector

**Status: planned.** Written before the search runs. The plan file beside this record, `EXP-20261031-l2-decider-retune.plan.json` (sha256 `c0f9d3bac865dc422fcf2cbf7c551d13eca02e44396c7d33ed6a1d37851ce2ec`), is what `RallyLab --retune-decider` reads; the command copies it into its output folder and writes its hash into `report.json`, so the results can be checked against this text.

## 0. Why

The L1-versus-L2 diagnostic (§2 below) shows L2 at the committed decider settings misses 3 fewer rallies than L1 but turns 11 fewer into clean one-to-one clips, because 7 more clips merge neighbouring rallies and 5 more touch no rally. The decider's joining and padding were tuned for L1 (2026-06-14 / 2026-10-11); L2's denser in-rally detections (+6 %) keep the decision open longer, and two rallies closer than preroll + postroll + join gap (2.0 + 0.5 + 1.35 = 3.85 s) are delivered as one clip. The owner's direction: *"Start with the suspected joining and padding interaction. Do not change detector weights, dataset, net model or tracking architecture."*

## 1. Hypothesis

**H1.** With the decider's joining and padding chosen for L2 on the tune pool, L2 on the evaluation pool preserves at least as many marked rallies as L1 at its committed settings, with no more merged rallies, no more than two more false clips, and no more than 10 % more dead time per rally — and a higher objective than L2 at the committed settings. Each clause is an acceptance criterion (§5); any one failing means *need data*, not promotion.

**Not claimed.** Generalisation. Every recording here is in both models' training packages and was scored in the diagnostic; the evaluation pool was not used to choose settings, but it is development evidence. The protected holdouts stay untouched (owner §5).

## 2. Baseline, frozen: the L1-versus-L2 pipeline diagnostic (2026-10-31)

Report folder `~/Movies/RallyLab/Reports/l1l2-diag-20261031/` (not in git; durable copies are the owner's call — see the cache inventory, owner §5). SHA-256 of its files as frozen here:

| file | sha256 |
|---|---|
| README.md | `a0f27b2a01a7fada4ce9d2912781b7c2123c8cf88b7d37e2ef3d9057870f8d1a` |
| diag2-Scratch-scratch_768_1014-20261014-2002.log (L1 pass) | `fcf6ffb42ae87ae7404a4a19611580d48774978e7ca439ad57c34961c00d1c20` |
| diag2-Scratch-l2_scratch_768_color_s20261021-20261030-1514.log (L2 pass) | `bf6a1c045a7d90e56ca4b333e0372f266024c066cf063362705ab5de11a90820` |
| l1l2-diag2.zsh / l1l2-diag2.out | `c7dcf96b354e0b3bcec55944cadfdb3abe6d10c022b0c0b6fea6e048266b7cf0` / `6f0d719c699beaf01a10a94a548a15bae139ec11c06954ef93cc9eb7a6a632bc` |
| diag-files.txt (the 26 footage files: sha256, size, path) | `224f1c0370dd1e0574c0731dfb753e3562adc4df23679c2b0a930c70febca7a4` |
| diag2-samples.json / diag2-truthstats.json | `fd91c95a828759bb182cf97ed4f71cce5617fde1c24d3ecd7e81868ba3cd5f57` / `8b2c6d119387f211817e9841ac02d017a482dbc583b8cd81626e12fa8bcebd9c` |

What it measured: `RallyLab --project Scratch --score-rallies <26> --heat <model> --heat-only`, committed settings (preroll 2.0 s, postroll 0.5 s, join ≤ 1.3513 s, minSegmentLength 2.6131 s, window every 5 frames), L1 = `Scratch-scratch_768_1014-20261014-2002` (canonical digest `09620ab77519bd9d`, the bundled `ball_heat` of the phase-0 baseline), L2 = `Scratch-l2_scratch_768_color_s20261021-20261030-1514` (`8cb1bbca0c2729a8`), 26 recordings, 449 marked rallies, local SHA-256-verified copies of the footage.

| | found (IoU ≥ 0.3, 1:1) | missed | false clips | merged clips | split | both ends within 1 s | start / end median |
|---|---|---|---|---|---|---|---|
| L1 | 246 | 26 | 41 | 31 | 0 | 37 | −1.6 s / +1.3 s |
| L2 | 235 | 23 | 46 | 38 | 0 | 32 | −1.6 s / +1.3 s |

Beach 110 → 107 found, grass 55 → 50, indoor 81 → 78 (misses 12 → 9 indoor; false 15 → 19 indoor). Dead-time detections 0.272 → 0.284 per sample (+4 %), in-rally 0.764 → 0.813 (+6 %). The diagnostic's own replay grid: at join 0 the L2 deficit shrinks (281 vs 286 found, false 59 = 59, merged 36 vs 38); at preroll 0.5 / postroll 0.5 / join 0 L2 is ahead (363 vs 361 found, within-1-s 94 vs 84) — the reason this experiment starts with joining and padding. Three recordings are one clip for the whole video under both models (`bch_ele_ovc_land_self_02_v3`, `grs_ele_shade_land_self_02`, `ind_ele_dim_land_self_04`; `grs_ele_dusk_port_self_03_v2` nearly so): 138 of the 449 rallies, unchanged by the detector.

**Exposure-ledger gap, identified retrospectively (owner §3).** The ledger's 26 `rally_scoring` rows for these recordings (ref `--score-rallies`, date `2026-10-30`, note `ball model ball_rallylab_960 + multi-frame`) were written by the first, aborted attempt on 2026-10-30; the two passes of 2026-10-31 (L1 03:19–06:17 UTC, L2 06:17–09:06 UTC) were dropped as duplicates of them, so neither pass has a row and no row names either model. PR #120 makes every later run record the model and its settings; the passes of this experiment are recorded that way. Retrospective rows for the two diagnostic passes are proposed in PR #120 for the owner's approval and are not written.

## 3. Inputs (frozen)

| Input | Value |
|---|---|
| Code SHA | the head of `feat/l2-decider-retune` that holds `RallyLab/DeciderRetune.swift` and this record — recorded in §7 when the passes run; the binary is built from it |
| Plan | `EXP-20261031-l2-decider-retune.plan.json`, sha256 `c0f9d3bac865dc422fcf2cbf7c551d13eca02e44396c7d33ed6a1d37851ce2ec` |
| Dataset manifest SHA-256 | `manifests/manifest.json` `05b8bc4feb279a37812e0609bf81c8c7f462c20de475f6b57944f2ba32ac53de` (written 2026-10-25); `project.json` `65243bca59895a7e…`; `validation.json` `6d160a1ac00254a0…` (9 tune, 5 holdout, 16 lineageHoldout, 0 finalTest) |
| Tune pool (settings chosen here) | the 9 `tune` recordings of validation.json, 4 recording groups: `bch_onl_ovc_land_onl_02` card (3, one uploader), Grace Qian's 3 grass recordings (incl. the handheld `grs_hnd_shade_port_self_02`), `ind_ele_bright_land_self_01`, the `ind_ele_dim_land_self_02` card (2) — 141 marked rallies |
| Evaluation pool (not used to choose) | the other 17 diagnostic recordings — 12 `train`, 1 `dev_val` (`bch_ele_sun_port_self_03`), and `bch_ele_ovc_land_self_02_v4`, `ind_gnd_bright_land_self_01_v2` (marked after the manifest was written; `train`) — 11 recording groups, 308 marked rallies |
| Pool checks (the command refuses otherwise) | no name in the final-test reservation or the lineage-withheld closure (lineage holdout 16 + legacy holdout 5 + aliases: 21); every rally marked; no recording group in both pools (groups = clip card ∪ uploader ∪ alias group ∪ confirmed source/session/venue, transitively) |
| Not used | the 5 legacy-holdout recordings (the old tuner's "holdout"; owner: not to be used simply because the tuner calls it one) and the 16 lineage holdouts — the whole withheld closure of 21 (no further aliases in this project) — never read |
| Label set | each recording's `.rallylabels.json` whole-video rally marks (legacy marks; `LabeledRally` times) — 449 rallies, the diagnostic's truth |
| Control | L1 `Scratch-scratch_768_1014-20261014-2002` (`09620ab77519bd9d`) at the committed settings; also L2 at the committed settings |
| Treatment | L2 `Scratch-l2_scratch_768_color_s20261021-20261030-1514` (`8cb1bbca0c2729a8`) at the settings chosen on the tune pool |
| Pipeline config | `ProcessorConfig()` as committed, `heatmapOnly`, rotation not applied, camera position applied per recording (`withCamera(of:)`), `minRallySec` 1.1653; detection stage untouched (no weights, dataset, net model or tracker change) |
| Candidate grid (144) | preroll {0.5, 1.0, 1.5, 2.0} × postroll {0.25, 0.5, 1.0} × minGapToMerge {0, 0.25, 0.5, 0.75, 1.0, 1.3513} × minSegmentLength {1.5, 2.6131}; every other setting as committed. Deterministic, exhaustive; ties go to the earlier candidate in grid order. No second stage (endTimeout, startBuffer, skyBallTimeout) without a second approved plan |
| Objective (chosen before the search) | per rally: (preserved − 0.5 × merged − 0.25 × false clips) / rallies − 0.25 × dead time / rally time. Preserved = matched one-to-one (IoU ≥ 0.3) with ≥ 95 % of the rally inside the delivered clips. A merged rally is worth half (the clip is watchable, needs splitting), a false clip costs a quarter of a rally (deletable), dead time at the tuner's rate (owner 2026-10-11: a second of rally lost ≈ 4 s of dead clip) |
| Compute | this Mac; the detector runs once per recording per model (≈ 1.25 × real time; the diagnostic took 2 h 58 m for L1 and 2 h 49 m for L2 over the 26), cached as `pipeline_tuning/evidence/<name>__<key>.evidence`; every candidate is a replay (milliseconds) |

## 4. Procedure

1. Footage: the 26 SHA-256-verified local copies of the diagnostic (`~/Movies/RallyLab/Cache/diag-20261030/`, hashes in `diag-files.txt`), the project's footage links pointed at them for the run and restored afterwards, as `l1l2-diag2.zsh` did (the share over Wi-Fi is too slow and drops).
2. Passes, recorded first: `RallyLab --project Scratch --retune-decider <plan.json> --out <report>/passes --passes-only` — one `rally_scoring` row per recording per model with the model-named ref (`--retune-decider EXP-20261031-l2-decider-retune heat=<model>@<digest> … config=<fingerprint>`, PR #120), then the detector over the 26 for L2 and for L1. The replay at the committed settings is checked against each pass's own clips (0.2 s); any mismatch is listed in the report.
3. The search: `RallyLab --project Scratch --retune-decider <plan.json> --out <report>/search` on the cached passes (no detector run): every candidate replayed on the tune pool only, ranked by the objective; the best is then replayed on the evaluation pool, beside L1 committed and L2 committed.
4. Report: `report.json` (every recording × condition account, the full grid on the tune pool, groups, splits, refs, digests, plan hash) and `report.md`; both hashed into §7.

## 5. Acceptance criteria (set before the search)

On the **evaluation pool**, L2 at the chosen settings against L1 at the committed settings:

- [ ] preserved rallies ≥ L1's
- [ ] merged rallies ≤ L1's
- [ ] false clips ≤ L1's + 2
- [ ] dead time per rally ≤ 1.1 × L1's
- [ ] objective > L2 at the committed settings (the retune helped L2 where it was not chosen)
- [ ] by recording group (11): the number of groups where L2-chosen preserves at least as many rallies as L1, reported; no bar (1–2 videos a group)

All five bars met → *keep as a candidate*: the owner decides whether this development evidence suffices for PR #110 or whether a holdout evaluation (owner-gated) comes first. Any bar failed → *need data*: no production change; the report says which bar and by how much, and the next step is the owner's.

## 6. What is reported (owner §2)

Per pool, per surface, per recording group and per recording, for each condition: rallies, preserved, clipped, merged, split, partial (a clip touches it, none matches), missed, delivered clips, false clips, dead time per rally, padded start/end median offsets, raw (unpadded decision) start/end median offsets, both-ends-within-1-s — every one of the 449 marked rallies in exactly one class. The tune-pool grid in full (`report.json`), top 40 in `report.md`.

## 7. Results

Not run.

## 8. Decision

Pending.

## 9. Test results

`RallyLabTests/DeciderRetuneTests` (6): one class per rally on a constructed case (preserved, clipped, two merged, split, missed, a false clip, covered and dead time to the second, boundary errors over the scorer's matches); the objective as written and its empty case; the grid as every combination in order and applied to the config; recording groups by card / uploader (trimmed) / alias group / source; plan refusals (group in both pools, withheld, final test, duplicate name, empty pool); the plan file round-trips. `ScoringExposureTests` (7) and `ReservationAndExposureTests` (28) on PR #120.
