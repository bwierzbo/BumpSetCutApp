---
name: rallylab2-phase0-audit
status: living (CF-BSC-006); Phase 0 of the RallyLab 2.0 overhaul (owner direction 2026-11-02; D-031 proposed)
created: 2026-11-03T02:42:42Z
updated: 2026-11-03T04:40:00Z
decision: D-031 (proposed)
---

# RallyLab 2.0 — Phase 0: architecture, data ownership and the stall investigation

The owner's direction of 2026-11-02 ([verbatim](../decisions/2026-11-02-rallylab2-overhaul-direction.md)) asks for a crash and architecture audit before any rebuild, with evidence, and for narrowly scoped reliability fixes where the evidence supports them. This is that audit, written in the Phase 1 worktree before Phase 1 was built, and updated with what Phase 1 delivered. Everything measured here was measured read-only against the live Scratch project and the running app; nothing under `~/Movies/RallyLab` was modified (one caveat in §4.6).

## 1. What was looked at

Read: `AGENTS.md`, `CLAUDE.md`, the working agreement, configuration management, the decision log through D-027, the roadmap and its amendments, the net, Stage 1 and event-boundary plans, the experiment registry; every open PR and worktree (six other worktrees were active and were not touched); and the RallyLab sources named in the direction plus `RallyLabApp`, `ContentView`, `DatasetStore`, `DatasetSplitManifest`, `EventReview`, `EventInventory`, `ReservedVideos`, `NetLabels`, `RallyBoundariesModel`, `RallyMarkModel`, `ScrubProxy`, `FootageRemote`, the shared `EventReviewRecord`, `RallyTrack`, `LabelQueue`, `TrainingPlan`, the flywheel capture service and migration 036. Two read-only sweeps (one over every persisted artefact, one over every synchronous main-actor file or AVFoundation call) fed §3 and §4.

Not available: a crash report. `~/Library/Logs/DiagnosticReports` and `/Library/Logs/DiagnosticReports` hold no RallyLab crash, hang or spin report, and the unified log of the last 14 days has no crash, jetsam or hang event for the process. The owner clarified during the audit that the symptom is not a crash: "it stalls and I get a loading cursor for a hot minute … it just sat loading for over a min of not being able to do anything" (2026-11-02, about 19:14 MST). That is a blocked main thread, and §4 treats it as such.

## 2. Architecture map (as found)

One process, one window, eleven tabs, every model built once in `RallyLabApp.init` and handed to `ContentView`:

