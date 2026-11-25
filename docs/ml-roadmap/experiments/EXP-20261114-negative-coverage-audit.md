---
id: EXP-20261114-negative-coverage-audit
status: pilot drawn and frozen (2026-11-15T07:25Z); **no interval reviewed yet** — the review is the owner's; results are added below the line when it is done
created: 2026-11-15T07:26:43Z
updated: 2026-11-15T20:09:22Z
decision: D-038 (owner authorisation of 2026-11-14, section "Negative-coverage audit"); D-001, D-002, D-021, D-028, D-030, D-032, D-037
roadmap_phase: learned temporal rally classifier — data readiness (gates G6 and G7 of EXP-20261103-temporal-rally-classifier-prereg)
pr: PR #183 (protocol, inventory, draw, report); PR #186 (the Audit tab, the record and its save operation); PR #187 (exporter and validator under `rally_activity_truth_v2`)
issue: n/a
---

# EXP-20261114-negative-coverage-audit — a person's second look at every unmarked interval of the continuous recordings of `rc-v1-20261112`

A verification of labels, not a model experiment. No model is trained, run or scored; the reviewer sees no ball path and no pipeline output. Everything above "Results" is fixed before any interval is reviewed.

## Question

The dataset's negatives are the time between marks on recordings whose marking pass the owner declared complete. Is that time free of rallies and served balls? The owner, 2026-11-14: "The owner does not waive negative-label verification." "Only explicitly reviewed clean intervals or eligible Stage 1 verified coverage may supply trusted negatives under the adopted G7 policy."

## What is frozen

