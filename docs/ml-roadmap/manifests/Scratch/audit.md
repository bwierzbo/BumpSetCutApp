# Dataset audit — Scratch

Run 2026-10-21T03:40:38Z on manifest hashes project.json `8404d1c0d97f10a4`, sessions `06ed23f06ccd23ce`.

**Result: no hard leak.**

| Severity | Count |
|---|---|
| hard | 0 |
| soft | 8 |
| info | 3 |

## Soft

- **CARD-SPLIT** — 4 videos with same clip card "bch_onl_ovc_land_onl_02" sit in dev_val + tune. `bch_onl_ovc_land_onl_02`, `bch_onl_ovc_land_onl_02_v2`, `bch_onl_ovc_land_onl_02_v3`, `bch_onl_ovc_land_onl_02_v4`
- **CARD-SPLIT** — 2 videos with same clip card "bch_onl_sun_land_onl_03" sit in dev_val + legacy_holdout. `bch_onl_sun_land_onl_03`, `bch_onl_sun_land_onl_03_v2`
- **CARD-SPLIT** — 2 videos with same clip card "grs_onl_sun_land_onl_01" sit in dev_val + tune. `grs_onl_sun_land_onl_01`, `grs_onl_sun_land_onl_01_v2`
- **CARD-SPLIT** — 3 videos with same clip card "ind_ele_dim_land_self_02" sit in dev_val + tune. `ind_ele_dim_land_self_02`, `ind_ele_dim_land_self_02_v2`, `ind_ele_dim_land_self_02_v3`
- **RESERVED-UPLOADER-IN-TRAIN** — bch_onl_sun_land_onl_03 (legacy_holdout) shares uploader "Dianne Gan" with train videos; confirm it is a different venue/session. `bch_onl_sun_land_onl_03`
- **UPLOADER-SPLIT** — 4 videos with same uploader "Blake Seegers" sit in dev_val + tune. `bch_onl_ovc_land_onl_02`, `bch_onl_ovc_land_onl_02_v2`, `bch_onl_ovc_land_onl_02_v3`, `bch_onl_ovc_land_onl_02_v4`
- **UPLOADER-SPLIT** — 4 videos with same uploader "Dianne Gan" sit in dev_val + legacy_holdout + train. `bch_onl_sun_land_onl_03`, `bch_onl_sun_land_onl_03_v2`, `grs_onl_sun_land_onl_04`, `grs_sid_shade_land_self_02_v2`
- **UPLOADER-SPLIT** — 5 videos with same uploader "Grace Qian" sit in dev_val + legacy_holdout + tune. `grs_hnd_shade_port_self_02`, `grs_onl_dusk_land_onl_03`, `grs_onl_shade_land_onl_02`, `grs_onl_sun_land_onl_01`, `grs_onl_sun_land_onl_01_v2`

## Info

- **FINAL-TEST-CANDIDATE** — 7 video(s) have no recorded exposure and share no card, uploader or file with train. Owner decision: confirm venue/session, then list in validation.json `finalTest`. `bch_extra_self_05`, `bch_extra_self_18`, `grs_extra_self_06`, `grs_extra_self_07`, `grs_extra_self_14`, `grs_extra_self_21`, `ind_extra_self_09`
- **PROVENANCE-SOURCE** — 167 video(s) have no confirmed sourceId (167 carry a file fingerprint as a suggestion, 0 nothing). Confirm with `--set-provenance <video> --source-id <id>`. (167 videos, see audit.json)
- **PROVENANCE-VENUE** — 167 video(s) have no confirmed venueId and 167 no sessionId. Until set, grouping by venue is impossible and the uploader/card checks above are the only guard. (167 videos, see audit.json)
