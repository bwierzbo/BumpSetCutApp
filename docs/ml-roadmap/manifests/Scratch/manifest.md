# Dataset split manifest — Scratch

Created 2026-10-21T17:19:06Z by RallyLab 1.0 (2). Schema 1.

Hashes: project.json `65243bca59895a7e` · sessions/ `06ed23f06ccd23ce` · validation.json `4d4b4368ae3decad`

## Videos by split and surface

| Split | beach | grass | indoor | Total |
|---|---|---|---|---|
| train | 52 | 54 | 27 | 133 |
| dev_val | 2 | 1 | 1 | 4 |
| tune | 3 | 3 | 3 | 9 |
| legacy_holdout | 2 | 1 | 2 | 5 |
| final_test_candidate | 6 | 8 | 2 | 16 |
| final_test | 0 | 0 | 0 | 0 |

- **train** — Detector training (dataset split "train").
- **dev_val** — Development validation: dataset split "val" and not listed in pipeline_tuning/validation.json. Used for model selection; not unseen.
- **tune** — validation.json `tune`: pipeline settings are searched on these. Also in the detector's val split.
- **legacy_holdout** — validation.json `holdout`: frozen recordings (D-002) with recorded prior exposure (test-set scoring, tuner reports). Not an unseen final test.
- **final_test_candidate** — validation.json `finalTestCandidates`: provisional final-test recordings (D-015 §2). Protected exactly like final_test while venue/session provenance and prior exposure are verified; NOT yet the final test.
- **final_test** — validation.json `finalTest`: verified recordings with no recorded exposure, reserved until promotion. Excluded from packages, scoring and tuning.

## Exposure

| Kind | Videos | Artefacts |
|---|---|---|
| training_package | 94 | Scratch-multiframe-20261016-2018, Scratch-val-multiframe-20261016-1100 |
| test_set_scoring | 17 | Scratch-val-multiframe-20261016-1100 |
| pipeline_tuning_tune | 9 | pipeline_tuning/validation.json |
| pipeline_tuning_holdout | 5 | pipeline_tuning/validation.json |
| rally_scoring | 11 | pipeline_tuning/evidence |
| detector_evaluation | 0 |  |
| pre_tracking | 152 | session tracks (machine) |

Videos with no recorded exposure: 13 (bch_extra_self_23, bch_extra_self_24, bch_sid_sun_port_self_01, grs_extra_tester_03_v2, grs_extra_tester_03_v8, grs_gnd_shade_land_self_02, grs_hnd_sun_land_self_01_v2, grs_tri_sun_land_self_01_v2, ind_gnd_bright_land_self_01_v3, ind_hnd_bright_port_self_01, ind_hnd_dim_land_self_02_v2, ind_tri_bright_land_self_01, ind_tri_bright_land_self_01_v2)

## Provenance

| Field | confirmed | inferred from fingerprint | unknown |
|---|---|---|---|
| sourceId | 73 | 94 | 0 |
| sessionId | 18 | 0 | 149 |
| venueId | 20 | 0 | 147 |

## Videos

