---
id: EXP-20261110-lineage-holdout-copies-audit
status: done — the correction was applied to the live project on 2026-11-12 on the owner's authorisation (§8); what stays open is listed in §9
created: 2026-11-10T19:53:11Z
updated: 2026-11-13T01:34:52Z
decision: D-036 (amends D-017, D-018); D-037 (applied; L2 marked exposed)
roadmap_phase: dataset integrity (D-002, D-009, D-017, D-018)
pr: fix/d017-lineage-correction
issue: n/a
---

# EXP-20261110-lineage-holdout-copies-audit — three lineage-holdout recordings were trained on under other names

An audit, not a training run: no model was trained, no protected video was decoded for it after the owner's authorisation of 2026-11-10 ([verbatim](../../decisions/2026-11-10-d017-lineage-correction-authorization.md)), and the live Scratch project was not changed. Evidence that is not in the repository is under `~/Movies/RallyLab/Reports/d017-correction-20261110/` (backup of the project's metadata with SHA-256 sums, the runs on the isolated copy, the apply script).

## Question

Why did the L2 package (D-018) train on footage of the lineage holdout (D-017), how far does it reach, and what makes every consumer refuse it from here on?

## Inputs (as found, 2026-11-10)

| Input | Value |
|---|---|
| Code | `712f048` (main) |
| Scratch `project.json` | sha256 `1364ee92aa269f71…` |
| Scratch `validation.json` | sha256 `cc22cd32c5f7aee5…` (16 `lineageHoldout`, 5 `holdout`) |
| Split manifest | `manifest.json` sha256 `216896db79445496…` (167 videos) |
| Exposure ledger | `exposure-log.json` sha256 `2574ead797fce420…` |
| L2 package record | `Scratch/manifests/l2/Scratch-L2-multiframe-20261021-1917.json` (preflight 2026-10-25T16:05:41Z, 13/13 passed, digest `04e3551b1cf92965…`) |
| Classifier dataset | `rc-v1-20261108` (49 recordings; digest `1b1e6898…`, manifest `237f2fb7…`) |

## 1. What was found

Three train recordings are the same footage as three lineage-holdout recordings:

| Train card (Scratch, 2026-10-07) | Lineage holdout (2026-10-17) | Original | Stretch (s) | Evidence |
|---|---|---|---|---|
| `grs_ele_sun_land_self_01` | `grs_extra_self_06` | `IMG_0823.MOV` | 211–511 | cards (below); decoded frames at 5, 150 and 290 s identical (compared 2026-11-09, before the no-decoding constraint) |
| `grs_sid_sun_port_self_01` | `grs_extra_self_12` | `IMG_0822.MOV` | 363–663 | cards; frames identical at the same three times |
| `bch_tri_sun_land_self_01_v4` | `bch_extra_self_18` | `IMG_0612.MOV` | 189–489 | cards and bytes only; **no frame was compared** (it would mean decoding protected footage) |

"Cards" means, for each pair: the Test1 project's card (2026-09-28) names the same original and the same start as the holdout's card; the holdout's video file is byte-identical (size, first and last 4 MB) to the file the Scratch train card was registered from; and the file sizes agree (the third pair to the byte: 884,148,311).

The byte-level audit added by this work (`CONTENT-SHARED`, `CONTENT-DUPLICATE`) and a reading of the cut history through Test1's `project.json` found six more pairs, all train with train, none reserved:

| Pair | Original | Shared stretch | Found by |
|---|---|---|---|
| `bch_tri_sun_land_self_01_v2` · `bch_extra_self_06` | `IMG_3014.MOV` | 300 s | bytes |
| `bch_gnd_ovc_land_self_01` · `bch_extra_self_16` | `IMG_0080.MOV` | 300 s | bytes |
| `ind_gnd_dim_land_self_02` · `ind_extra_self_01` | `IMG_0393.MOV` | 300 s | bytes |
| `bch_ele_sun_land_self_01` · `bch_extra_self_04` | `IMG_3606.MOV` | 300 s | cut history only (bytes differ) |
| `bch_tri_sun_land_self_01` · `bch_extra_self_27` | `IMG_4802.MOV` | 300 s | cut history only |
| `ind_tri_bright_land_self_01` · `ind_extra_self_05` | `IMG_3427.MOV` | 219 s | cut history only |

