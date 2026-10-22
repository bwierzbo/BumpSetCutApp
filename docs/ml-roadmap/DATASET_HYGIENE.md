---
name: dataset-hygiene
status: open issues recorded; cleanup proposed, not approved
created: 2026-10-22T02:05:00Z
updated: 2026-10-22T02:05:00Z
---

# Dataset hygiene: known inconsistencies in the Scratch project

Known gaps between what the sessions say and what the dataset folders hold. None is touched without a reviewed change (owner decision 2026-10-22: "Any future cleanup should be a separate, reviewed change with a preserved backup and verification that no valid annotations or provenance are lost"). The L2 export records them (`l2-manifest.json` → `preflight.danglingProtectedRecords`, `protectedFrameFiles`) rather than silently working around them.

## H-1 — `grs_onl_dusk_land_onl_03` (legacy holdout): 54 frame records with no file

| Fact | Value (2026-10-22) |
|---|---|
| Session | `sessions/grs_onl_dusk_land_onl_03.json`, split val, `legacy_holdout` in the manifest, added 2026-10-06T23:34:05Z |
| Frame records | 55, all `keep: true`, `reviewed: false` (sources: 18 `missed`, 9 `random`, 28 `rally:N`), times 1.875 s … 288.06 s |
| Files on disk for that name | 28 under `excluded/images/val/`, all dated Oct 6 2026; 0 under `images/val/`; 0 labels |
| Records whose file exists | 1 |
| Records whose file exists nowhere (kept or parked) | **54** |
| Files with no record (orphans) | **27** (e.g. `…_0000_250.jpg`, `…_0008_500.jpg`) |
| Reading | the recording was sampled twice: the Oct 6 ingest wrote the 28 files; a later re-sample replaced the records with 55 new frame times but its images were never written (or were written elsewhere and lost). Only this session is affected; every other session's records have their files (479 withheld records checked, 2,738 eligible). `bch_onl_sun_land_onl_03` has 40 orphan files with records intact |
| Effect today | none on training (unreviewed frames are never labels); the L2 preflight hashes the 28 files that exist (orphans included) and notes the 54 dangling records; the manifest counts `frames: 55, reviewedFrames: 0` |
| Exposure history | pipeline tuning holdout; pre-tracking 2026-10-16; rally scoring 2026-10-12; val clip of the Oct 16 packages — unchanged by any of this |

### Proposed cleanup (separate PR, not approved)

1. **Backup first**: copy `sessions/grs_onl_dusk_land_onl_03.json` and the 28 image files to `manifests/backups/<date>/grs_onl_dusk_land_onl_03/` with a SHA-256 list; commit the hash list with the PR.
2. **Change**: remove the 54 frame records whose file exists neither at `images/<file>` nor `excluded/images/<file>`, through a headless RallyLab command that reports every record it drops (name, file, time, source) — not by hand-editing JSON. Keep the 1 record with a file. Do **not** delete the 27 orphan files (they are the Oct 6 frames of a protected recording; they stay parked and hashed).
3. **Verify, before and after**: 0 reviewed frames, 0 labels, tracks unchanged (2 machine tracks, byte-identical), rally marks unchanged, exposure rows unchanged, `project.json` untouched; the manifest's `sessions` digest changes and the new value goes into the registry; the L2 plan/preflight for the next package shows 0 dangling records and the same 28 (or 452 total) protected files.
4. **Record**: a note in `EXPERIMENT_REGISTRY.md` and in this file, with the backup path and the two session digests.

Not in scope: re-sampling the recording (it is withheld; running the sampler would count as exposure), deleting orphan files, touching any other session.
