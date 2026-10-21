# Dataset audit — Scratch

Run 2026-10-21T18:53:12Z on manifest hashes project.json `65243bca59895a7e`, sessions `06ed23f06ccd23ce`.

**Result: no hard leak.**

| Severity | Count |
|---|---|
| hard | 0 |
| soft | 8 |
| info | 21 |

## Soft

- **CARD-SPLIT** — 4 videos with same clip card "bch_onl_ovc_land_onl_02" sit in dev_val + tune. `bch_onl_ovc_land_onl_02`, `bch_onl_ovc_land_onl_02_v2`, `bch_onl_ovc_land_onl_02_v3`, `bch_onl_ovc_land_onl_02_v4`
- **CARD-SPLIT** — 2 videos with same clip card "grs_onl_sun_land_onl_01" sit in dev_val + tune. `grs_onl_sun_land_onl_01`, `grs_onl_sun_land_onl_01_v2`
- **CARD-SPLIT** — 3 videos with same clip card "ind_ele_dim_land_self_02" sit in dev_val + tune. `ind_ele_dim_land_self_02`, `ind_ele_dim_land_self_02_v2`, `ind_ele_dim_land_self_02_v3`
- **RESERVED-UPLOADER-IN-TRAIN** — bch_onl_sun_land_onl_03 (legacy_holdout) shares uploader "Dianne Gan" with train videos; confirm it is a different venue/session. `bch_onl_sun_land_onl_03`
- **RESERVED-UPLOADER-IN-TRAIN** — bch_onl_sun_land_onl_03_v2 (legacy_holdout) shares uploader "Dianne Gan" with train videos; confirm it is a different venue/session. `bch_onl_sun_land_onl_03_v2`
- **UPLOADER-SPLIT** — 4 videos with same uploader "Blake Seegers" sit in dev_val + tune. `bch_onl_ovc_land_onl_02`, `bch_onl_ovc_land_onl_02_v2`, `bch_onl_ovc_land_onl_02_v3`, `bch_onl_ovc_land_onl_02_v4`
- **UPLOADER-SPLIT** — 4 videos with same uploader "Dianne Gan" sit in legacy_holdout + train. `bch_onl_sun_land_onl_03`, `bch_onl_sun_land_onl_03_v2`, `grs_onl_sun_land_onl_04`, `grs_sid_shade_land_self_02_v2`
- **UPLOADER-SPLIT** — 5 videos with same uploader "Grace Qian" sit in dev_val + legacy_holdout + tune. `grs_hnd_shade_port_self_02`, `grs_onl_dusk_land_onl_03`, `grs_onl_shade_land_onl_02`, `grs_onl_sun_land_onl_01`, `grs_onl_sun_land_onl_01_v2`

## Info

- **FINAL-TEST-NONE** — Every video has recorded exposure; an independent final test needs new recordings.
- **LINEAGE-HOLDOUT** — bch_extra_self_05: historical exposure: pre_tracking; no reviewed frames. Results on it are valid only for model lineages trained after the D-017 cut-over. `bch_extra_self_05`
- **LINEAGE-HOLDOUT** — bch_extra_self_10: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `bch_extra_self_10`
- **LINEAGE-HOLDOUT** — bch_extra_self_18: historical exposure: pre_tracking; no reviewed frames. Results on it are valid only for model lineages trained after the D-017 cut-over. `bch_extra_self_18`
- **LINEAGE-HOLDOUT** — bch_extra_self_29: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `bch_extra_self_29`
- **LINEAGE-HOLDOUT** — bch_extra_self_30: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `bch_extra_self_30`
- **LINEAGE-HOLDOUT** — bch_extra_self_31: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `bch_extra_self_31`
- **LINEAGE-HOLDOUT** — grs_extra_self_02: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_02`
- **LINEAGE-HOLDOUT** — grs_extra_self_06: historical exposure: pre_tracking; no reviewed frames. Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_06`
- **LINEAGE-HOLDOUT** — grs_extra_self_07: historical exposure: pre_tracking; no reviewed frames. Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_07`
- **LINEAGE-HOLDOUT** — grs_extra_self_12: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_12`
- **LINEAGE-HOLDOUT** — grs_extra_self_14: historical exposure: pre_tracking; no reviewed frames. Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_14`
- **LINEAGE-HOLDOUT** — grs_extra_self_15: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_15`
- **LINEAGE-HOLDOUT** — grs_extra_self_20: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_20`
- **LINEAGE-HOLDOUT** — grs_extra_self_21: historical exposure: pre_tracking; no reviewed frames. Results on it are valid only for model lineages trained after the D-017 cut-over. `grs_extra_self_21`
- **LINEAGE-HOLDOUT** — ind_extra_self_06: historical exposure: pre_tracking; no reviewed frames; stored under images/train (excluded from packages by name). Results on it are valid only for model lineages trained after the D-017 cut-over. `ind_extra_self_06`
- **LINEAGE-HOLDOUT** — ind_extra_self_09: historical exposure: pre_tracking; no reviewed frames. Results on it are valid only for model lineages trained after the D-017 cut-over. `ind_extra_self_09`
- **LINEAGE-HOLDOUT-SUMMARY** — 16 lineage-holdout recording(s): beach 6, grass 8, indoor 2; 0 carry reviewed frames, 0 have rally marks; unreviewed machine tracks are not ground truth. Historically exposed: not an untouched final test. (16 videos, see audit.json)
- **LINEAGE-UNKNOWN-RELATIONS** — 144 train/dev recording(s) (76 own files, 68 links) have neither a confirmed venue nor session: their relation to the lineage holdout is unknown, not cleared. Only the card/uploader checks cover them. (144 videos, see audit.json)
- **PROVENANCE-SOURCE** — 94 video(s) have no confirmed sourceId (94 carry a file fingerprint as a suggestion, 0 nothing). Confirm with `--set-provenance <video> --source-id <id>`. (94 videos, see audit.json)
- **PROVENANCE-VENUE** — 147 video(s) have no confirmed venueId and 149 no sessionId. Until set, grouping by venue is impossible and the uploader/card checks above are the only guard. (147 videos, see audit.json)