(`ind_sid_dim_land_self_01` · `ind_extra_self_08`, `IMG_0492.MOV`, was confirmed by the owner earlier and already shares a `sourceId`.)

## 2. Root cause

Not stale fingerprints, and no file changed.

1. **A card's stored fingerprint is the file it was cut from, not its own video.** `ProjectsModel.addVideo` fingerprints the source before cutting (`RallyLab/ProjectsModel.swift`, `fingerprint(of: trimmed)`), and the cut is a stream copy (`scripts/fetch_clip.py`, `-c copy`), so the same original, start and length give the same bytes every time.
2. **The train cards are cuts of cuts.** On 2026-09-28 Test1 cut `IMG_0823/0822/0612.MOV`. On 2026-10-07 Scratch's train cards were registered with those Test1 clips as their origin, start 0: their stored fingerprints are the Test1 clips' (`2b8e3ef5…`, `2b5e67ca…`, `b4c20573…`), their own files a second generation with other bytes (`d5e0ea95…`, `3b5821a6…`, `ac0d890e…`), and the link to the original was lost.
3. **The holdouts were cut from the originals again.** On 2026-10-17 the album import registered `grs_extra_self_06/12` and `bch_extra_self_18` from the same originals at the same starts: stored fingerprints the originals' (`d04cff74…`, `136b3de8…`, `d7690d3e…`), video files byte-identical to the Test1 clips — the bytes the train cards were registered with.
4. **No check compared the two sides in the one combination that matches.**
   - The alias closure (`ReservedVideos.identities`), the split manifest's groups and the leakage audit compare stored fingerprints and confirmed sourceId / sessionId / venueId. Train: `{fp:2b8e…}`. Holdout: `{fp:d04c…, ses:2022-10-09, ven:grass-florida-jacksonville}`. Disjoint.
   - The L2 preflight's `sources-not-protected` held each packaged clip's **current content** (`d5e0…`, `3b58…`, `ac0d…`) against the withheld identities. Those identities were complete — the record's `protectedSourceFingerprints` (42) contains `2b8e…`, `2b5e…` and `b4c2…` — and the plan's own `eligible` entries carry `fp:file:2b8e…`, `fp:file:2b5e…`, `fp:file:b4c2…`. The check never looked at them. Exactly three eligible clips in that record have a stored fingerprint in the protected set: these three.
5. The audit did say the relation was unknown (`LINEAGE-UNKNOWN-RELATIONS`, info): the three train cards have no confirmed venue or session. Nothing blocked on it.

Ruled out: files changed after registration (the L2 record of 2026-10-25 holds the same content fingerprints as today; the `Cache/marking` copy is a SHA-256-verified copy with the same fingerprint); caches (`FileFingerprintCache` and `ProjectsModel.fingerprintCache` are in memory, never persisted); the unreachable-share hole fixed by PR #171 (not involved on 2026-10-25).

## 3. Reach: packages, runs, checkpoints

Kept apart: in a package · a run trained on it (gradient exposure) · used to select (validation) · inference only (pre-tracking, ball path, net proposal) · evaluated on the holdouts themselves.

| Package | Status | The three train copies in it | Runs that consumed it | Checkpoints |
|---|---|---|---|---|
| `Scratch-multiframe-20261016-2018` (L1; before the holdouts existed) | complete (zip sha256 `a6abd1ba…`) | train: ele 1,113 windows / 2,334 frames · sid 462 / 954 · bch_tri_v4 in the ledger | 4 from-scratch runs | `scratch_768_gray_1016` (`9f7d4f1f…`, in the model library), `scratch_768_1016`, `scratch_768_aug_1017`, `scratch_768_seed1_1017` |
| `Scratch-L2-multiframe-20261021-1917` (L2) | complete, preflight 13/13 | train: ele 1,113 / 2,334 · sid 462 / 954 · bch_tri_v4 246 / 537 | `l2_scratch_768_color_s20261021` | `best.pt` `d736147b…`; mlpackage digest `8cb1bbca0c2729a8` (model library; not bundled) |
| `Scratch-net-20261102-0129` | refused by the trainer before training | one frame each (ledger) | none | none |
| `Scratch-net-20261102-0140` | complete (record sha256 `67d60f66…`) | one frame each, in **val** groups | `net_v1`, `net_v1_extra`, `net_v2`, `net_v2_aug`, `net_v2_res` | in `Reports/net-v1`, `net-v2` only; not bundled |