| Item | Value |
|---|---|
| Protocol | [RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md](../RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md), SHA-256 `bdb28442173588d25581ce904a78005e1c3b4d88f880864ca5ae5182c1293eab`, at commit `ff1cb43` (PR #183; Codex review of that commit: no findings) |
| Dataset | `rc-v1-20261112` — manifest SHA-256 `eaa95c08d2fd010b…`, digest `1b1e68986311e7ce…`; frozen folds file SHA-256 `b5e4b4ef3c6ce1cd…` |
| Inventory | built 2026-11-15T07:23Z from metadata only (no video opened): 31 eligible continuous recordings in 18 groups, 402 unmarked intervals, 6,040.5 s; 18 dataset recordings left out, all edited; every marks file equal to the one the dataset was exported from. SHA-256 `6c50ddab3f1c1495…` |
| Withheld closure refused | 24 names, 8 confirmed sourceIds, 45 fingerprints, and the project's closure as it is now |
| Pilot draw | `20261115-072552` — `Scratch/manifests/coverage-audit/20261115-072552-draw.json`, SHA-256 `e01f685b3052b31c6ad01f27a5f90560feb12c340fc9431e7b917a74cc1553bc`; procedure `coverage_draw_v2`, seed 20261114 |
| Criterion (in the draw file) | *n* = 127 rally marks. **Pass** when the exact one-sided 90 % upper bound on *m / n* is ≤ 5 % — at most *m* = 2 missed rallies or missed serves — **and** no recording holds more than 2. Evaluated only when every interval, every repeat and every resolution is recorded |
| How the tools read a look (one point stricter than the protocol) | The protocol (§7) requires a `clean` verdict to have played its whole interval. The tools that apply it — RallyLab's Audit tab and `coverage_audit_report.py` — require it of **every look that counts**: a first look, repeat or resolution that gave findings before its interval had played whole keeps its findings, but the interval stays pending and the pilot `incomplete` until the look is finished. This can only delay an evaluation, never change the criterion; the protocol document is not edited (it remains SHA-256 `bdb28442…`). A repeat's method is read from who made it (the first reviewer after 24 h, or another person), interval by interval |

## The pilot sample

| Surface | Recording | Group | Fold | Split | Camera | Rally marks | Intervals | Unmarked s | Repeat set |
|---|---|---|---|---|---|---|---|---|---|
| beach | `bch_ele_ovc_land_self_02_v2` | `bch_ele_ovc_land_self_02` | 4 | train | End line, elevated (stands/tripod 2m+) | 12 | 14 | 207 | 3 |
| beach | `bch_extra_self_04` | `bch_extra_self_04` | 3 | train | Extra | 11 | 13 | 208 | 3 |
| beach | `bch_extra_self_12` | `bch_extra_self_12` | 1 | train | Extra | 10 | 12 | 200 | 3 |
| beach | `bch_gnd_ovc_land_self_01` | `bch_gnd_ovc_land_self_01` | 1 | train | End line, ground level | 7 | 8 | 231 | 2 |
| grass | `grs_ele_sun_land_self_01_v2` | `grs_ele_sun_land_self_01_v2` | 2 | train | End line, elevated (stands/tripod 2m+) | 12 | 13 | 227 | 3 |
| grass | `grs_extra_self_04` | `grs_extra_self_04` | 4 | train | Extra | 9 | 12 | 233 | 3 |
| grass | `grs_gnd_sun_land_self_01` | `grs_gnd_sun_land_self_01` | 3 | train | End line, ground level | 11 | 12 | 238 | 3 |
| grass | `grs_hnd_shade_port_self_02` | `grs_hnd_shade_port_self_02` | 0 | tune | Handheld / corner | 12 | 13 | 160 | 3 |
| indoor | `ind_extra_self_07` | `ind_extra_self_07` | 4 | train | Extra | 8 | 10 | 239 | 2 |
| indoor | `ind_gnd_bright_port_self_03` | `ind_gnd_bright_port_self_03` | 3 | train | End line, ground level | 14 | 15 | 201 | 3 |
| indoor | `ind_onl_bright_land_onl_01` | `ind_onl_bright_land_onl_01` | 0 | train | Online (CC-licensed) | 12 | 17 | 171 | 4 |
| indoor | `ind_tri_dim_port_self_02` | `ind_tri_dim_port_self_02` | 4 | train | Tripod / corner | 9 | 11 | 193 | 3 |

Twelve recordings in twelve groups: beach 4 of its 4 eligible groups, grass 4 of 6, indoor 4 of 8. **150 intervals, 2,508.5 s of unmarked video, 127 rally marks; repeat set 35 intervals** (a fifth of each recording's intervals, at least two), plus every interval the first look leaves `uncertain`.

Left for stage 2 (19 recordings, 252 intervals, 3,532.0 s): `bch_ele_ovc_land_self_02`, `bch_ele_ovc_land_self_02_v4`, `bch_onl_sun_land_onl_01`, `bch_onl_sun_land_onl_01_v2`, `bch_sid_sun_land_self_03`, `grs_ele_dusk_port_self_03`, `grs_ele_sun_land_self_01_v3`, `grs_onl_shade_land_onl_02`, `grs_onl_sun_land_onl_01`, `grs_sid_shade_land_self_02_v2`, `ind_ele_dim_land_self_02`, `ind_ele_dim_land_self_02_v2`, `ind_extra_self_08`, `ind_gnd_bright_land_self_01`, `ind_gnd_bright_land_self_01_v2`, `ind_onl_bright_land_onl_01_v2`, `ind_onl_bright_land_onl_01_v3`, `ind_onl_bright_land_onl_01_v4`, `ind_tri_bright_land_self_01_v3`.

## The owner's workload

| Step | What | Video time | At 2× |
|---|---|---|---|
| Pilot, first look | 150 intervals of 12 recordings, each played whole with 1 s of context either side | 41.8 min + ≈ 5 min context | ≈ 25 min of playback, plus keystrokes and notes: **about 40 minutes** |
| Pilot, blind repeat | 35 intervals (more if any are left uncertain), by a second person or by the owner at least 24 hours after the first look | ≈ 9.8 min + context | **about 10 minutes**, a day later |
| Resolutions | only where the two looks disagree | — | minutes |
| Stage 2, if the pilot passes | 252 intervals of 19 recordings, then its repeat set | 58.9 min + context | **about 1 hour**, and ≈ 15 minutes a day later |

The repeat by the same reviewer is reported as a repeat, never as independent agreement (protocol §6).

## What happens with the result

- **Incomplete** until every pilot interval, repeat and resolution is recorded; no pass or fail is read before that.
- **Pass:** stage 2 is listed (`coverage_audit_draw.py --stage2`, which evaluates the pilot itself) and reviewed the same way. The pass certifies no recording that was not reviewed.
- **Fail:** the findings go to the marking pass for corrective labeling; the changed intervals are audited again under a new draw with its reason; no negative is used meanwhile.
- Either way the dataset `rc-v1-20261112` and its folds file are not touched. Trusted negatives arrive with a new export under `rally_activity_truth_v2`, in which a step is `NON_RALLY` only inside a reviewed-clean interval. G6 is then counted over trusted negatives: at least 17 of the 25 groups, two in every fold — only 18 groups hold a continuous recording, and fold 0 holds exactly two of them, so at most one group may fall out and not from fold 0. A shortfall is reported, not waived.

## Results

Not yet. No interval has been reviewed.