| Video | Split | Surface | Card | Card split | Uploader | sourceId | Exposure |
|---|---|---|---|---|---|---|---|
| bch_ele_ovc_land_self_02 | train | beach | bch_ele_ovc_land_self_02 | train | Alex | youtube:y_96TGH6LlY (confirmed) | pre_tracking, training_package |
| bch_ele_ovc_land_self_02_v2 | train | beach | bch_ele_ovc_land_self_02 | train | Beach Junkies | youtube:5bmSFq7edL0 (confirmed) | pre_tracking, training_package |
| bch_ele_ovc_land_self_02_v3 | train | beach | bch_ele_ovc_land_self_02 | train | Ben W | youtube:hoHwSypvTLo (confirmed) | pre_tracking, training_package |
| bch_ele_ovc_land_self_02_v4 | train | beach | bch_ele_ovc_land_self_02 | train | Beware Of Hamsters | youtube:u2wRqEJdEB4 (confirmed) | pre_tracking, training_package |
| bch_ele_ovc_land_self_02_v5 | train | beach | bch_ele_ovc_land_self_02 | train | Brandon Tarter | youtube:nGlB764XoME (confirmed) | pre_tracking, training_package |
| bch_ele_sun_land_self_01 | train | beach | bch_ele_sun_land_self_01 | train | — | file:f7f69c1611f8d0179cabee9044cfd24b62f341fd62008cdff81b56445f327338 (inferred_fingerprint) | pre_tracking, training_package |
| bch_ele_sun_port_self_03 | dev_val | beach | bch_ele_sun_port_self_03 | val |  Arbel Sports | youtube:hPG3FjkDe_8 (confirmed) | pre_tracking, test_set_scoring, training_package |
| bch_extra_self_01 | train | beach | bch_extra_self_01 | auto | — | file:7f4a2ebc8ef84e56bb8da3efdbb5e7a9c41afe7f21ec48e1174523801cdd3a58 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_02 | train | beach | bch_extra_self_02 | auto | — | file:e66a7b9d73859c90e0f79fd591d798dc5c0be2bcff4fa9fb1c18c92437fad5d3 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_03 | train | beach | bch_extra_self_03 | auto | — | file:b539b539db2726bc649b2fcc42b777921c9220662067f696bbe886357160c3ec (inferred_fingerprint) | pre_tracking |
| bch_extra_self_04 | train | beach | bch_extra_self_04 | auto | — | file:1ebb6279d5d4edfbb7a8094afe98d6290e1deeada01d60e069e3611e28df64ad (inferred_fingerprint) | pre_tracking |
| bch_extra_self_05 | final_test_candidate | beach | bch_extra_self_05 | auto | — | file:30ce89bf4182a96d7a5f0fbfc565939b50b9fdd9cfce7924b3c0a131d9de04f5 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_06 | train | beach | bch_extra_self_06 | auto | — | file:b842477a44883651c2d932fff47a8540e198cf6471448e52bf2b0b9c3324424b (inferred_fingerprint) | pre_tracking |
| bch_extra_self_07 | train | beach | bch_extra_self_07 | auto | — | file:a6c015b2cc1caaec1695b3f6396db90567e7d9e9bd0d961e4cee9bfd71875b54 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_08 | train | beach | bch_extra_self_08 | auto | — | file:7e424df8a69ac2dd61bb76d8b90a09b74d4d96c5dfc44b4faac304bb46c24c30 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_09 | train | beach | bch_extra_self_09 | auto | — | file:9d06491935e04c10bdfa043efcbc3e9105510a45ca6e757fe442a39609240c69 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_10 | final_test_candidate | beach | bch_extra_self_10 | auto | — | file:15b90949710691c7915085a1f4aeaca8df74ab97065cf5ef4713c3e3fff4ff61 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_11 | train | beach | bch_extra_self_11 | auto | — | file:203271a1bddd49d000fc4f8dceffce6ff2e18659b9632e17871f8d9cf694ff96 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_12 | train | beach | bch_extra_self_12 | auto | — | file:2e4d1e2005e12bfb87e6761787d30df70b4b191800cc336df03e3288a6d1657e (inferred_fingerprint) | pre_tracking |
| bch_extra_self_13 | train | beach | bch_extra_self_13 | auto | — | file:22a3f3f2a83a86214e0f6f54bf040da2301c3e09bf3d0b0056aded83985aef2c (inferred_fingerprint) | pre_tracking |
| bch_extra_self_14 | train | beach | bch_extra_self_14 | auto | — | file:0ee5c05d9b004ca2a62d99efd838f695370016adc7d1f5a21d9dacf32ed62487 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_15 | train | beach | bch_extra_self_15 | auto | — | file:3de4e1f05ce496363a6ba8ccc1eaf61b8a7bbc890f6b89209b197d0bb1e100ac (inferred_fingerprint) | pre_tracking |
| bch_extra_self_16 | train | beach | bch_extra_self_16 | auto | — | file:08a09953d74188fa48a42e0c275f4dcce0b171bbe53dba1b954608e130d9be29 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_17 | train | beach | bch_extra_self_17 | auto | — | file:ecc03a3565151800eedd73c5ecce83a6ef15ffeb02e2ef064df0341ab7554ccb (inferred_fingerprint) | pre_tracking |
| bch_extra_self_18 | final_test_candidate | beach | bch_extra_self_18 | auto | — | file:d7690d3efadbbce7b36f3ccd1aa9fb952d8bafbde0075a884b80400816685168 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_19 | train | beach | bch_extra_self_19 | auto | — | file:a60d76364ffea6b87efbe20f440754cac2f1650e9106fbdcadd36774cd578b25 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_20 | train | beach | bch_extra_self_20 | auto | — | file:486c56e0b1375acd62e67bf8f50b50b0cd3d8485c2551d98092df28ec1057a0d (inferred_fingerprint) | pre_tracking |
| bch_extra_self_21 | train | beach | bch_extra_self_21 | auto | — | file:dc29fb39ce417ad47bd28c24a3ae4cab3a0692f20773163c38a60bd50ed6d272 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_22 | train | beach | bch_extra_self_22 | auto | — | file:81115341274322394f2e01b6492265acd54febf36627aa519b0b97676bed6e4b (inferred_fingerprint) | pre_tracking |
| bch_extra_self_23 | train | beach | bch_extra_self_23 | auto | — | file:ea6c851dbde729c9a08efdceac659bc9fbcd0c3975d318040fbf55ad760296db (inferred_fingerprint) | none |
| bch_extra_self_24 | train | beach | bch_extra_self_24 | auto | — | file:36af6585ae192be3f7717d93e12e97c926d4793a20295a5698285ef9734d65a5 (inferred_fingerprint) | none |
| bch_extra_self_25 | train | beach | bch_extra_self_25 | auto | — | file:6a77846dac5e5568b48d12829983d2a2e2c6925a9d2f97d908a15813f79c08c3 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_26 | train | beach | bch_extra_self_26 | auto | — | file:9c3d7952875e177499e5ccbb964120e2576c2aaed9117c745d83b055c5e363d9 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_27 | train | beach | bch_extra_self_27 | auto | — | file:9c5175a25f7cdc1ad679e4c324090ca10c14fb040d79bd542d2f00d2eb59e503 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_28 | train | beach | bch_extra_self_28 | auto | — | file:8ec4493cf1fd0e2abd1b1430262c92d6b7703e05c3da7c785b5ad83b26a572c9 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_29 | final_test_candidate | beach | bch_extra_self_29 | auto | — | file:8d0e3e60b02b9e15ddc58d52ce9b4a43ecb4554eb7f3790f1a2a0dd2f89dd575 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_30 | final_test_candidate | beach | bch_extra_self_30 | auto | — | file:02e0b8c0b9ac6e9ce1395fa96de9e09d740e550f4f6c876763fce7ac71a54d76 (inferred_fingerprint) | pre_tracking |
| bch_extra_self_31 | final_test_candidate | beach | bch_extra_self_31 | auto | — | file:64b152182bf98d2a784b4280dacaf36a6bd04fdacbd17981c961f7878f9292a0 (inferred_fingerprint) | pre_tracking |
| bch_gnd_ovc_land_self_01 | train | beach | bch_gnd_ovc_land_self_01 | train | — | file:8dbefe7b605c004cf611855426567f08cc2114160fb94bbdc7a68d9fbb357a83 (inferred_fingerprint) | pre_tracking, training_package |
| bch_gnd_ovc_land_self_01_v2 | train | beach | bch_gnd_ovc_land_self_01 | train | Mike Jazgarski | youtube:em0vtWfpFSQ (confirmed) | pre_tracking, training_package |
| bch_gnd_ovc_land_self_03 | train | beach | bch_gnd_ovc_land_self_03 | train | Beach Volleyball | youtube:Wwm1VcxbMHE (confirmed) | pre_tracking, training_package |
| bch_gnd_sun_land_self_02 | train | beach | bch_gnd_sun_land_self_02 | train | 1st Seed Volleyball | youtube:aCmyH9_oV6c (confirmed) | pre_tracking, training_package |
| bch_gnd_sun_land_self_02_v2 | train | beach | bch_gnd_sun_land_self_02 | train | — | file:7b0df692a840fc491fad132cda00943d14d96ea1523e1fd73bd802c4595787f9 (inferred_fingerprint) | pre_tracking, training_package |
| bch_gnd_sun_land_self_02_v3 | train | beach | bch_gnd_sun_land_self_02 | train | 1st Seed Volleyball | youtube:bOVU9txvMzo (confirmed) | pre_tracking, training_package |
| bch_gnd_sun_land_self_02_v4 | train | beach | bch_gnd_sun_land_self_02 | train | 1st Seed Volleyball | youtube:N30WLlXNLec (confirmed) | pre_tracking, training_package |
| bch_gnd_sun_land_self_02_v5 | train | beach | bch_gnd_sun_land_self_02 | train | 1st Seed Volleyball | youtube:vdc-NUctBVQ (confirmed) | pre_tracking, training_package |
| bch_gnd_sun_land_self_02_v6 | train | beach | bch_gnd_sun_land_self_02 | train | 1st Seed Volleyball | youtube:wzdNbHQbuEg (confirmed) | pre_tracking, training_package |
| bch_hnd_ovc_land_self_01 | train | beach | bch_hnd_ovc_land_self_01 | train | Mohd Nordin Hussain | youtube:wf50CVUSKqo (confirmed) | pre_tracking, training_package |
| bch_onl_ovc_land_onl_02 | tune | beach | bch_onl_ovc_land_onl_02 | val | Blake Seegers | youtube:GEOoIfqgugU (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| bch_onl_ovc_land_onl_02_v2 | tune | beach | bch_onl_ovc_land_onl_02 | val | Blake Seegers | youtube:nzmArcqT1TU (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| bch_onl_ovc_land_onl_02_v3 | dev_val | beach | bch_onl_ovc_land_onl_02 | val | Blake Seegers | youtube:--UAF5GpI0w (confirmed) | pre_tracking, test_set_scoring, training_package |
| bch_onl_ovc_land_onl_02_v4 | tune | beach | bch_onl_ovc_land_onl_02 | val | Blake Seegers | youtube:4VTRrT3b40s (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| bch_onl_sun_land_onl_01 | train | beach | bch_onl_sun_land_onl_01 | train | Alex | youtube:itCVYFtr5WI (confirmed) | pre_tracking, training_package |
| bch_onl_sun_land_onl_01_v2 | train | beach | bch_onl_sun_land_onl_01 | train | Alex | youtube:o2lbYPSqzjU (confirmed) | pre_tracking, training_package |
| bch_onl_sun_land_onl_03 | legacy_holdout | beach | bch_onl_sun_land_onl_03 | val | Dianne Gan | youtube:2UUUGXanWxQ (confirmed) | pipeline_tuning_holdout, pre_tracking, test_set_scoring, training_package |
| bch_onl_sun_land_onl_03_v2 | legacy_holdout | beach | bch_onl_sun_land_onl_03 | val | Dianne Gan | youtube:julH3gK_3Yo (confirmed) | pipeline_tuning_holdout, pre_tracking, test_set_scoring, training_package |
| bch_onl_sun_land_onl_04 | train | beach | bch_onl_sun_land_onl_04 | train | Trent Smillie | youtube:f2aF5FN5LUQ (confirmed) | pre_tracking, training_package |
| bch_sid_ovc_land_self_02 | train | beach | bch_sid_ovc_land_self_02 | train | — | file:7fd0d585ff25d78d6ee4245bae98719a4f84171441d49d2e20b7744e78eb128e (inferred_fingerprint) | pre_tracking, training_package |
| bch_sid_ovc_land_self_02_v2 | train | beach | bch_sid_ovc_land_self_02 | train | — | file:5bf1b5b7f451716bfa9173e9a136cf0fcafafa616ac07d8f0c267e6f9af1a97a (inferred_fingerprint) | pre_tracking, training_package |
| bch_sid_sun_land_self_03 | train | beach | bch_sid_sun_land_self_03 | train | Alex | youtube:6qUTRu0xqrQ (confirmed) | pre_tracking, training_package |
| bch_sid_sun_port_self_01 | train | beach | bch_sid_sun_port_self_01 | train | Better at Beach Volleyball | youtube:MbW6MCmnpd8 (confirmed) | none |
| bch_tri_sun_land_self_01 | train | beach | bch_tri_sun_land_self_01 | train | — | file:f1193e8445e3ea06d2b1bf134b273b6331fc34398a08d5a268b6d06230904d3f (inferred_fingerprint) | pre_tracking, training_package |
| bch_tri_sun_land_self_01_v2 | train | beach | bch_tri_sun_land_self_01 | train | — | file:7bfcba739c7aed928ca24baa21a338fc9df01efc0a00c633e9e61e21df988d9b (inferred_fingerprint) | pre_tracking, training_package |
| bch_tri_sun_land_self_01_v3 | train | beach | bch_tri_sun_land_self_01 | train | — | file:27cd6e68827fc2a7b807582522737434ab3fc6a456b8bb7557f606d27e358255 (inferred_fingerprint) | pre_tracking, training_package |
| bch_tri_sun_land_self_01_v4 | train | beach | bch_tri_sun_land_self_01 | train | — | file:b4c2057388ebbc99f1a45f12f8691c12edc4e7044537540eeac624d168972dcc (inferred_fingerprint) | pre_tracking, training_package |
| grs_ele_dusk_port_self_03 | train | grass | grs_ele_dusk_port_self_03 | train | AVP Beach Volleyball | youtube:0MnjfOUg4DQ (confirmed) | training_package |
| grs_ele_dusk_port_self_03_v2 | train | grass | grs_ele_dusk_port_self_03 | train | GrassVolleyball | youtube:dxif699FPk0 (confirmed) | pre_tracking, training_package |
| grs_ele_shade_land_self_02 | train | grass | grs_ele_shade_land_self_02 | train | Expansion Volleyball | youtube:50P96wuXt5Y (confirmed) | pre_tracking, training_package |
| grs_ele_sun_land_self_01 | train | grass | grs_ele_sun_land_self_01 | train | — | file:2b8e3ef52cd6d5a78d56850a404ce2ffa657aab3751f82f9a631cdfe2bcd598f (inferred_fingerprint) | pre_tracking, training_package |
| grs_ele_sun_land_self_01_v2 | train | grass | grs_ele_sun_land_self_01 | train | Gainesville Volleyball | Big Grass Party | youtube:5LMZ9sSIewI (confirmed) | pre_tracking, training_package |
| grs_ele_sun_land_self_01_v3 | train | grass | grs_ele_sun_land_self_01 | train | Gainesville Volleyball | Big Grass Party | youtube:Pf3R1hEH6Fs (confirmed) | pre_tracking, training_package |
| grs_ele_sun_land_self_01_v4 | train | grass | grs_ele_sun_land_self_01 | train | Blandford Drone & Video | youtube:I26flewmE2o (confirmed) | pre_tracking, training_package |
| grs_extra_self_01 | train | grass | grs_extra_self_01 | auto | — | file:b4823c28cad90135a2dde8d8627973a2aeaf2ee265cd362043698dc2199ffdb0 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_02 | final_test_candidate | grass | grs_extra_self_02 | auto | — | file:c78c94e19844aa4232874e9fa269a11e6599c5e62dc56ba1bfe654d169d302c5 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_03 | train | grass | grs_extra_self_03 | auto | — | file:6dc3457462a1406afba7196661d8f56513aed40f08156b4537b4845ff76fb005 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_04 | train | grass | grs_extra_self_04 | auto | — | file:1f34abe677ac07290fa88021f39a8e49dc8838918d0ceb7f07ac659fbcdea8a8 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_05 | train | grass | grs_extra_self_05 | auto | — | file:8f97fde5371bcde164055b815670e3a0ea4dff10265a5485bcad141499fb2551 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_06 | final_test_candidate | grass | grs_extra_self_06 | auto | — | file:d04cff74d627cce2cbb49435e4d34a489f8dbd43bcd3eea26944bdcbbe9342ae (inferred_fingerprint) | pre_tracking |
| grs_extra_self_07 | final_test_candidate | grass | grs_extra_self_07 | auto | — | file:3133ae1df9486849ff66365c2432cd57ba4304e6396a5e3df6d4180824633251 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_08 | train | grass | grs_extra_self_08 | auto | — | file:7a0ec4665137d2d8b6777107f9e43817d21b11b5f8d35b9598989f5573a42f4f (inferred_fingerprint) | pre_tracking |
| grs_extra_self_09 | train | grass | grs_extra_self_09 | auto | — | file:56be263f4a151ee847b4d93530737a5c35058deee7a70a18052749d31fdffd1a (inferred_fingerprint) | pre_tracking |
| grs_extra_self_10 | train | grass | grs_extra_self_10 | auto | — | file:6ddd7f8aaac651b4fc0aeeb7f37316c1ff3028ed966d9f1d1bf6e729a46ea2ae (inferred_fingerprint) | pre_tracking |
| grs_extra_self_11 | train | grass | grs_extra_self_11 | auto | — | file:cbc347aa6ba5ddd7908fd3eed4994ec1de285289b552fa6c73a5105d18d61a41 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_12 | final_test_candidate | grass | grs_extra_self_12 | auto | — | file:136b3de8a5dd2d05ef40a225d7814636f1e58b45e9a9182e90086e45b5a0d835 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_13 | train | grass | grs_extra_self_13 | auto | — | file:eae9375de8c63d7f1b593bec2803dd9b736a44bc59beed02674a7ddd829c3b35 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_14 | final_test_candidate | grass | grs_extra_self_14 | auto | — | file:8641d83e784b78eb9d7e8f8c1a80a9875eae84748219bd37f4da457ac284f643 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_15 | final_test_candidate | grass | grs_extra_self_15 | auto | — | file:d35e60771003c4ed91d18e9e76ee62bb9585e319041b8501d07022f0e360b9db (inferred_fingerprint) | pre_tracking |
| grs_extra_self_16 | train | grass | grs_extra_self_16 | auto | — | file:6ab635998960f071d09175a66f52651b0c1dfa17ee674df6df01045773b5c39f (inferred_fingerprint) | pre_tracking |
| grs_extra_self_17 | train | grass | grs_extra_self_17 | auto | — | file:c6c491d7a94b99013b8009bc2ddb6052bc559f10e63cfa7e6e1ab552fed1a864 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_18 | train | grass | grs_extra_self_18 | auto | — | file:18d08a5c3b44392bda0c8e5c8d09b7f25e666f97c3f73304068bc1db2b62ee34 (inferred_fingerprint) | pre_tracking |
| grs_extra_self_19 | train | grass | grs_extra_self_19 | auto | — | file:908656ed165c56e0c90dad2cdfd2daf0e9bf3591d9a6f0a02cbc0b1075c26f9e (inferred_fingerprint) | pre_tracking |
| grs_extra_self_20 | final_test_candidate | grass | grs_extra_self_20 | auto | — | file:da357993415f35eb5c73d19ba94c64f33cf826322a256ee2ca1fa40f26f76a2f (inferred_fingerprint) | pre_tracking |
| grs_extra_self_21 | final_test_candidate | grass | grs_extra_self_21 | auto | — | file:e67e36f8731943f702ca6644819c893b641b16fa43f11d6ee8ce056d2b19d655 (inferred_fingerprint) | pre_tracking |
| grs_extra_tester_01 | train | grass | grs_extra_tester_01 | train | — | file:ba601df0a1cd2236321c01d2d522d47ed0585ff61db3995462c54d16b1c43839 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_02 | train | grass | grs_extra_tester_02 | train | — | file:c3a1ea850f85102bbca32220c84abbadb8cecb846fd1a03a89b84406f28abcd7 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_02_v2 | train | grass | grs_extra_tester_02 | train | — | file:01b7c9fde0e5c16fa7b76dee5e5f3f72b1a6bf9513b007908cd2a4cdf1b26339 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_03 | train | grass | grs_extra_tester_03 | train | — | file:cdff6dd1ac58abdeb2d0d2c3f40a0816b22831578a4e6d3c4965ab6a44c806ac (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_03_v2 | train | grass | grs_extra_tester_03 | train | — | file:4415d18314c2e00aed768d73784fb3894ab1e3cec331eb035ad2c9f2e053d5cd (inferred_fingerprint) | none |
| grs_extra_tester_03_v3 | train | grass | grs_extra_tester_03 | train | — | file:c7d6feaa882752350fc09e0beb5119ae69ef14d1a083a1bfa7d976683dfed811 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_03_v4 | train | grass | grs_extra_tester_03 | train | — | file:5212ed8819981b54900b9974c2f8d6569b2a5213b929135f32a524946394d744 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_03_v5 | train | grass | grs_extra_tester_03 | train | — | file:b22318ad88b62f8c683730cd12faeccbec813c3542a1d88ca372a37e2ee50ce2 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_03_v6 | train | grass | grs_extra_tester_03 | train | — | file:83c6cfcf6e85c40aaacd936144248564f6633e9be5c6c74dc92c164961b89e18 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_03_v7 | train | grass | grs_extra_tester_03 | train | — | file:be7cbfcc2047e4f65b70d2144e1ecd0eb33591080e4e64ae2c9dd1d6a5869b25 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_03_v8 | train | grass | grs_extra_tester_03 | train | — | file:16ccbdb2c323ff04bd4b1f356b7934337ad63d17d5910594bbb7d26df6c8d326 (inferred_fingerprint) | none |
| grs_extra_tester_03_v9 | train | grass | grs_extra_tester_03 | train | — | file:edfffa373f1933c72854214164662591abc029d774f81f3702eb4d6f16b4b501 (inferred_fingerprint) | pre_tracking, training_package |
| grs_extra_tester_04 | train | grass | grs_extra_tester_04 | train | — | file:0f2a9e431f74c5356e52b1dbf2a320643759696c82a536bfba41786f2a18d9a0 (inferred_fingerprint) | pre_tracking, training_package |
| grs_gnd_dusk_land_self_03 | train | grass | grs_gnd_dusk_land_self_03 | train | Caseyrosexo | youtube:r9kflsBTArQ (confirmed) | pre_tracking, training_package |
| grs_gnd_shade_land_self_02 | train | grass | grs_gnd_shade_land_self_02 | train | Clark Ngo | youtube:adXKWyQP854 (confirmed) | none |
| grs_gnd_shade_land_self_02_v2 | train | grass | grs_gnd_shade_land_self_02 | train | Chandler North | youtube:JmXZtcZPlqk (confirmed) | pre_tracking, training_package |
| grs_gnd_sun_land_self_01 | train | grass | grs_gnd_sun_land_self_01 | train | — | file:480decaa06522216e6a01f41087041a0c9b18699e4197296a4ec0b652591a924 (inferred_fingerprint) | pre_tracking, training_package |
| grs_gnd_sun_land_self_01_v2 | train | grass | grs_gnd_sun_land_self_01 | train | — | file:b900a3095327e5f8584443084097e2c6fb893bebb3fb3d87de1f66418faafd94 (inferred_fingerprint) | pre_tracking, training_package |
| grs_gnd_sun_land_self_01_v3 | train | grass | grs_gnd_sun_land_self_01 | train | lambsters volleyball | youtube:HCeocwa0Dxs (confirmed) | pre_tracking, training_package |
| grs_gnd_sun_land_self_01_v4 | train | grass | grs_gnd_sun_land_self_01 | train | 1PonchMan | youtube:nX854JW7T-w (confirmed) | pre_tracking, training_package |
| grs_gnd_sun_land_self_01_v5 | train | grass | grs_gnd_sun_land_self_01 | train | V4 Volleyball - Nick Vo | youtube:R4HeWTtxOAI (confirmed) | pre_tracking, training_package |
| grs_gnd_sun_land_self_01_v6 | train | grass | grs_gnd_sun_land_self_01 | train | Volley Bums | youtube:BQ0XAFftBlk (confirmed) | pre_tracking, training_package |
| grs_hnd_shade_port_self_02 | tune | grass | grs_hnd_shade_port_self_02 | val | Grace Qian | youtube:sQY6ssoZiv4 (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| grs_hnd_sun_land_self_01 | train | grass | grs_hnd_sun_land_self_01 | train | — | file:04eb04eee021d72225158b849cf23f237a041de290de69071a05c80b3bccec20 (inferred_fingerprint) | pre_tracking, training_package |
| grs_hnd_sun_land_self_01_v2 | train | grass | grs_hnd_sun_land_self_01 | train | — | file:4624f8472f436015bdeab52fd52f20556b5f53c2617334ec7461195916409532 (inferred_fingerprint) | none |
| grs_hnd_sun_land_self_01_v3 | train | grass | grs_hnd_sun_land_self_01 | train | Clark Ngo | youtube:zXH5h-NA-74 (confirmed) | pre_tracking, training_package |
| grs_onl_dusk_land_onl_03 | legacy_holdout | grass | grs_onl_dusk_land_onl_03 | val | Grace Qian | youtube:gWEjh1l4wto (confirmed) | pipeline_tuning_holdout, pre_tracking, rally_scoring, test_set_scoring, training_package |
| grs_onl_shade_land_onl_02 | tune | grass | grs_onl_shade_land_onl_02 | val | Grace Qian | youtube:slWWzpI_Slc (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| grs_onl_sun_land_onl_01 | tune | grass | grs_onl_sun_land_onl_01 | val | Grace Qian | youtube:-2xDgPzs6Zo (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| grs_onl_sun_land_onl_01_v2 | dev_val | grass | grs_onl_sun_land_onl_01 | val | Grace Qian | youtube:OPi2glKaIvk (confirmed) | pre_tracking, test_set_scoring, training_package |
| grs_onl_sun_land_onl_04 | train | grass | grs_onl_sun_land_onl_04 | train | Dianne Gan | youtube:MU6Jy81tb7E (confirmed) | pre_tracking, training_package |
| grs_onl_sun_land_onl_04_v2 | train | grass | grs_onl_sun_land_onl_04 | train | Out of System | youtube:_QiTA7DYPs8 (confirmed) | pre_tracking, training_package |
| grs_sid_shade_land_self_02 | train | grass | grs_sid_shade_land_self_02 | train | V4 Volleyball - Nick Vo | youtube:6_egL09hp0c (confirmed) | pre_tracking, training_package |
| grs_sid_shade_land_self_02_v2 | train | grass | grs_sid_shade_land_self_02 | train | Dianne Gan | youtube:eFU9BZN7Tqw (confirmed) | pre_tracking, training_package |
| grs_sid_sun_port_self_01 | train | grass | grs_sid_sun_port_self_01 | train | — | file:2b5e67ca0bc182463bb1b53eba35fbbd614f6c2edcc513029df2c16b9070769e (inferred_fingerprint) | pre_tracking, training_package |
| grs_sid_sun_port_self_01_v2 | train | grass | grs_sid_sun_port_self_01 | train | NYC - LI Volleyball | youtube:kL6a113GhtI (confirmed) | pre_tracking, training_package |
| grs_tri_shade_port_self_02 | train | grass | grs_tri_shade_port_self_02 | train | 1st Seed Volleyball | youtube:MWRYCnd-m-Y (confirmed) | pre_tracking, training_package |
| grs_tri_sun_land_self_01 | train | grass | grs_tri_sun_land_self_01 | train | Quin Zilch | youtube:lZ8j3a4pvYY (confirmed) | pre_tracking, training_package |
| grs_tri_sun_land_self_01_v2 | train | grass | grs_tri_sun_land_self_01 | train | Pittsburgh Grass Volleyball | youtube:v0UcqeFC1ZE (confirmed) | none |
| ind_ele_bright_land_self_01 | tune | indoor | ind_ele_bright_land_self_01 | val | Carsten Lindemeier | youtube:Jp7z7isnyTY (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| ind_ele_dim_land_self_02 | tune | indoor | ind_ele_dim_land_self_02 | val | Luck Sports & Entertainment | youtube:5T5YnoIny-Y (confirmed) | pipeline_tuning_tune, rally_scoring, training_package |
| ind_ele_dim_land_self_02_v2 | tune | indoor | ind_ele_dim_land_self_02 | val | Philip Yung | youtube:YL2sAeIJcqI (confirmed) | pipeline_tuning_tune, pre_tracking, rally_scoring, test_set_scoring, training_package |
| ind_ele_dim_land_self_02_v3 | dev_val | indoor | ind_ele_dim_land_self_02 | val | Lounel Francisco | youtube:IZKhj9m2SJw (confirmed) | pre_tracking, test_set_scoring, training_package |
| ind_ele_dim_land_self_04 | train | indoor | ind_ele_dim_land_self_04 | train | Dalenaaa | youtube:WcMFSmDOSzc (confirmed) | pre_tracking, training_package |
| ind_extra_self_01 | train | indoor | ind_extra_self_01 | auto | — | file:cfc877eef8f84b78462fe3a9843b75142cb4aa126572a96dd35a433e58d58a3f (inferred_fingerprint) | pre_tracking |
| ind_extra_self_02 | train | indoor | ind_extra_self_02 | auto | — | file:6789a408595ade841a5cf92080674e2754727d51ea8c66457981c16a8d3ba94b (inferred_fingerprint) | pre_tracking |
| ind_extra_self_03 | train | indoor | ind_extra_self_03 | auto | — | file:dee8f49ee1962ad16ebc312c8298b5e0d2c74bda597ab9c70f3cad804f22e415 (inferred_fingerprint) | pre_tracking |
| ind_extra_self_04 | train | indoor | ind_extra_self_04 | auto | — | file:6e9f748668bbe5e42ebe894e42f4386ce70f1221704bcb1741e4c73deee47912 (inferred_fingerprint) | pre_tracking |
| ind_extra_self_05 | train | indoor | ind_extra_self_05 | auto | — | file:6c135e9df8b34af49de298627969c819fec6d73200cb118f66ecf5f44a9db6da (inferred_fingerprint) | pre_tracking |
| ind_extra_self_06 | final_test_candidate | indoor | ind_extra_self_06 | auto | — | file:16ad6a443d1f98bfa1013de6bbc90fec47ab3c0645d71b811d6364bdb5091982 (inferred_fingerprint) | pre_tracking |
| ind_extra_self_07 | train | indoor | ind_extra_self_07 | auto | — | file:aaf674a8b7cd824193b6184774a6dc3f0824f35a857f8f49da4ddb2e7a9e2b5c (inferred_fingerprint) | pre_tracking |
| ind_extra_self_08 | train | indoor | ind_extra_self_08 | auto | — | file:3a677cb643487dda761900c93d61f1a30f0ee505b87e35a6148f6e137f861bb8 (inferred_fingerprint) | pre_tracking |
| ind_extra_self_09 | final_test_candidate | indoor | ind_extra_self_09 | auto | — | file:8f9ab8c1859044fc8daf3ec5166e2049158aafd1a8a899dc37088e467bce2f51 (inferred_fingerprint) | pre_tracking |
| ind_gnd_bright_land_self_01 | train | indoor | ind_gnd_bright_land_self_01 | train | Jayster | youtube:ngZSGGOc-Tg (confirmed) | pre_tracking, training_package |
| ind_gnd_bright_land_self_01_v2 | train | indoor | ind_gnd_bright_land_self_01 | train | Andre Troyer | youtube:pk46UoPr0a8 (confirmed) | pre_tracking, training_package |
| ind_gnd_bright_land_self_01_v3 | train | indoor | ind_gnd_bright_land_self_01 | train | Tyler Ripoli | youtube:Qg2akNKcFJI (confirmed) | none |
| ind_gnd_bright_land_self_01_v4 | train | indoor | ind_gnd_bright_land_self_01 | train | Short guy Volleyball | youtube:1mC2MlyBEv8 (confirmed) | pre_tracking, training_package |
| ind_gnd_bright_port_self_03 | train | indoor | ind_gnd_bright_port_self_03 | train | — | file:ca095c7f65df4c73339a6e4f3845be5f0cde3d5236cfd8b565e29c7b4065fcf9 (inferred_fingerprint) | pre_tracking, training_package |
| ind_gnd_dim_land_self_02 | train | indoor | ind_gnd_dim_land_self_02 | train | — | file:6c8b9c9169b041eb044ae6198e9b4dec74af3f4c565ffe78e68549f2fc3e5560 (inferred_fingerprint) | pre_tracking |
| ind_hnd_bright_port_self_01 | train | indoor | ind_hnd_bright_port_self_01 | train | Drew | youtube:Kr4UoYtRnt4 (confirmed) | none |
| ind_hnd_dim_land_self_02 | train | indoor | ind_hnd_dim_land_self_02 | train | Volleyball Source 2.0 | youtube:sU9amp7fJKA (confirmed) | pre_tracking, training_package |
| ind_hnd_dim_land_self_02_v2 | train | indoor | ind_hnd_dim_land_self_02 | train | moomoocowjonny | youtube:WU0GteluwQc (confirmed) | none |
| ind_onl_bright_land_onl_01 | train | indoor | ind_onl_bright_land_onl_01 | train | Bokuto  | youtube:7oXjebsAtvY (confirmed) | pre_tracking, training_package |
| ind_onl_bright_land_onl_01_v2 | train | indoor | ind_onl_bright_land_onl_01 | train | Bokuto  | youtube:kv_F17KFrsM (confirmed) | pre_tracking, training_package |
| ind_onl_bright_land_onl_01_v3 | train | indoor | ind_onl_bright_land_onl_01 | train | Bokuto  | youtube:nKBjwxTLQ1Y (confirmed) | pre_tracking, training_package |
| ind_onl_bright_land_onl_01_v4 | train | indoor | ind_onl_bright_land_onl_01 | train | Bokuto  | youtube:ZA-Xb6ttMxU (confirmed) | pre_tracking, training_package |
| ind_onl_bright_land_onl_04 | legacy_holdout | indoor | ind_onl_bright_land_onl_04 | val | margie<3 | youtube:tC8nvubWSaw (confirmed) | pipeline_tuning_holdout, pre_tracking, test_set_scoring, training_package |
| ind_sid_bright_land_self_02 | legacy_holdout | indoor | ind_sid_bright_land_self_02 | val | Michelle Thao | youtube:LQt_mu2eN-U (confirmed) | pipeline_tuning_holdout, pre_tracking, rally_scoring, test_set_scoring, training_package |
| ind_sid_dim_land_self_01 | train | indoor | ind_sid_dim_land_self_01 | train | — | file:0fa6977ff6fe376ed46daf4e6e5ba17c061c617ba86b8d861bf21b3396f70e59 (inferred_fingerprint) | pre_tracking, training_package |
| ind_tri_bright_land_self_01 | train | indoor | ind_tri_bright_land_self_01 | train | — | file:95f7654b01dd93222d18f71d6f9c2ef57220aa7a031996a9fc8ec2705c621ae0 (inferred_fingerprint) | none |
| ind_tri_bright_land_self_01_v2 | train | indoor | ind_tri_bright_land_self_01 | train | — | file:acf88a7da00dcf1b209e35134b32b45585bc5d32b1aa3fee3db3368e46ee577f (inferred_fingerprint) | none |
| ind_tri_bright_land_self_01_v3 | train | indoor | ind_tri_bright_land_self_01 | train | Glen Mendoza | youtube:qo-DV2lU10o (confirmed) | pre_tracking, training_package |
| ind_tri_bright_land_self_01_v4 | train | indoor | ind_tri_bright_land_self_01 | train | Bryce Schroeder | youtube:4R-WrdmpR-U (confirmed) | pre_tracking, training_package |
| ind_tri_dim_port_self_02 | train | indoor | ind_tri_dim_port_self_02 | train | Jumping is Good | youtube:BxklmDxjmGk (confirmed) | pre_tracking, training_package |