**Confirmed gradient-training exposure:** `l2_scratch_768_color_s20261021` (L2 — its premise does not hold for `grs_extra_self_06`, `grs_extra_self_12`, `bch_extra_self_18`), and the four Oct 16 L1 runs (L1 claimed no isolation from them).

**Confirmed selection exposure, no gradient exposure:** the five net runs (the copies' groups are in the validation split, so the net H1 numbers include footage that duplicates two holdouts).

**Potential, not provable from the Mac:** the shipped `ball_heat` = `scratch_768_1014` (canonical digest `09620ab77519bd9d`) and its siblings trained on `Scratch-multiframe-20261014-0006`, which is no longer on the Mac and has no ledger row; the train cards were in the project from 2026-10-07. Earlier L1 heat models likewise.

**Unknown:** which model wrote any machine track (every `pre_tracking` row says "model not recorded"); the desktop's run folders and queue records (not reachable during the audit).

**Evaluated on the three holdouts:** nothing, ever. Each has one ledger row (`pre_tracking`, 2026-10-17/18), no reviewed frame, no rally mark. No published number rests on them; L2's H1 (ΔF1 on the package's 13 val recordings) is unaffected as development validation.

The other 13 lineage holdouts carry only `pre_tracking` rows (six of them a second row dated after the cut-over, 2026-10-28 … 11-07, cause not established on 2026-11-10; established since — no model ran, §8.4). None is pristine; none is a final test (D-016, D-017).

`rc-v1-20261108` records its detector as `ball_heat`, canonical digest `d4aeac1583ab4cec`: that is the digest of the compiled model inside one build (six local builds give six digests); its weights are byte-identical to the bundled `scratch_768_1014`. The recorded digest is build-dependent and not a stable model identity.

## 4. The correction (Option A), prepared and not applied

Through the established mechanism — a confirmed `sourceId` shared by both cards (`RallyLab --set-provenance`, D-009; precedent `IMG_0492`) — nothing else in `project.json` changes, and nothing is deleted:

| Videos | `sourceId` | Effect |
|---|---|---|
| `grs_extra_self_06`, `grs_ele_sun_land_self_01` | `IMG_0823` | the train card becomes `lineage_holdout`, reserved as an alias |
| `grs_extra_self_12`, `grs_sid_sun_port_self_01` | `IMG_0822` | same |
| `bch_extra_self_18`, `bch_tri_sun_land_self_01_v4` | `IMG_0612` | same (found during this work; the owner's Option A named the first two pairs) |
| the six train/train pairs of §1 | `IMG_3014`, `IMG_0080`, `IMG_0393`, `IMG_3606`, `IMG_4802`, `IMG_3427` | grouping only: one alias group each, so no grouped split or fold parts them |

On the isolated copy (all nine pairs applied; `isolated-copy-evidence/` in the report folder): withheld closure 21 → 24 names; train 133 → 130; `lineage_holdout` 16 → 19; all 21 earlier names still withheld; the exposure ledger byte-identical before and after, and every video's exposure rows unchanged in the manifest; `project.json` differs in the eighteen `sourceId` fields only; audit: no hard finding, `LINEAGE-HOLDOUT-TRAINED` (soft) on the six lineage rows. The cut-history reading of the live `project.json` (`cut-history-relations.json`, nothing decoded) lists the same nine pairs and the earlier `IMG_0492` one. Before the correction the same build reports three hard `CONTENT-SHARED` findings and exits non-zero.

## 5. Consumers

After the correction every live guard refuses the three copies by name (they are in the closure both `reservedNames` and `lineageWithheldNames` compute). What does not, and what is done about it:

| Gap | Status |
|---|---|
| L2 plan and preflight compared one side by content, the other by stored identity | fixed here: both of a clip's file identities on both sides (`LineagePackage.identities`, `sources-not-protected`) |
| The audit had no content comparison and no finding for a holdout in a training package | fixed here: `CONTENT-SHARED` (hard), `CONTENT-DUPLICATE`, `CONTENT-UNREADABLE` (soft), `CONTENT-ABSENT` (info), `LINEAGE-HOLDOUT-TRAINED` (soft) |
| `--export-training-data` ignores reservations; `HeatmapLab.evaluate`, the Pipeline tab's debug export, Label-tab tracking and sampler ingest have no guard; `ReservedVideos.sources(in:)` reads an unreadable `project.json` as empty | separate PR #175 (`fix/withheld-guards-unguarded-consumers`) |
| Artefacts already written keep verifying against the closure they froze (the built L2 package; `rc-v1-20261108`; `.trainingdata.json` sidecars) | open — §6 for the classifier dataset; the L2 package must not be trained from again as a holdout-clean lineage |
| The copies' frames and labels stay under `images/train` / `labels/train`; `data.yaml` still points there | open — unsupported for lineage training since D-018, and still a folder a trainer can be pointed at |
| Guards on `reservedNames` alone (pre-tracking, `ModelLibrary.evaluate`, HeatmapLab scoring and rendering, ball paths, the legacy packagers, the Pipeline and Compare tabs) do not cover the legacy `holdout` list or its aliases | open — an owner policy question (the legacy holdout is L1's scored test set), not this pair |
| `DeciderRetune` and `train_net_model.py` read a split manifest without checking that it is current | open |
| The copies' rows and uploaded videos on the labeling server stay after they become withheld | open |
| Net labels, footage-properties records and AI proposals are bound to the stored fingerprint: the three train cards' rows carry the holdout videos' identity | open — owner decision |

## 6. The classifier dataset `rc-v1-20261108`

- None of the 49 recordings is in the corrected closure by name, confirmed sourceId, stored fingerprint or current content; none changes split; all 49 files were read.
- No pair of §1 has both members in the dataset (one member each of `IMG_0080`, `IMG_0492` and `IMG_3606`); its 25 groups each sit in one split; no content fingerprint repeats inside it. It has no folds (`fold` is unset on every recording): the preregistered grouped folds are made later, from `groupId`.
- `validate_dataset.py` passes it against the closure it froze (21 names, 5 sourceIds, 42 fingerprints) and **fails** it against the corrected closure passed with `--withheld` (24 / 8 / 45): "the export ran against a smaller closure". That rule is by design.
- So: its contents are consistent with the corrected policy, and its record is not. Training from it needs either a new export after the correction is applied (same recordings expected; a new digest) or the owner's explicit acceptance of the older record. Not regenerated here.
- Its detector trained with potential exposure to the copies (§3); the three copies and their holdouts are not in the dataset.

## 7. Limits

- A re-encode or a different export of a recording, with no card naming the same original, is invisible to every check above. The content-lineage prototype (`scripts/content_lineage/audit.py`, PR #174) compares motion over time and proposes. Run over the 142 unreserved recordings it could read (one was not read), it proposed the seven train-with-train pairs of §1 and no other; it has not been run against any reserved recording, so no reserved recording is cleared by it.
- The third pair rests on cards and bytes, not on pictures.
- The cut-history check needed Test1's `project.json`; a card whose origin file and whose origin's project are both gone cannot be traced.
- The desktop was not inspected.

## 8. Applied to the live project, 2026-11-12 (owner authorisation of 2026-11-12, §4; D-037)

Written after the sections above, which stand as they were on 2026-11-10.

### 8.1 What was done

- Before: no RallyLab project app or headless project run open (a Player Lab research window of another session was open over its own experiment folder; it opens no project and was left alone — the one line of the apply script that changed excludes it, and the unchanged script is kept beside it); the footage share mounted and every one of the 167 clip files reachable; the backup of 2026-11-10 verified against its 539 SHA-256 sums; the live `project.json`, manifest, audit, exposure ledger, `validation.json`, net labels, all 168 session files and all footage-properties records byte-identical to that backup; all eighteen cards present with no confirmed `sourceId`.
- Applied with the build of `main` at `284a8d1` (PRs #172, #173, #175, #174 merged): eighteen `RallyLab --project Scratch --set-provenance <video> --source-id <id>` runs, each answered "Provenance saved", then `--manifest --audit-dataset`. Started 2026-11-13T00:35:43Z (17:35 MST on 2026-11-12), finished 00:53:59Z.
- That first audit could not read three train recordings (`bch_extra_self_01`, `_08`, `_25`: `CONTENT-UNREADABLE`, a stalled share). The manifest and audit were run again at 01:32Z with the share remounted: all 167 read.

### 8.2 Result

| Check | Expected | Found |
|---|---|---|
| Withheld closure | 21 → 24 | 24 |
| Train | 133 → 130 | 130 |
| `lineage_holdout` (16 listed + aliases) | 16 → 19 | 19 |
| `dev_val` · `tune` · `legacy_holdout` | unchanged | 7 · 6 · 5 |
| Hard audit findings | 0 | 0 (15 soft, 25 info; `LINEAGE-HOLDOUT-TRAINED` × 6, as designed) |
| Content read | every recording | 167 of 167 |
| Exposure ledger | byte-identical | byte-identical (`2574ead797fce420`, 787 rows) |
| `project.json` | eighteen `sourceId` fields and nothing else | 18 cards changed, the one field each; every other card, clip and project field equal |
| Everything else in the project | unchanged | of 1,124 metadata files hashed before and after (sessions, marks sidecars, footage properties, net labels and proposals, ball paths, tuning, scores, ledgers), five differ: `project.json`, `manifests/manifest.json`, `manifest.md`, `audit.json`, `audit.md` |

Hashes after: project.json `bc6a5fccdb55e3f3`, validation.json `cc22cd32c5f7aee5` (unchanged), manifest.json `fb6b540cb2bc0576`. Evidence: `~/Movies/RallyLab/Reports/d017-correction-20261110/` — `applied-20261113T003544Z/` (the four files as they were, `apply.log`, `audit-rerun.log`), `scratch-metadata-{before,after}-20261112.SHA256SUMS`, `apply-d017-correction-20261112.sh`.

### 8.3 The nine pairs and their overlapping stretches

From the cards' cut history (`project.json` of Scratch and Test1; nothing decoded). A pair now shares a confirmed `sourceId`, so an alias group, a classifier group and a fold.

| `sourceId` | Recordings | Stretch of the original (s) | Same footage (s) | Footage only one of them has |
|---|---|---|---|---|
| `IMG_0823` | `grs_extra_self_06` (lineage holdout) · `grs_ele_sun_land_self_01` (now withheld) | 211–511 both | 300 | none |
| `IMG_0822` | `grs_extra_self_12` (lineage holdout) · `grs_sid_sun_port_self_01` (now withheld) | 363–663 both | 300 | none |
| `IMG_0612` | `bch_extra_self_18` (lineage holdout) · `bch_tri_sun_land_self_01_v4` (now withheld) | 189–489 both | 300 | none |
| `IMG_3014` | `bch_extra_self_06` · `bch_tri_sun_land_self_01_v2` (train) | 89–389 both | 300 | none |
| `IMG_0080` | `bch_extra_self_16` · `bch_gnd_ovc_land_self_01` (train) | 87–387 both | 300 | none |
| `IMG_0393` | `ind_extra_self_01` · `ind_gnd_dim_land_self_02` (train) | 346–646 both | 300 | none |
| `IMG_3606` | `bch_ele_sun_land_self_01` · `bch_extra_self_04` (train) | 570–870 both | 300 | none |
| `IMG_4802` | `bch_extra_self_27` · `bch_tri_sun_land_self_01` (train) | 421–721 both | 300 | none |
| `IMG_3427` | `ind_extra_self_05` · `ind_tri_bright_land_self_01` (train) | 579–879 · 660–960 | 219 (660–879) | 81 s each: 579–660 and 879–960 |

Five train/train pairs are one stretch twice: using both members in one training set counts that footage double, so a dataset takes one member of each (the classifier dataset has at most one member of any pair; §6). `IMG_3427` is two stretches that share 219 s: the 81 s either side are distinct footage and are not discarded; a dataset that takes both members counts the shared 219 s once. No recording was removed.

### 8.4 The six `pre_tracking` rows dated after the cut-over

They are not pre-tracking runs. They are in `manifests/manifest.json` only (the ledger and its seed hold no `pre_tracking` row): manifest discovery writes one row per session that has machine tracks, dated the day of the newest track's `updatedAt` (`DatasetSplitManifest.swift`, the discovery of session tracks), and `updatedAt` moves on any edit or sync of a track. What moved it, per recording (Mountain Time):

| Recording | Row date (UTC) | What happened | A model ran |
|---|---|---|---|
| `bch_extra_self_31` | 2026-10-28 | the owner checked five frames in annotation review (server frame log, 09:06 MDT) | no |
| `bch_extra_self_29`, `bch_extra_self_30` | 2026-10-29 | one Mac–phone sync round pushed the existing tracks (09:16 MDT) | no |
| `ind_extra_self_09`, `grs_extra_self_21`, `ind_extra_self_06` | 2026-11-06, 11-07, 11-07 | the owner's "mark the rallies" pass on the Mac; tracks changed in `isRally` and trim only | no |

No ball path, no `ball_path` row and no ledger row of any kind exists for any of the 16 after the cut-over; pre-tracking has skipped lineage holdouts since 2026-10-21. No model or evaluation number is affected. Three statements in the records are now incomplete and are corrected here, not rewritten there: `bch_extra_self_31` has five human-checked frames (the manifest's `reviewedFrames` counts sampler frames only); `grs_extra_self_21`, `ind_extra_self_06` and `ind_extra_self_09` have the owner's complete rally marks (on the Mac); the phone copies of `bch_extra_self_29`, `_30` and `_31` were readable by three labelers from their upload on 2026-10-22 until migration 049 (2026-10-27) — human access, not model exposure. Not known: which model wrote the tracks on 2026-10-17, and whether any labeler opened those clips.

### 8.5 Corrections to §3 and §5 (found by the inventory of 2026-11-12)

- §5 says the copies' frames stay under `images/train` of Scratch. They do not: Scratch's `images/` and `labels/` hold none of the six recordings. They are in `excluded/images/train` of Scratch (61 frames of the three copies, 22 of `grs_extra_self_12`), which the project-dataset writer can move back in, and in the archived **Test1** project's `images/train` and `labels/train` (55, 70 and 70 reviewed frames of the three copies), whose `data.yaml` carries no lineage warning.
- §3 puts the copies' net frames in the validation split of `Scratch-net-20261102-0140`. For `bch_tri_sun_land_self_01_v4` the Mac's records (the ledger and the runs' `split.json`) do not show it among the 36 validation videos: it was probably in the **train** split of the five net runs — gradient exposure of one frame. The dataset record that would settle it is on the desktop; until it is read this is likely, not confirmed.
- `scripts/desktop_training/desktop.sh train` with no package named takes the newest `*-multiframe-*.zip` in `Scratch/exports`, which today is `Scratch-multiframe-20261016-2018.zip` — a package that holds the three copies and has no manifest.

## 9. What stays open after the application

| Item | State |
|---|---|
| Guards that read the smaller reserved set; registration of a reserved card; stale manifests and packages; the project-dataset writer | follow-up PRs (D-037 §3–§5), each merged by the owner |
| The labeling server | its withheld list for Scratch holds 21 names until the Mac next syncs with the project open; until then an ordinary labeler can still read the three copies' rows and clips (`bch_tri_sun_land_self_01_v4` is an open marking job). After the sync, row-level security stops ordinary labelers; the lead account is exempt from it and the sync and queue code has no filter of its own (a follow-up PR). Removing or re-statusing the three rows, their tracks and storage objects, or changing the lead exemption, are separate owner decisions |
| Records bound to a stored fingerprint (net labels, AI proposals, footage properties of the three copies) | none is keyed by `sourceId`; every lookup is by name; they still bind to the footage they were made on, and none is invalidated. The three cards' stored fingerprint is the holdout file's content hash, which is harmless only because nothing resolves these records by content |
| Artefacts that hold the copies | kept, none deleted: the L1 zip, the L2 package (desktop) and its record, the net datasets (desktop), Test1's dataset folder, `models/heatmap/` (the model library has no exposure field). Marked by the audit's `LINEAGE-HOLDOUT-TRAINED` on every run; the trainers' refusal is in the follow-up PRs |
| The desktop (`D:\RallyLabStaging`, `C:\BallTraining`) | not inspected: run folders, the L2 package folder, the net dataset record, older L1 packages. Ancestry that depends on them stays unknown |
| The ProcessedMetadata leak (PR #173) | closed: the 905 files (5,901,282,658 bytes, every one `<UUID>.json` or `<UUID>_checkpoint.json` written by an analysis run under a random id) were inventoried and deleted on 2026-11-12, 5.6 GB recovered; a pipeline run of the `284a8d1` build over a 12 s synthetic clip (360 frames processed) left the folder empty. Inventory: `~/Movies/RallyLab/Reports/processed-metadata-cleanup-20261112/` |
| The protected recordings' pictures | compared once, by the owner's authorisation: [EXP-20261112-protected-content-lineage-audit](EXP-20261112-protected-content-lineage-audit.md) |