| Model (`@MainActor @Observable`) | Owns | Tabs |
|---|---|---|
| `ProjectsModel` | project.json (cards, videos, provenance), cut/download jobs; opens the last project on launch | Project |
| `SamplerModel` | the dataset root, `sessions: [VideoSession]` (every frame, track and flag of every recording, in memory), the ingest queue, frame review | Import; read by every other model |
| `RallyLabModel` | the Pipeline / Net / Compare / Phase 1 tabs (one video, the pipeline's evidence) | Pipeline, Net, Compare, Phase 1 |
| `ModelLibrary` | models/, exports/, evaluation | Models |
| `TrackLabelModel`, `RallyMarkModel` | dense ball tracks; legacy rally times (`<video>.rallylabels.json`) | Track, Label |
| `RallyBoundariesModel` | Stage 1 review (`<video>.rallyevents.json`) through `EventReview.open` | Review |
| `NetLabelsModel` | net corners (`net-labels.json`), proposals, exclusions | Net labels |
| `LabelingSync` + `ProjectReviewStore` | the phone sync every 30 s, on activation, on every remote save and 1.5 s after each local decision; box fitting after each round | — |
| **`WorkQueueModel`** (Phase 1) | `tasks/work-queue.json`, the source index | **Queue** |

Headless: `RallyLab --project <name> …` runs a command on the main queue and exits (`HeadlessProjects`), so the sync never starts there. The iOS app and RallyLab share the processing pipeline (the files in RallyLab's `membershipExceptions`); nothing in Phase 1 touches a shared file.

Footage: the project folder holds a per-file symlink to the SMB mount of the desktop's footage share (`scripts/footage_share/link_footage.py`); sidecars (`.rallylabels.json`, `.rallyevents.json`) sit beside the symlink on the Mac. So `fileExists(session.sourcePath)` is a stat over SMB, and any read of a video's bytes is a read over SMB — the footage share ran at about 11 MB/s idle and 0.08 MB/s while the app itself was reading from it (§4.2).

## 3. Data ownership

### 3.1 Authoritative files (project folder unless noted)

| Fact | Owner (the one file to change) | Writers | Read strictly? |
|---|---|---|---|
| Cards, videos, origin, licence, file fingerprint, confirmed `sourceId`/`sessionId`/`venueId` | `project.json` (`Project`, `PlannedClip`, `ClipSource`) | `ProjectsModel.save` only (atomic) | `EventReview.projectSourcesStrict` yes; `ReservedVideos.sources` **no** (an unreadable file is an empty map) |
| Frames, boxes, review flags, dense tracks, `ralliesMarked`, `syncedTrackIds`, `notRallies`, `fittedTracks`, `netBox` | `sessions/<video>.json` (`VideoSession`) | `DatasetStore.save` (atomic, whole file from memory) from the sampler, tracker, review store, pre-tracker and sync | `loadSessionsStrict` yes; `loadSessions` (the GUI) **no** (an undecodable session is dropped) |
| Legacy rally times, kind, touches | `<video>.rallylabels.json` beside the footage | `RallyMarkModel`, `RallyLabModel`, `LabelingSync.write` (atomic; the sync overwrites whole, newer file wins) | **no** (`try?`: unreadable = no marks); ids minted on load |
| Stage 1 boundaries, coverage, completion, persistent rally ids | `<video>.rallyevents.json` (`rally_event_truth_v1`) | `EventReview.write` only (validate, atomic); synced by revision with a shadow and conflict files | yes; another version refused whole |
| Reservations (tune, legacy holdout, final test, candidates, lineage holdout) | `pipeline_tuning/validation.json` | **hand-edited; no writer in code** | `loadStrict` yes |
| Exposure (every use of a recording) | `manifests/exposure-log.json` + `.unmerged-*` sidecars + `exposure-seed.json` | `ExposureLog.record` (read-modify-write, atomic; a write failure fails the operation) | yes (ledger) |
| Split manifest, audit, L2 plans and records, export journals | `manifests/`, `manifests/l2/`, `exports/*.journal.jsonl` | the headless commands | yes (ledgers; plans never overwritten) |
| Net corners, exclusions, AI proposals | `net-labels.json`, `net-exclusions.json`, `net-ai-proposals.json` | the tab and `--import-net-ai-proposals` (atomic) | yes |
| Training rounds | `training_plan.json` | `TrainingPlanModel` (`try?`) | **no** |
| Pending phone edits (Mac) | `~/Library/Application Support/RallyLab/pending-*.json` | `LabelingSync` (`try?`) | **no** (unreadable = empty; queued edits lost) |
| **Labeling tasks** (Phase 1) | `tasks/work-queue.json` (schema 1) | `WorkQueue.Store.save` (atomic) from the reconciler and the Queue tab | yes; a duplicate id or another schema is refused |

Supabase (migrations 028–049): `label_videos`, `label_rally_times` (newer file mtime vs server time wins), `label_tracks` (per rally, newer `updatedAt` wins; point identity is the array index), `label_rally_events` (optimistic revision; both versions kept on conflict), `label_withheld*` (replaced whole from the Mac's closure), `label_project_state`, the `labeling` and `training-data` buckets, `tester_footage()` (036). Migration 050 is unapplied and not on main.

### 3.2 Where two files can claim the same fact

Rally boundaries (`rallylabels.json`, `label_rally_times`, `rallyevents.json`, track bounds, `notRallies`, `label_videos.ralliesFound`); "every rally marked" (`session.ralliesMarked`, `label_rally_times.complete`, `rallyevents.stage1Complete`); tracks (session, `label_tracks`, pending queues, phone outbox); split (session, card, manifest, `label_videos`, validation.json, package columns); the withheld set (validation.json; derived in `ReservedVideos`, the manifest, the server list, the phone snapshot — and `BallPathBuilder`/the Pipeline tab refuse only `finalTestNames`, scoring refuses `lineageWithheldNames`); footage identity (card fingerprint, manifest, `label_videos.source_fingerprint`, `rallyevents.sourceFingerprint`, net files, journals); provenance and licence (`project.json` and `footage/meta/sources.csv`, which nothing in Swift reads). `ProjectsModel.moveVideo` carries only the exposure rows to the new id: sidecars, net labels, ball paths and the server rows stay under the old name. Scrub proxies are keyed by the footage file's basename, so two sessions with one basename collide. `--export-training-data` (`TrainingDataExporter`) has no reservation guard and writes no ledger row.

Phase 1's rule for the registry and the queue follows from this: **they own no annotation and no identity.** The source index is rebuilt from the owners above on every refresh and is never read to decide what may be trained, scored or reviewed; the queue records work and reads every state from the annotation files.

### 3.3 Checkpoint counts reconciled (live Scratch metadata, 2026-11-02)

| The direction's checkpoint | Now | Note |
|---|---|---|
| 167 clips | 167 videos on 121 cards; 167 sessions | all with a stored file fingerprint; 73 links, 94 files |
| 145 eligible | 146 admitted = 167 sessions − 21 withheld (16 lineage holdout + 5 legacy holdout; the closure adds no alias). The newest sessions were added 2026-10-17, so the difference is not a later import; 145 most likely counted one recording out for another reason at that checkpoint (not derivable from the files). **Admitted is not per-model eligible:** net export: 146 − 8 handheld − 6 side-view exclusions = **132** labelable; L2 package: 88 admitted recordings have ≥ 1 human-labeled rally today, and only human-labeled rallies enter (D-023); rally classifier: 30 declared-complete recordings (legacy marks) and 0 Stage 1 records; and every recording's per-model footage eligibility is `not_assessed` until it has a footage-properties record (§11) — explicitly unknown, never a pass | verified on the metadata copy, 2026-11-03 |
| 30 eligible clips declared fully marked | 30 (33 sessions carry `ralliesMarked`, 3 of them withheld) | a declaration (`session.ralliesMarked`); **0** `rallyevents.json` records exist on the Mac, so Stage 1 verified coverage is 0 for every recording |
| 25 independent recording groups | 156 alias groups over 167 videos by the manifest's identities (shared file or confirmed source/session/venue); 75 confirmed `sourceId`, 18 `sessionId`, 20 `venueId` | 25 counted groups by venue is not derivable from the files: 144 recordings have no confirmed venue or session (D-017 §5) |
| 466 rallies, 40 missed serves | not recounted here (legacy marks; `--event-inventory` counts them) | |
| — | 257 human-labeled ball-track rallies; 386 pre-tracked rallies nobody has checked; 131 net labels (129 with corners); 124 AI net proposals pending | |

## 4. The stall investigation

### 4.1 Evidence collected

| What | Measurement | How |
|---|---|---|
| Crash, hang or spin report for RallyLab | none, last 14 days | DiagnosticReports (user and system), `log show` |
| The running app (launched from Xcode, project open) over 1.5 h | resident memory 0.8–2.3 GB, swinging by about 1 GB; CPU bursts at 80–100 % lasting 30–60 s every few minutes, idle between | `ps` every 30 s (read-only) |
| A stack sample during the owner's stall (19:14 MST) | empty: the process was attached to Xcode's debugger, so `sample` read no stacks | `sample` |
| Session files | 167 files, 98.4 MB; Swift `JSONDecoder` 0.79 s for all, `JSONEncoder` 0.63 s (release build, mirror types); Python 1.0 s | benchmark on the real files |
| Share: stat of all 167 footage links | 0.92 s cold, 0.015 s warm, with the share idle | timed loop |
| Share: one 4 MB head read | **48.3 s** while the app was reading the share (a scrub proxy being made); 0.36 s with the share idle; 0.03 s read again (SMB client cache) | timed `dd` |
| Session files rewritten | **128 of 167 rewritten within one minute (19:03 MST)**, 2 single edits afterwards | file mtimes |

### 4.2 Confirmed causes (read in the code, cost measured)

1. **The Review tab's inventory, on the main actor, after every commit.** `RallyBoundariesModel.refreshRecordings()` ran `EventInventory.build` synchronously (on appear, on the refresh button and after every committed edit). The build judges every recording by the withheld guard (`EventReview.refusal`), which for every recording whose file is present reads its content fingerprint — 4 MB head + 4 MB tail over the share — plus the 21 withheld recordings' files, so 146 × 8 MB + 21 × 8–16 MB per refresh, with no cache. At the idle share's 11 MB/s that is about two minutes; while the app was also reading the share, 48 s per 4 MB. This matches the owner's "over a minute" with nothing else in sight, and the net plan had already recorded the same read taking half an hour on 2026-10-30.
2. **Every sync round rewrote every session file.** `LabelingSync.syncTracks` called `setSyncedTrackIds` for every video every round, and `SamplerModel.modify` saved unconditionally: 167 encodes and atomic writes (tens of MB) on the main actor with no await between them. The 128 files rewritten in one minute are this; the memory swings are consistent with it and with the full decodes below.
3. **Every sync round decoded every session on the main actor** (`loadSessionsStrict` in `syncRallyEvents`; again, with 167 share stats, in `publishVideos` every tenth round including the first): about 0.8 s of main-thread time per round, more when the share is slow, up to a stall when it has dropped.
4. **The sync's withheld closure fingerprints every session over the share every round, off the main actor.** `publishedWithheldNames` → `refusal` for every session: about 1.3 GB of share reads per round, and rounds follow each other while labeling (every decision schedules one 1.5 s later; every remote save triggers one). This is what made the share busy, and every main-thread share access (1–3, and the view bodies in §4.3) then waits behind it.

### 4.3 Suspected causes (read in the code; latency under load not measured)

- View bodies that stat every recording on the share on every render: the Label tab's Next page (`LabelQueue.Video` → `PlanVideo` → `isOnMac`, plus a rallylabels decode per recording), the Plan and Coverage pages, and the Track tab (`trackableSessions` in the same body as the frame image, so on every frame step). 0.9 s cold with the share idle; unbounded when it is busy.
- Box fitting after each sync (`ProjectReviewStore.fitNewRallies`) draws full-resolution grey frames and fits on the main actor.
- The old net model is loaded twice per recording in the Net labels tab.
- `ReservedVideos.match` (the Pipeline tab's Run) can fingerprint every session's files.
- A project switched while a sync round runs: `syncRallyTimes`, `syncTracks` and `publishPlan` look up sessions by name in the **new** project under the old project's server rows — a correctness hazard, not a stall. `ProjectsModel.close()` cancels nothing (sync, ingest, ball-path building, fitting, open players keep running).

### 4.4 What Phase 1 changed (narrow, each backed by §4.1–4.2)

| Change | Where | Effect |
|---|---|---|
| Per-process **file fingerprint cache** keyed by resolved path, size, mtime and inode: a stat instead of an 8 MB read while the file is unchanged; nothing cached for a missing or unreadable file | `FileFingerprintCache`, `ProjectsModel.fileFingerprint` | causes 1 and 4: the first pass per launch still reads; every later pass is 167 stats. The fingerprint's meaning and every refusal that reads it are unchanged |
| The Review tab's inventory built **off the main actor**, with a generation guard | `RallyBoundariesModel.refreshRecordings` | cause 1: the list updates when ready; the UI stays responsive |
| `setSyncedTrackIds` saves **only when the ids changed** | `SamplerModel` | cause 2 |
| The sync's two session decodes (and the share stats of `publishVideos`) run **off the main actor**; the project is re-checked after each | `LabelingSync.publishVideos`, `syncRallyEvents` | cause 3 |
| A **main-thread watchdog**: every stall of the main thread ≥ 0.5 s is recorded with its length and the activity the main actor had noted (the sync notes its rounds) to the unified log and `~/Library/Logs/RallyLab/stalls.log` | `MainThreadWatchdog`, started in `RallyLabApp.init` | measurement: the next stall says how long and during what, without Xcode |

Not changed (§4.3; each is a separate, reviewable change): the view-body stat sweeps, box fitting on main, the double model load, `ReservedVideos.match`, the project-switch hazard and `close()`.

### 4.5 How the fixes are verified

Build and unit tests (§7). The stall itself cannot be reproduced on demand here — it depends on the share's load — so the acceptance test is the watchdog log: after the owner runs the new build for a labeling session, `~/Library/Logs/RallyLab/stalls.log` lists every stall ≥ 0.5 s with its duration. Target (§9): no stall over 2 s on a Review-tab commit, a sync round or a tab switch with the share mounted and idle; stalls while the share is saturated are expected to shrink to the remaining main-thread share accesses of §4.3, each named in the log by the activity note.

### 4.6 A caveat on the evidence run

The headless `--source-index` and `--work-queue` commands were run on a **metadata-only copy** of Scratch (project, sessions, validation, manifests, net files and sidecars; no footage; paths rewritten to the copy; a 1 KB stand-in file for each withheld session so the content guard had something to fingerprint). Nothing in `~/Movies/RallyLab/Projects/Scratch` was written. One side effect: a headless run records the opened project in RallyLab's preferences (`RallyLab.lastProjectPath`, `RallyLab.datasetRoot`, the known-projects list, opened-at); these were restored to Scratch immediately after each run and verified. The running app was not touched.

## 5. Existing components reused in Phase 1

`ReservedVideos` (closure, groups, expansion, effective fingerprint — the one withheld rule), `PipelineTuner.ValidationSet.loadStrict`, `DatasetStore.loadSessionsStrict`, `ExposureLog.readStrict`/`readSeedStrict`, `DatasetSplitManifest.Hashes`/`sha256`/`canonicalDigest`, `EventInventory.build` (Stage 1 state through the same guard as opening a recording), `EventReview.projectSourcesStrict`, `NetInventory`, `NetLabelStore`, `NetAIProposalStore`, `NetExclusionStore`, `NetLabels.skip`, `LineagePackage.isHumanLabeled` (the one human-label rule), `TrackedRally.isOpen`/`awaitsRallyCheck`, `ClipID.surface`, `DatasetStore.safeName`, `HeadlessProjects` (command dispatch and logging), the existing tabs for doing the work. `NetLabels.status` and `NetLabels.isOffered` were extracted from `NetLabelsModel` so the tab and the queue apply one rule.

## 6. Target architecture, mapped onto the existing stores

| Direction §4 layer | Phase 1 | Later phases |
|---|---|---|
| Footage sources | the cards and sessions as they are; `pulledFrom` for tester cards | 2: five-minute selection; 3: tester intake and phone videos through one intake path |
| Source registry | `SourceRegistry.Index` — derived, rebuildable, no file reads; identity key and confidence; alias group; exact duplicates (same file) and same-source variants (same confirmed `sourceId`, another file); admission state | 3: an intake ledger (append-only) for quarantine, rejection, consent and contribution identity — the only facts no existing file owns; near-duplicate detection beyond the file fingerprint |
| Dataset admission | `admitted`, `withheld` (the closure), `pending_ingest`, `unidentified`; `quarantined`/`rejected` defined | 3 |
| Automated preprocessing | — | 2: pinned pipeline premarking written as proposals beside, never into, `rallyevents.json`; L2 and net task selection |
| Labeling task queue | `WorkQueue` (file, lifecycle, strict store) + `WorkQueueReconciler` + Queue tab + headless | 2: tasks created by intake; 5: the queue becomes the place work starts |
| Human-verified annotations | unchanged: `rallyevents.json`, sessions, `net-labels.json` | — |
| Validation and versioned export | unchanged: `--package-l2`, `--export-net-dataset` | 4: model-specific exporters reading the queue's completion as one more precondition, never as a label |

**No new database.** The queue is one JSON file read strictly and written atomically, like every ledger here; the index is a report. SQLite was considered for the index and rejected for now: the index is rebuilt in 7 s from 167 sessions (measured), nothing queries it concurrently, and a second store for facts the JSON files own would be exactly the competing copy the direction forbids. Revisit when a registry spans several projects and tester contributions (Phase 3), where an append-only intake ledger is needed anyway.

## 7. Phase 1 as delivered

**Code (RallyLab only; no shared-pipeline file):** `SourceRegistry.swift`, `WorkQueue.swift`, `WorkQueueReconciler.swift`, `WorkQueueModel.swift`, `WorkQueueView.swift`, `FileFingerprintCache.swift`, `MainThreadWatchdog.swift`; edits to `ProjectsModel` (cache), `RallyBoundariesModel` (off-main inventory), `SamplerModel` (no-op save), `LabelingSync` (two decodes off main; activity notes), `NetLabels`/`NetLabelsModel` (shared helpers), `ContentView`/`RallyLabApp` (Queue tab, watchdog), `HeadlessProjects` (`--work-queue [--json]`, `--reconcile-tasks`, `--source-index`).

**Rules the queue enforces (tested):** deterministic task ids, idempotent enqueue; the lifecycle table (reconcile may move between any non-cancelled states; a person may retry a failed task, cancel, or reopen a cancelled one; a person cannot declare a task complete); a machine-proposed rally never completes a ball-track task; the legacy "marked every rally" declaration is recorded as `declaredComplete` and never completes a Stage 1 task; a model's net proposal is `needs_review`, never `complete`; a withheld recording's tasks are `blocked` whatever is on file; an unreadable queue, validation file, project file or sessions folder refuses the run and nothing is written; a stale net manifest leaves the net tasks as they are and says so; running the reconciler twice changes nothing the second time; a recording that leaves the dataset blocks its tasks; cancelled stays cancelled.

**On the real metadata (the copy of §4.6):**

| Kind | ready | in progress | needs review | complete | blocked |
|---|---|---|---|---|---|
| Rally boundaries (Stage 1) | 116 | 0 | 0 | 30 (by declaration) | 21 |
| Ball tracks (target 2 human-labeled rallies) | 13 | 23 | 43 | 67 | 21 |
| Net corners | left as they were: the copy's rewritten `project.json` no longer matches the split manifest's hash (the tab's own stale-manifest refusal; on the live project the manifest matches) | | | | |

30 of the 146 Stage 1 tasks are complete by the legacy declaration (`declaredComplete`, coverage not verified; owner 2026-11-03 §9); none has a Stage 1 record. Source index: 167 sources, 156 alias groups, 146 admitted, 21 withheld, 75 confirmed identities, 92 inferred from the file, 0 unknown, 0 exact duplicates, 2 same-source variants. `--source-index` ran in 7.3 s, `--work-queue` in 12.6 s (167 sessions, no share).

**Tests:** `RallyLabTests` 262 executed, 0 failures, 1 skipped (the pre-existing resume benchmark); of these 25 are new (`WorkQueueTests`, `WorkQueueReconcilerTests`, `SourceRegistryTests`, `FileFingerprintCacheTests`). `scripts/build.sh mac` succeeds. `BumpSetCutTests` not run: no iOS or shared file changed.

**Not in Phase 1:** intake, premarking, five-minute selection, tester intake, exporters, any UI consolidation, contact-label task creation (the kind and the per-rally scope exist), per-rally ball-track tasks (Phase 2 selects rallies; Phase 1 counts human-labeled rallies per recording against the policy's target of 2, configurable in the queue file).

## 8. Migration and compatibility

No migration. No existing file changes shape; `tasks/work-queue.json` and `manifests/source-index-*.json` are new files the old build ignores. Rollback is deleting `tasks/` (the queue is rebuilt by the next reconcile from the annotation files) and reverting the branch. The iPhone Labeler is untouched (no shared file changed; no sync rule changed). Legacy projects (Test1-era cards, single-`source` cards) decode as before (`LegacyProjectDecodingTests`); the reconciler tolerates a project with no `project.json`, no `validation.json` and no manifest. The queue file's schema version is checked on read; an unknown version is refused, never half-read.

## 9. Acceptance criteria (measurable)

Stability (owner's build, a normal labeling session, the share mounted):
- `stalls.log` shows no stall ≥ 2 s on a Review-tab commit, a sync round, or a tab switch while the share is idle.
- The Review tab's list refreshes after a commit without the beachball; the refresh is visible as "refreshing" and lands within the first pass's share time.
- Session files are rewritten only when they changed (mtimes after a sync round with no edits: unchanged).
- Resident memory no longer swings by about a gigabyte on every round (sampled with `ps` as in §4.1).

Queue:
- `--reconcile-tasks` twice in a row: the second reports 0 created, 0 changed.
- A pre-tracked rally confirmed as a rally with no checked frame never counts; a legacy declaration completes the boundary task with `verifiedCoverage` nil, a Stage 1 completion with it set; a withheld recording's tasks are blocked in every kind, net corners included, whatever the manifest says.
- `--work-queue` on the live project reads no video bytes after the first pass of the fingerprint cache (second run time ≈ the copy's 12.6 s).

## 10. Remaining work and decisions for the owner

By phase (each needs a go-ahead): **2** — intake path, five-minute selection, pinned premarking as proposals, L2/net task selection (needs: which pinned model and config; whether the ball-track target is 2 or 3). **3** — Scratch compatibility pass, tester intake through `tester_footage()` with consent verification (the flywheel dedupes per user and video, not across users; "posted by user and day" is not a source identity; the tester default consent is `tester-2.0` but historical consent is not proven), cross-source deduplication, deletion requests; any backend change is a separate proposal. **4** — exporters. **5** — UI consolidation and the §4.3 list.

Decisions requested now:
1. Accept D-031 (proposed) and the direction note as the primary record.
2. Approve the Phase 1 PR for merge after Codex review, or not.
3. Whether the §4.3 hazards get their own PRs before Phase 2 (recommended: the project-switch-during-sync hazard and the view-body share stats first).
4. The default ball-track target per recording (2 now, configurable per project in `tasks/work-queue.json`).

## 11. Edited footage, camera motion and training eligibility (owner direction of 2026-11-02, evening)

The second direction ([verbatim](../decisions/2026-11-02-rallylab2-edited-footage-direction.md)) arrived while this PR was being prepared. **It changes neither the architecture nor the order of the phases.** It adds one stage between admission and premarking — *characterisation* — and one more precondition for every exporter. Phase 1 takes only what the direction asks for a PR already underway: the record, the policy and the registry's verdicts, with tests; nothing runs over the corpus.

### 11.1 Design

- **The record** — `footage-properties/<video>.json` (`FootageProperties.File`, schema 1, read strictly, written atomically, validated): the recording's type as a person confirmed it (`continuous`, `edited`, `unknown`), **spans** (seconds, or the whole recording) each carrying one or more coexisting **traits** — camera: `fixed_camera`, `normal_panning`, `aggressive_panning`, `handheld`, `digital_zoom`, `camera_angle_change`; time: `normal_speed`, `slow_motion`, `replay`, `montage`, `dead_time_removed`; other: `overlays`, `unknown` — with an **origin** (`proposed` by a detector or `confirmed` by a person), a confidence, what proposed it, and a `rejectedAt` that keeps a rejected proposal on file counting for nothing; and **`derivedFrom`** (the original's video id or identity key, and the relation: highlight, crop, slow-motion replay, other camera, re-encode). Nothing else owns these facts; the file is a new owner, not a copy.
- **The policy** — `TrainingEligibility.assess(admission:properties:)`: per model (`rally_classifier`, `ball_detector`, `net_detector`) a verdict `standard` / `restricted` / `quarantined` / `not_assessed` / `ineligible` with its reasons, and a separate verdict for **full-video negatives** (whether the recording's unmarked time may be ordinary non-rally examples). The direction's table is `TrainingEligibility.rule(trait, model)` and `negativesRule(trait)`, in one place, so a controlled experiment changes a rule without touching an exporter. Conservative defaults: no record → `not_assessed` (an explicit unknown, never a pass); only a person's confirmation of the recording type (continuous or edited) establishes eligibility — a recording of unconfirmed type stays `not_assessed` whatever a scanner proposes about it, with any proposed restriction kept in the reasons (Codex on #134, second review: a proposed `fixedCamera` span used to turn `not_assessed` into `standard`); a proposal restricts and never clears, quarantines or establishes; a rejected proposal counts for nothing; a confirmed `unknown` quarantines, which is the one thing that resolves `not_assessed` (something known to be wrong wins over nothing known); `edited` with no spans restricts the temporal models and the negatives; `unknown` type keeps the negatives `not_assessed` however complete the marks are declared; withheld → `ineligible`; a derivative of a withheld recording → admission `quarantined`.
- **The registry** carries `recordingType`, `derivedFrom` and `eligibility` per source, and `--source-index` summarises eligibility per model. An unreadable properties record quarantines its recording (fail closed) and is listed under problems.
- **Completion ≠ eligibility**: the queue keeps `declaredComplete` (legacy marks) and `verifiedCoverage` (Stage 1) as facts about annotation; the registry's negatives verdict is a fact about footage; an exporter (Phase 4) needs both.

### 11.2 Reuse

`EventReview.Span` (Stage 1's `nonRallyActivity | transition | uncertain` spans inside reviewed coverage) is the precedent for time-span records and stays separate: it says what a person saw in play; the footage record says what the footage is. The other instance's **`CutRange`** (branch `feat/cut-ranges`, local commit `6fe6dad`, not on `main`; it labels itself D-030, which is why this entry is D-031) is a person's mark in the live pass of a stretch that is *not footage*, stored on the session and in `label_rally_times.cuts`, with the range algebra every consumer of a recording's time reads (`outside`, `overlaps`). Phase 2 should map confirmed time-breaking spans (`slow_motion`, `replay`, `montage`, `camera_angle_change`) onto that algebra rather than add a second masker, and the two PRs should be reconciled on one owner of "this stretch is not real time" — a decision for the owner (§11.4). `FrameIdentity.allFrameTimes` (frame presentation times) is the right input for timestamp-irregularity and duplicate-frame detection in Phase 2; the other instance's scan of 2026-11-02 (`~/Movies/RallyLab/Reports/edited-footage-20261102/scan_results.json`: duplicate-frame fraction, slow segments with speed ratio, hard cuts, zoom segments per recording) is a ready source of *proposals* for the first import, as `proposed` spans with their confidence, never confirmations. `NetLabels.skip(.handheld)` is the net model's existing handheld rule and the policy agrees with it. `LineagePackage`/`MultiFramePackage` build the temporal windows the policy constrains; Phase 4 adds "no window inside or across a confirmed time-breaking span".

### 11.3 Where the rest goes

The guards that train or export (D-017: the withheld closure in `ReservedVideos`, the L2 preflight, the exposure ledger, the split manifests) do not read the footage-properties derivations yet: a derivative of protected footage is quarantined by the index and, since the owner's instruction of 2026-11-03, receives no actionable task from the queue, but the Label, Track, Review and Net tabs opened directly still know only the withheld closure. Folding derivative lineage into every consumer is phase 3, separately reviewed.

Phase 2: the detection job (scene cuts from frame differencing, duplicate-frame runs from the frame-time digest, zoom from global motion; bounded, cancelable, resumable; writes `proposed` spans only), the import of the 2026-11-02 scan as proposals, and the properties UI (§9 of the direction: type, camera, cuts, replays, slow motion, zoom, completion, per-model eligibility with reasons; a labeler reviews only uncertain or consequential proposals). Phase 3: `derivedFrom` becomes an identity edge in the guard closure (`ReservedVideos.identities`) so a derivative of a withheld recording is withheld by every consumer, not only quarantined in the index — a change to the D-017 closure, so an owner decision. Phase 4: exporters read the spans (no L2 window inside or across a time-breaking span; slow-motion frames only into a single-frame dataset; net labels carry the crop geometry; negatives only where `fullVideoNegatives` is `standard` and Stage 1 is complete).

### 11.4 Decided by the owner on 2026-11-03

- **Ownership.** `FootageProperties` is authoritative for characterising source media; `CutRange` (PR #135) is authoritative for the effective timeline exclusions every consumer applies. One exclusion mechanism: a confirmed time-breaking span is a reason to mark a cut range, never a second mask; the existing cut-range schema is kept; a manual exclusion of a clip's initial partial rally is not a classification as edited footage. Coordination with PR #135 before Phase 2.
- **Handheld and heavily panned footage** stays restricted for initial temporal training, not discarded (the policy's current rules).
- **L2 target:** 2 fully human-reviewed rallies per eligible recording, configurable; a third allowed for model difficulty and dataset diversity (Phase 2's selector).
- **"Marked every rally"** declarations remain valid development-label evidence under the conditions already defined; the owner does not redo them to adopt Stage 1 completion. The boundary task is complete by declaration, `verifiedCoverage` stays a separate fact.

### 11.5 Historical experiments and the edited recordings (documented, nothing modified)

The other instance's scan of 2026-11-02 found editor-added slow-motion replays and zooms inside YouTube-sourced files: clear — `grs_gnd_shade_land_self_02_v2` (half-speed replays at about 83–85, 91–94, 115–125, 142–157 s), `grs_sid_sun_port_self_01_v2`, `grs_ele_sun_land_self_01_v4`, `grs_onl_sun_land_onl_04_v2`, `bch_gnd_sun_land_self_02_v4`, `bch_gnd_sun_land_self_02_v6`, `bch_ele_sun_port_self_03` (dev_val), `grs_tri_sun_land_self_01_v2`, `grs_ele_shade_land_self_02`; borderline — `grs_ele_dusk_port_self_03`, `grs_onl_dusk_land_onl_03`, `bch_gnd_sun_land_self_02_v5`, `grs_sid_shade_land_self_02`. These are scanner findings, not confirmed spans. Most of the clear ones are in the L2 package `Scratch-L2-multiframe-20261021-1917` (EXP-20261021-l2-scratch-prereg) and some in the tuner's pools, so those experiments' windows may include replayed or zoomed frames and their timing: a **limitation of the historical results**, recorded here; the frozen records, the package, the labels and the splits are not modified (owner, 2026-11-03 §6). The experiment registry's rows are left as they are; a docs PR may add the same limitation sentence to the registry if the owner wants it there.

### 11.6 Unresolved decisions

1. How a confirmed time-breaking span becomes a cut range (Phase 2): written by the same confirmation, or proposed to the live pass for the owner's X — and the reverse, whether an X-marked replay also records a `replay` span (it should, with origin `confirmed`), so the two files agree without either copying the other's authority.
2. Whether the 13 edited recordings' spans are entered by hand before Phase 2's detector exists (the scan's segments as `proposed` spans are a ready import).
3. Whether `fullVideoNegatives` for a `continuous` recording also requires a confirmed `normal_speed` span, or whether the confirmed type suffices (the policy takes the type).

## 12. Owner decisions of 2026-11-03 on PR #134, and what was done

| # | Decision | Done in this PR |
|---|---|---|
| 1 | D-031's architecture and the two verbatim documents accepted as the intended direction; not permission to merge or deploy | D-031 marked accepted (direction) with the owner's words |
| 2 | PR held pending Codex's two findings at `3587fce`: serialise queue refreshes and mutations; apply withheld checks to every task type before making tasks actionable; regression tests; rerun validation; new independent review | `WorkQueueFileAccess` actor serialises every queue-file read-modify-write; a person's action no longer invalidates a refresh and `refreshing` clears regardless; the reconciler applies the withheld verdict before any net observation. Tests: `WorkQueueModelTests` (3), `WorkQueueReconcilerTests` extended. Validation rerun (§7); `@codex review` requested |
| 3 | `FootageProperties` authoritative for characterisation, `CutRange` for effective exclusions; coordinate with PR #135; no duplicate masks; keep the cut-range schema; a manual initial-partial-rally exclusion is not "edited" | Recorded in D-031 and §11.4; `FootageProperties` says so in its header; no mask added here; coordination before Phase 2 |
| 4 | L2 default 2 fully human-reviewed rallies per eligible recording, configurable, third allowed by difficulty and diversity | The policy's default (2, in `tasks/work-queue.json`); the third is Phase 2's selector |
| 5 | Before Phase 2, separate reviewed fixes: project-switch-during-sync writes and cancellation; expensive filesystem work in view bodies | Not in this PR; next two PRs after this one is settled |
| 6 | Handheld and heavily panned footage restricted, not discarded; document the edited recordings as limitations of historical experiments without modifying frozen records or labels | Policy unchanged (restricted); §11.5 |
| 7 | Verify 145 vs 146, and whether admitted footage is eligible per model-specific export | §3.3: 146 = 167 − 21; per-model counts (net 132, L2 88 with human labels today, rally classifier 30 declared) |
| 8 | PR #135's migration 051: confirm deployment, old-client compatibility, rollout and rollback; no further backend changes | Read-only check: `label_rally_times_cuts` (version `20261103033340`) **is applied** on the live project as of 2026-11-03T03:33Z. The compatibility test and the rollout/rollback record belong to PR #135; nothing changed here |
| 9 | Preserve "Marked Every Rally" declarations as valid development-label evidence; no redoing of annotations | The boundary task is complete by declaration (§11.4); 30 recordings now show complete, coverage unverified |
| 10 | (2026-11-03, after Codex's second review at `d6a41b7`) Fix both new P2 findings in the same PR, with regression tests; no change to the architectural boundaries, annotations, frozen records or splits; rerun build, tests and configuration checks; request another Codex review; stop at the merge gate | **Queue → Net labels selection lost:** the Queue's open used to select the recording before SwiftUI switched tabs, and the Net labels tab's activation reload cleared it. `NetLabelsModel` now holds a durable navigation request (`open(video, in: root)` → `pending`), applied only once the tab reports itself active (`activate`) and has reloaded the project the request names; a reload of the same project while the tab is off screen keeps it; a project change drops it (said so in the status); it is applied through the ordinary selection, so a withheld, handheld or unidentified recording is named and never opened, a recording not in the project is reported, and an unreadable file shows nothing. Tests: `NetLabelsNavigationTests` (4) — open from the Queue while the tab is inactive, open while active, request surviving a reload before activation, project change and stale request and no project, withheld/unidentified/handheld/missing/unreadable. **Proposals promoted eligibility:** see §11.1 — eligibility is established only by a confirmed recording type; `Verdict.combined` keeps `not_assessed` under a standard or restricted verdict and yields only to quarantine or worse. Tests: `TrainingEligibilityTests.testProposalsNeverEstablishEligibilityOfAnUnknownRecording` (every model and the negatives verdict: proposed harmless traits, proposed restrictions, a confirmed restriction on an unknown type, confirmed and proposed `unknown`, rejected proposals, confirmed types with proposals) and the combination rule's test |
| 11 | (2026-11-03, after Codex's third review at `29905d9`) Fix the new P2 finding on the Queue → Track path the same way | **Queue → Track opened in the wrong mode:** the Queue opened the recording in the tracker only; a Track tab left in "rally times" mode still showed the rally marker, and the tab's appearance restored its own saved recording into that marker. The request now lives on `TrackLabelModel` (`request(video, in: root)` → `requested`); the Track tab takes it when it is on screen (`takeRequest`, on appearance and on the request's arrival), switches to ball tracks (stopping the marker's playback) and remembers the recording as its own, so nothing is restored over it. The resolution is a pure function (`TrackLabelModel.resolve`): opened only for the project the request names and a recording with its video on this Mac; a project change, a stale request (even with a same-named recording in the new project) or an untrackable recording drops it with the reason in the status. Tests: `TrackNavigationTests` (3) cover the resolution; the tab's mode switch is SwiftUI state (`@AppStorage`) and the tracker needs the app's sampler, so that part is read, not test-run (noted in the PR) |
| 12 | (2026-11-03, after Codex's fourth review at `b03c5fe`) Fix the two new findings on the source index: P1 — derivations followed one generation only (A withheld, B from A, C from B: C admitted and, confirmed continuous, standard everywhere); P2 — a footage-properties record used by name after the recording was replaced under the same id | The index follows `derivedFrom` through every generation — a parent named by video id or by identity key (`src:` / `fp:`, every project video carrying it) — expanding each recording once, so a cycle ends the walk; a withheld ancestor at any depth quarantines the derivative, and an ancestor whose record cannot be used (unreadable, or another file's) leaves the ancestry unknown, which quarantines too. A record whose `sourceFingerprint` is not the card's current fingerprint (or whose card has none) is another file's: nothing of it is used (no recording type, spans or derivation carried forward) and the recording is quarantined as for an unreadable record, until it is characterised again; a record with no fingerprint remains bound by name (phase 2's writer records one). Tests: `SourceRegistryTests.testDerivationsAreFollowedThroughEveryGenerationAndARecordOfAnotherFileIsNotUsed` — three generations by id and by fingerprint, a cycle, an unreadable ancestor, a replaced file, a record for the card's own fingerprint, a record with a fingerprint for an unidentified recording |
| 13 | (2026-11-03, after Codex's fifth review at `c5c3555`) P1 — a reserved name validation.json lists that no longer has a card or session was not found as a parent (the walk resolved parents among project names only), so its derivative was admitted | Parents are resolved against the project's names and the withheld closure's names together, so a listed reservation that left the project still quarantines its derivatives at any depth; a parent that is neither is outside the project and the derivative stays admitted. Test extended: a lineage-holdout and a legacy-holdout name with no card or session, two generations, and an outside parent |
| 14 | (2026-11-03, found by the revision-6 validation run) The revision-2 queue test `testManyInterleavedOperationsLoseNothing` failed once under load: a cancel was lost | The actor serialised queue-file operations but did not order them: a cancel then a reopen of one task could land as reopen then cancel, and the next cancel was then refused as a same-state move. Mutations now wait for the mutation before them (`lastMutation` chain), so a person's actions land in the order they were made; a refresh stays outside that order and reconciles over the file as it is when its turn comes. The test now checks the order of every user transition in the history and no longer asserts which side of the reopen the refresh landed on |
| 15 | (2026-11-03, owner's independent inspection after the clean sixth review) A derivative of protected footage could be quarantined by the source index while its labeling tasks stayed actionable: the queue checked only the withheld closure and EventInventory. Before merge: no quarantined, withheld or otherwise inadmissible source may receive an actionable task through the Queue UI; decide from the authoritative records, not a cached index; treat unresolved explicit `derivedFrom` ancestry conservatively; regression tests for a protected original, an edited derivative with a different fingerprint, multigeneration derivatives and unknown parents; D-017 safeguards unchanged; narrow scope | The reconciler's `Inputs` carry each recording's admission (and reason) from the index that `gather` builds at that moment from project.json, the sessions, validation.json, the ledger and the footage-properties records — a written `source-index-*.json` is never read (the on-disk test plants one claiming otherwise). Every kind passes one gate before reading any observation: the withheld closure (blocked), then admission — quarantined → task `quarantined`, unidentified/rejected → `blocked`; `complete`, `in_progress`, `needs_review` or `ready` observations are overruled. `WorkQueue.State.isActionable` (not blocked, quarantined or cancelled) is what the Queue tab's "Open" follows. In the index, an explicit `derivedFrom` whose parent is neither a project recording nor a reserved name is unverified ancestry → quarantined (it was "clear" before), at any depth. Tests: `testInadmissibleRecordingsGetNoActionableTaskOfAnyKind` (pure verdicts, all three kinds) and `testDerivativesOfProtectedFootageAreQuarantinedFromTheAuthoritativeRecords` (a project on disk: holdout original, derivative under its own fingerprint, second generation, unknown parent, re-characterisation frees, unreadable ancestor); registry test updated. Not changed: the L2 package preflight, the exposure ledger, the split manifests, `ReservedVideos` — derivative lineage in every consumer stays phase 3 |
