---
id: EXP-20261031-l2-decider-retune
status: done — need data (two of five acceptance bars failed on the evaluation pool); no production change; the owner decides the next plan
created: 2026-10-31T18:39:45Z
updated: 2026-11-01T05:44:08Z
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
| Plan | `EXP-20261031-l2-decider-retune.plan.json` (configuration-item family CF-BSC-009, frozen), sha256 `c0f9d3bac865dc422fcf2cbf7c551d13eca02e44396c7d33ed6a1d37851ce2ec` |
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
3. The search: `RallyLab --project Scratch --retune-decider <plan.json> --out <report>/search` on the cached passes (no detector run): every candidate replayed on the tune pool only, ranked by the objective; the best is then replayed on the evaluation pool, beside L1 committed and L2 committed. One replay per candidate and recording (`EvidenceReplayer.decidedRallies`): the delivered (padded, joined) clips and, for each, its raw decided span from the same segmentation (a joined clip's is the union of what it joined) — never a second replay with the padding zeroed, which joins and filters differently.
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

Per pool, per surface, per recording group and per recording, for each condition: rallies, preserved, clipped, merged, split, partial (a clip touches it, none matches), missed, delivered clips, false clips, dead time per rally, padded start/end median offsets, raw start/end median offsets (each delivered clip's raw decided span, from the same replay), both-ends-within-1-s — every one of the 449 marked rallies in exactly one class. The tune-pool grid in full (`report.json`), top 40 in `report.md`.

## 7. Results (run 2026-10-31 → 2026-11-01; search on the cached passes with the parity-fixed replayer)

**Where.** `~/Movies/RallyLab/Reports/l2-retune-20261031/`: passes written by `run-passes.zsh` (`--passes-only`, started 2026-10-31T18:41Z, interrupted by a reboot at 21:27Z after 25 of 52 passes, resumed 21:36Z from the cache, finished 2026-11-01T00:28Z — the interrupted pass was re-run, none reused half-done); the search (`--retune-decider plan.json --out search`, 2026-11-01T05:28:48Z–2026-11-01T05:43:44Z, 144 candidates × 26 replays) from the build of `fix/replay-parity` at `995e610`. Plan sha256 in `search/report.json` = §3's `c0f9d3bac865dc42…`.

| file | sha256 |
|---|---|
| search/report.json | `9c5d3e4039e03f83e5f4e00d6f5f62aaeb09af62c8196fb16f14be5ac6e43629` |
| search/report.md | `559b21c83e2b19c321647cdf655bb03b885adf17cca0e127a83217d05a427276` |
| search/plan.json | `c0f9d3bac865dc422fcf2cbf7c551d13eca02e44396c7d33ed6a1d37851ce2ec` |
| search.log | `3c124c2ea7646a13093861d3896275c18948d8ba302cbc6653edaed8039d73a1` |
| passes/report.json | `657febce564bc07df3d78199f78a831485e20eade91ad18f10f90ce7b0cfba1e` |
| passes.log (resumed run) | `9ebf0cb23d4408a5dafbedb751ec3115316f0045c69b514734371a6729659a17` |
| passes.log.1 (before the reboot) | `3de295e8527928725dbfdcc8df6c2fb163b8e31266b42ee70c8341e2df1c4fa5` |
| run-passes.zsh | `74c81b9b38966048484ae5b6bb1f144e2646896416595274306ca678b2db1361` |

**Replay parity, and the fix it needed.** The first search build flagged 19 of 52 passes (replay at the committed settings differing from the pass's own clips by more than 0.2 s). Reading the pipeline against the replayer found the cause without a run: `VideoProcessor` gives the decider's sky-ball grace and the above-net rule the active track's last *raw* height, else the highest on-court detection; `EvidenceReplayer` gave it the *smoothed* trail point and nothing without one, so the 2 s grace instead of the 0.4 s end timeout moved rally ends. `EvidenceReplayer.ballHeight` now reconstructs the pipeline's input from the evidence: while there is an active track (a trail point) the selected candidate's raw point, else the trail point; with no active track — a lock retained through the drop grace included, whose candidate is still marked selected — the highest on-court detection, as the pipeline read. With it: **every pass matches** its replay within 0.2 s. Every number below is a replay, the committed-settings rows included, so the three conditions are comparable with each other and with the pipeline on 52 of 52 passes.

### Tune pool (settings chosen here; 9 recordings, 4 groups)

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| L1 committed | 128 | 68 | 25 | 27 | 0 | 1 | 7 | 116 | 12 | 2.8 | -1.0 / +0.2 | +0.9 / -0.2 | 26 | 0 (0) | 0.3457 |
| L2 committed | 128 | 61 | 25 | 35 | 0 | 1 | 6 | 111 | 11 | 2.9 | -1.0 / +0.2 | +0.9 / -0.2 | 21 | 0 (0) | 0.2588 |
| L2 chosen (join 0, postroll 1, preroll 2, min clip 1.5) | 128 | 83 | 19 | 18 | 0 | 2 | 6 | 125 | 14 | 3.3 | -1.1 / +0.6 | +0.9 / -0.3 | 20 | 0 (0) | 0.4845 |

By surface (tune):

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bch · L1 committed | 54 | 26 | 6 | 16 | 0 | 1 | 5 | 39 | 1 | 2.0 | -1.1 / +0.4 | +0.7 / -0.0 | 9 | 0 (0) | 0.2879 |
| bch · L2 committed | 54 | 22 | 7 | 19 | 0 | 1 | 5 | 38 | 1 | 2.1 | -1.1 / +0.5 | +0.5 / +0.0 | 7 | 0 (0) | 0.1857 |
| bch · L2 chosen | 54 | 33 | 6 | 9 | 0 | 1 | 5 | 44 | 1 | 2.2 | -1.5 / +0.8 | +0.4 / -0.1 | 6 | 0 (0) | 0.4784 |
| grs · L1 committed | 34 | 21 | 8 | 5 | 0 | 0 | 0 | 34 | 3 | 4.1 | -1.2 / +0.5 | +0.7 / +0.0 | 7 | 0 (0) | 0.4416 |
| grs · L2 committed | 34 | 16 | 8 | 10 | 0 | 0 | 0 | 31 | 3 | 4.4 | -1.2 / +0.1 | +0.8 / +0.0 | 5 | 0 (0) | 0.2150 |
| grs · L2 chosen | 34 | 23 | 5 | 6 | 0 | 0 | 0 | 34 | 3 | 4.8 | -1.3 / +0.8 | +0.7 / +0.0 | 5 | 0 (0) | 0.4720 |
| ind · L1 committed | 40 | 21 | 11 | 6 | 0 | 0 | 2 | 43 | 8 | 2.7 | -0.6 / -0.2 | +1.1 / -0.7 | 10 | 0 (0) | 0.3427 |
| ind · L2 committed | 40 | 23 | 10 | 6 | 0 | 0 | 1 | 42 | 7 | 2.9 | -0.8 / +0.1 | +1.1 / -0.4 | 9 | 0 (0) | 0.3953 |
| ind · L2 chosen | 40 | 27 | 8 | 3 | 0 | 1 | 1 | 47 | 10 | 3.3 | -0.8 / +0.4 | +1.1 / -0.5 | 9 | 0 (0) | 0.5036 |

### Evaluation pool (not used to choose; 17 recordings, 11 groups — development evidence)

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| L1 committed | 321 | 127 | 10 | 159 | 0 | 6 | 19 | 191 | 29 | 3.8 | -1.9 / +1.7 | +0.1 / +1.2 | 11 | 36 (8) | -0.0166 |
| L2 committed | 321 | 121 | 6 | 169 | 0 | 8 | 17 | 192 | 35 | 4.2 | -1.9 / +1.6 | +0.1 / +1.1 | 11 | 36 (7) | -0.0694 |
| L2 chosen (join 0, postroll 1, preroll 2, min clip 1.5) | 321 | 137 | 5 | 150 | 2 | 10 | 17 | 230 | 48 | 4.4 | -1.9 / +2.1 | +0.0 / +1.1 | 5 | 36 (7) | -0.0094 |

By surface (eval):

| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end padded | start/end raw | both ≤ 1 s | missed-serve marks (missed) | objective |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bch · L1 committed | 125 | 65 | 5 | 44 | 0 | 2 | 9 | 98 | 20 | 4.4 | -1.7 / +1.8 | +0.3 / +1.3 | 3 | 11 (3) | 0.1631 |
| bch · L2 committed | 125 | 65 | 2 | 46 | 0 | 4 | 8 | 99 | 21 | 4.8 | -1.8 / +1.7 | +0.2 / +1.2 | 3 | 11 (3) | 0.1391 |
| bch · L2 chosen | 125 | 72 | 3 | 37 | 0 | 5 | 8 | 113 | 28 | 5.2 | -1.8 / +2.1 | +0.2 / +1.2 | 2 | 11 (3) | 0.2039 |
| grs · L1 committed | 93 | 24 | 0 | 68 | 0 | 1 | 0 | 32 | 2 | 3.2 | -2.1 / +1.7 | -0.1 / +1.2 | 1 | 8 (0) | -0.2534 |
| grs · L2 committed | 93 | 23 | 0 | 67 | 0 | 2 | 1 | 31 | 2 | 3.5 | -2.4 / +1.5 | -0.4 / +1.1 | 0 | 8 (1) | -0.2719 |
| grs · L2 chosen | 93 | 26 | 0 | 65 | 1 | 0 | 1 | 43 | 4 | 3.6 | -2.4 / +2.0 | -0.4 / +1.1 | 0 | 8 (1) | -0.2365 |
| ind · L1 committed | 103 | 38 | 5 | 47 | 0 | 3 | 10 | 61 | 7 | 3.6 | -1.9 / +1.5 | +0.1 / +1.0 | 7 | 17 (5) | -0.0212 |
| ind · L2 committed | 103 | 33 | 4 | 56 | 0 | 2 | 8 | 62 | 12 | 4.0 | -1.8 / +1.5 | +0.1 / +1.0 | 8 | 17 (3) | -0.1398 |
| ind · L2 chosen | 103 | 39 | 2 | 48 | 1 | 5 | 8 | 74 | 16 | 4.2 | -1.8 / +2.0 | +0.1 / +1.0 | 3 | 17 (3) | -0.0617 |

### Acceptance (§5), evaluation pool, L2 chosen against L1 committed

| bar | value | bar | met |
|---|---|---|---|
| preserved ≥ L1 | 137 | ≥ 127 | **yes** |
| merged ≤ L1 | 150 | ≤ 159 | **yes** |
| false clips ≤ L1 + 2 | 48 | ≤ 31 | **no** |
| dead time per rally ≤ 1.1 × L1 | 4.43 s | ≤ 4.19 s | **no** |
| objective > L2 committed | -0.0094 | > -0.0694 | **yes** |

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

### The grid on the tune pool (top of 144; the full table is in `search/report.json`)

| candidate | objective | preserved | merged | false | dead s/rally |
|---|---|---|---|---|---|
| join 0, postroll 1, preroll 2, min clip 1.5 | 0.4845 | 83 | 18 | 14 | 3.3 |
| join 0, postroll 1, preroll 2, min clip 2.6131 | 0.4845 | 83 | 18 | 14 | 3.3 |
| join 0, postroll 1, preroll 1.5, min clip 1.5 | 0.4807 | 81 | 16 | 15 | 3.0 |
| join 0, postroll 1, preroll 1.5, min clip 2.6131 | 0.4807 | 81 | 16 | 15 | 3.0 |
| join 0.25, postroll 1, preroll 1.5, min clip 1.5 | 0.4572 | 79 | 18 | 15 | 3.0 |
| join 0.25, postroll 1, preroll 1.5, min clip 2.6131 | 0.4572 | 79 | 18 | 15 | 3.0 |
| join 0, postroll 0.5, preroll 1, min clip 2.6131 | 0.4486 | 70 | 6 | 16 | 2.1 |
| join 0, postroll 0.5, preroll 1, min clip 1.5 | 0.4393 | 70 | 6 | 20 | 2.2 |

The two best candidates tie exactly ({'minGapToMerge': 0, 'minSegmentLength': 1.5, 'postroll': 1, 'preroll': 2} and {'minGapToMerge': 0, 'minSegmentLength': 2.6131, 'postroll': 1, 'preroll': 2} give identical clips), so the tie-break (earlier in grid order) named the first; a change would keep the committed value of the knob that made no difference. The committed settings are a grid point (preroll 2.0, postroll 0.5, join 1.3513, min clip 2.6131): objective on tune 0.2588, the L2-committed row above.

## 8. Decision

**Need data — no production change.** 3 of five bars are met on the evaluation pool; **false clips ≤ L1 + 2: 48 against ≤ 31**; **dead time per rally ≤ 1.1 × L1: 4.43 s against ≤ 4.19 s** fail. The chosen settings buy preservation and fewer merges and pay in clips that touch no rally and in dead time — on the tune pool too (false 12 → 14, dead 2.8 → 3.3 s), so the search was not misled by the pool: the objective's false-clip cost (0.25 of a rally) weighs false clips lighter than the acceptance bar (+2) does, and the two were written to disagree. That is a methodology finding: a next plan should price false clips in the objective at the bar's rate, or drop the bar.

What the owner can decide with this: (a) keep PR #110 held and L1's committed settings as they are; (b) authorise a second plan on the same cached passes — candidates between the committed and the chosen settings (join 0.25–0.5 with postroll 0.5–0.75), or a second stage on `endTimeout`/`skyBallTimeout`, with the false-clip cost raised to match the bar — a replay-only run, minutes, no detector pass; (c) accept the trade-off explicitly (more preserved rallies and fewer merges for 19 more false clips over 17 recordings) as a product call, which this record does not make. Development evidence throughout: every recording is in both models' training packages and was scored in the diagnostic.

## 9. Test results

`RallyLabTests/DeciderRetuneTests` 8/8 on `fix/replay-parity` (the 7 of PR #121 plus `testBallHeightFollowsThePipelinesOrder`, with the retained-lock fixture; `testEveryRallyLandsInOneClass` extended with the missed-serve mark class); `ScoringExposureTests` 7/7 and `ReservationAndExposureTests` 28/28 on PR #120. Parity on the real passes: 52 of 52 within 0.2 s after the fix (19 of 52 before it).
