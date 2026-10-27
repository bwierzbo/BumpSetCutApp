---
title: Protected-footage inventory of the labeling bucket — 2026-10-26
status: findings for the owner; no data, file or permission changed
created: 2026-10-26T21:40:00Z
updated: 2026-10-26T21:40:00Z
decision: D-002, D-017, D-018; owner direction 2026-10-26 §3
pr: feat/stage1-events-sync (#100)
---

# Protected-footage inventory of the labeling bucket (2026-10-26)

**Method (read-only).**
- The withheld closure was computed by RallyLab itself: `RallyLab --project Scratch --review-status`, built from PR #100. This uses the same guard as the Review tab, by name, path and content, with the footage share mounted read-only.
- It was compared with `public.label_videos` and with the metadata of the objects in the private `labeling` bucket (`storage.objects`: names, sizes, ETags, created_at). Neither was modified.
- Who labelled what was read from `label_rally_times`, `label_tracks` and `label_frame_log`, aggregated as lead vs non-lead. No identities are reported here.
- No object was downloaded. No file, row, policy or permission was changed.

## Findings

**1. Eight withheld recordings have copies on the server, with `label_videos` rows that every labeler can read.**

| Recording | Withheld as | Copy uploaded (UTC) | Labeling activity on the server |
|---|---|---|---|
| `bch_extra_self_29` | lineage holdout | 2026-10-22 14:41 — **after the D-017 cut-over (2026-10-21)** | none |
| `bch_extra_self_30` | lineage holdout | 2026-10-22 14:37 — **after the cut-over** | none |
| `bch_extra_self_31` | lineage holdout | 2026-10-17 15:07 (before the cut-over) | one tracked rally saved by the lead, 2026-10-17 (the Mac's own sync) |
| `bch_onl_sun_land_onl_03` | legacy holdout | 2026-10-10 02:26 | lead: tracks, rally times, 439 frame checks |
| `bch_onl_sun_land_onl_03_v2` | legacy holdout | 2026-10-09 21:53 | lead: tracks, 758 frame checks |
| `grs_onl_dusk_land_onl_03` | legacy holdout | 2026-10-10 02:49 | lead: tracks, rally times, 663 frame checks; **a non-lead labeler: one tracked rally (2026-10-10) and 6 frame checks (2026-10-16)** |
| `ind_onl_bright_land_onl_04` | legacy holdout | 2026-10-10 00:10 | lead: tracks, 512 frame checks |
| `ind_sid_bright_land_self_02` | legacy holdout | 2026-10-09 22:33 | lead: tracks, rally times, 560 frame checks; **a non-lead labeler: 53 frame checks (2026-10-16)** |

The other 13 withheld recordings have no copy and no row on the server: `bch_extra_self_05/10/18`, `grs_extra_self_02/06/07/12/14/15/20/21` and `ind_extra_self_06/09`.

**Cause.** Before PR #100, `LabelingSync.publishVideos` uploaded every session that had a readable video, with no withheld filter. Copies 29 and 30 were uploaded by the Mac's normal sync the day after the cut-over. PR #100 stops this going forward: withheld recordings are never uploaded, and nothing is uploaded when the closure cannot be read.

**2. Access paths.**
- **Video copies.** The `labeling` bucket is private, but the storage policy `labeling_select` lets any labeler (4 accounts, 1 lead) list objects and create a signed URL for any of them. So all eight copies can be downloaded by any labeler.
- **Video rows.** The policy `label_videos_labelers` (`ALL … USING is_labeler()`) lets any labeler read these rows, including their `clip_path`, and also write them.
- **Labels.** `label_tracks`, `label_rally_times` and `label_frame_log` rows for these recordings are readable by labelers under their existing policies.
- **Stage 1 records.** Migration 048, as corrected in this PR, makes `label_rally_events` unreadable for withheld recordings. It does not change the three paths above.

**3. Download exposure cannot be ruled out.** Storage request logs are retained for 24 hours only. They show no request for these objects in that window, and nothing older can be checked. Any of the four labelers may have downloaded any of the eight copies since they were uploaded.
- For the two lineage-holdout copies uploaded after the cut-over (29, 30), the server holds **no labeling activity of any kind**, so no label for them came from the phone.
- For the legacy holdout, a non-lead labeler did look at frames of two recordings. The L2 preregistration already records the legacy holdout as historically exposed and diagnostic-only, so this changes no recorded status. It is reported for completeness.

**4. Aliases.**
- All 109 Scratch copies on the server are named after current sessions, and RallyLab judged each one, including aliases by path and content. Apart from the eight above, none is withheld.
- The 14 copies under the archived `Test1` project share no fingerprint, origin or source id with any withheld recording, per both projects' `project.json`.
- **One object is not referenced by any row and is not a current session of either project:** `rallylab/Scratch/ind_gnd_dim_land_self_02_v2-v2.mp4` (188 MB, uploaded 2026-10-09). Its source cannot be established from metadata, and its content cannot be compared without downloading it. Whether it is a copy of a withheld recording is **unknown**. Its name belongs to an eligible recording family (`ind_gnd_dim_land_self_02`).

**5. L2 isolation.** None of this touches the L2 package, which was built from the Mac's people-only labels and verified by digest on 2026-10-25. The lineage-holdout recordings have no server labels at all, except one Mac-synced track for 31 dated before the cut-over.

## Options for the owner (none taken)

1. **Restrict reads of withheld footage on the server** (a permission change). After 048 is applied, add the published-list condition used for `label_rally_events` to `label_videos` SELECT and to the `labeling_select` storage policy, so withheld rows and copies are unreadable by every labeler, judged at read time. This is a small migration (049) and is testable locally like 048.
2. **Remove the eight copies and the orphan** (a data change). Delete the objects, and either delete their `label_videos` rows or clear `clip_path`. The tracks and frame checks on legacy-holdout rows would then need a decision: keep them as evidence, or archive them.
3. **Record the exposure.** Add a dated note to the lineage record that copies 29/30/31 were downloadable by labelers from the dates above, with no recorded use. Whether that affects the lineage-holdout status is the owner's call under D-017.
