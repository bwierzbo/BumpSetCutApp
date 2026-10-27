---
name: stage1-rally-boundaries-plan
status: living plan for the Stage 1 review (D-024); S1-a (PR #97) and S1-b (PR #98) merged on the Mac; §8 is the Mac + iPhone plan of 2026-10-26 (owner direction, verbatim in docs/decisions/2026-10-26-stage1-mac-iphone-direction.md)
created: 2026-10-25T06:09:28Z
updated: 2026-10-26T18:34:12Z
decision: D-024 (accepted), D-021 (C1 first), D-004 (24-rally pilot), D-010 (rally activity ≠ ball visibility)
---

# RallyLab Stage 1 — Rally Boundaries review: implementation plan (read-only)

**Authority.** [D-024](../decisions/DECISION_LOG.md#d-024) (owner direction of 2026-10-23, [summary](../decisions/2026-10-23-progressive-rally-review-owner-direction.md)) makes full-video rally-boundary review the MVP priority; the owner's overnight authorisation of 2026-10-24 permits *preparing a read-only implementation plan* once the L2 export and its verification are done. This page is that plan. It authorises nothing: every PR below needs the owner's go-ahead under D-005/D-014, and the D-024 direction's own condition — tool implementation planning proceeds after L2 training has been separately approved and actually started — is noted, not overridden. The live dataset is not modified; no annotation is collected automatically.

**What exists today** (file:line from the 2026-10-25 survey of `main`): the Track tab's Rally Times mode (`RallyMarkModel`, `RallyMarkView` in `TrackTabView.swift:26-44`) edits `<video>.rallylabels.json` — `[RallyMarkRecord{startTime, endTime, kind?, contacts?}]` (`Labeler/Shared/RallyEvents.swift:70`) with no annotator, timestamp, uncertainty or stable id (`Mark.id` is minted on every load, `RallyMarkModel.swift:27`); `RallyKind` has `rally | missedServe | other` and no non-rally-activity case (`RallyEvents.swift:20-35`); phone sync overwrites that file wholesale when the remote row is newer (`LabelingSync.swift:387-430, 540`), every 30 s; the GUI's periodic sync re-saves sessions from memory (`ProjectsModel.swift:218-221`); the withheld closure is `ReservedVideos.lineageWithheldNames(in:)` (`ReservedVideos.swift:49`); the exposure ledger is `ExposureLog.record(videos:kind:ref:note:in:)` (`DatasetSplitManifest.swift:602`) with the GUI refusal pattern in `BallPathBuilder.admission(of:in:)` (`BallPathBuilder.swift:64-75`); original footage reaches the Mac through per-file symlinks to the read-only mount (`scripts/footage_share/link_footage.py`), playback prefers the original and swaps in a 960 px scrub proxy (`RallyMarkModel.open`, `ScrubProxy`); frame stepping exists only over decoded rally points in the Track tab (`TrackLabelModel.stepBy`, 507), not over video frames. Nothing in the code mentions `rallyevents`, `EventReview` or coverage.

## 1. Scope

| In Stage 1 | Not in Stage 1 |
|---|---|
| Every **review-eligible development recording**: all project sessions minus the L2 withheld closure (lineage holdout, legacy holdout, final test, candidates, aliases). Train and val sides alike — boundary truth is annotation, not model exposure, and the L2 package is frozen regardless | Any withheld recording (refused by name, path and fingerprint; the separate exception process stays separate) |
| Per rally: first serve-contact frame and first ball-dead frame, each as `[earliest, latest]`, visibility, kind (`rally`, `missedServe`, `other`), flags, file-edge marker; **persistent rally id** | Contacts, actions, techniques (Stage 2 — the id is the hook); players (Stage 3) |
| Per recording: **coverage** — which intervals a person has inspected; confirmed `nonRallyActivity` spans (throws, retrieval, bouncing, warm-up) marked quickly without per-throw frames; `transition` and `uncertain` spans; an explicit **recording complete** action that refuses gaps | Treating unreviewed time as dead time, non-rally or negative detector examples (D-010); any write to `rallylabels.json`, ball boxes, tracks, splits, L2 records |
| The approved **24-rally calibration pilot** (D-004, [protocol](EVENT_BOUNDARY_REVIEW_PROTOCOL.md)) as the first use of the same tool: frozen selection, blind mode, repeat review | Scoring, sensitivity analysis (SCORING_CONTRACT PRs), corrections to legacy marks (C4) |

## 2. Data: `<video>.rallyevents.json` (new, versioned, never synced)

One file per recording beside the legacy sidecar, written atomically by the Stage 1 tool only. It extends the protocol's §5 record with coverage. Proposed `annotationVersion: "rally_event_truth_v1"`:

```json
{"annotationVersion": "rally_event_truth_v1", "video": "grs_tri_shade_port_self_02",
 "sourceFingerprint": "file:<sha256>", "frameRate": 59.94, "durationSec": 300.0,
 "tool": "RallyLab <git sha>",
 "coverage": [{"start": 0.0, "end": 187.433, "state": "reviewed", "at": "2026-…Z", "annotator": "BW"}],
 "spans": [{"id": "<uuid>", "kind": "nonRallyActivity", "start": 12.0, "end": 19.5, "note": "ball retrieval"},
           {"id": "<uuid>", "kind": "uncertain", "start": 140.2, "end": 143.0, "note": "camera cut"}],
 "rallies": [{"rallyId": "<uuid>", "legacyIndex": 3, "legacyStart": 61.25, "legacyEnd": 73.4,
              "kind": "rally",
              "contact": {"earliest": 61.433, "latest": 61.467, "visibility": "clear"},
              "dead":    {"earliest": 73.133, "latest": 73.200, "visibility": "occluded"},
              "flags": ["ambiguous_dead"], "edge": null,
              "sourceMethod": "manual_event", "reviewState": "reviewed",
              "annotator": "BW", "reviewedAt": "2026-…Z",
              "secondReview": null}],
 "stage1Complete": null}
```

Rules the store enforces (shared function, not the view):

1. **Persistent ids.** A `rallyId` is minted when a rally record is first saved and never changes; edits keep it; a deleted rally is kept with `reviewState: "withdrawn"` rather than removed. Legacy marks are linked by `legacyIndex` + times at first review only, never re-derived.
2. **Coverage is explicit.** `coverage` holds only `reviewed` intervals the person confirmed ("reviewed through here"); everything else is *unknown*. `spans` of kind `nonRallyActivity | transition | uncertain` live inside reviewed coverage and never widen it. `stage1Complete` is set only by the complete action, which refuses when the union of `coverage` does not cover `[0, durationSec]` within one frame, or any rally has an `unresolved` event without an `edge`.
3. **Non-destructive.** The tool never opens `rallylabels.json` for writing; `LabelingSync` does not know the new file (test: a sync round leaves it byte-identical); the periodic session re-save does not touch it (it is not in `sessions/`). Legacy marks stay `legacy_unverified` in the inventory.
4. **Uncertainty rubric** as the protocol §4: interval wider than 0.2 s of video time ⇒ `ambiguous_<event>` flag; occluded ⇒ `visibility: occluded`; file edge ⇒ `edge: start|end` with the missing event `unresolved`.
5. **Not a detector label.** No exporter, sampler or package reads this file; `nonRallyActivity` never becomes a `no ball` frame (D-010). A test asserts `MultiFramePackage`/`LineagePackage` inputs are unchanged by the file's presence.
6. **Frame rate and times** come from the original file's track (`AVAssetTrack.nominalFrameRate` and presentation timestamps), recorded in the file; the UI shows ms and frame index at that rate.

## 3. Refusal and ledger (shared function)

`EventReview.open(session:, project:) throws -> EventReview.Session`:

- Refuses when the session's name, path or fingerprint is in `ReservedVideos.lineageWithheldNames(in:)` or matches `ReservedVideos.match(_:root:)` — the whole closure, not `reservedNames` (the protocol §2 gap: legacy holdout is reachable by `--score-rallies` today).
- Writes `ExposureLog.record(videos: [name], kind: .eventReview, ref: "EventReview", note: "Stage 1 rally boundaries", in: root)` **before** returning; an unwritable ledger refuses the open (fail closed, as `BallPathBuilder.admission`). `ExposureRecord.Kind` gains `.eventReview` (`DatasetSplitManifest.swift:69-85`; the manifest/audit treat it as a non-training use).
- Requires the **original** video (the mount link resolves and `stat` follows it; `FootageRemote.playbackURL` original branch). The scrub proxy may drive scrubbing but **commits are refused while the proxy is the loaded item** — proxies are not frame-exact.
- The headless and GUI paths both call this function (CLAUDE.md: guards live in the shared function).

## 4. The `Rally Boundaries` workflow (RallyLab-only files)

- **Tab.** `ContentView.Tab` gains `review` (`ContentView.swift:25`); `RallyBoundariesModel` is built in `RallyLabApp.init` like `RallyMarkModel`. Stage 2 (`Contact Review`) will be a second mode in the same tab later, keyed by `rallyId`; not built now.
- **Recording list.** Eligible recordings with a coverage bar (reviewed / unknown / complete), sorted by least coverage; withheld recordings are not listed. "Resume" opens at the first unknown interval.
- **Player.** `AVPlayer` on the original with zero-tolerance seeks (reuse `RallyMarkModel`'s chased-seek pattern, 231-260); frame stepping ±1, ±5 frames, ±1 s, hold-to-scrub; the frame list for stepping comes from the track's sample cursor (as `TrackLabelModel.frameTimes` does, 608) so steps land on real presentation times; audio on. Time shown as `mm:ss.mmm` and frame index.
- **Timeline.** A full-duration bar (new view; `RallyTimesBar` is rally-only) with layers: coverage, spans, rallies (contact→dead), legacy marks (hidden in blind mode), the playhead. Click or key to seek.
- **Keys** (configurable later, defaults): `S` contact-earliest, `Shift-S` contact-latest (one press when unambiguous), `D`/`Shift-D` dead, `K` cycle kind, `O` occluded, `A` flag ambiguous, `E` edge, `N` start/end a non-rally span, `T` transition span, `U` uncertain span, `R` "reviewed through playhead", `Return` commit rally, `Cmd-Return` recording complete (refuses gaps with the first gap shown), `Z` undo (in-memory stack; the file is rewritten whole on each commit).
- **Blind mode** (pilot): legacy mark and frozen prediction hidden until both events are committed; the frozen 24-rally selection loaded from the pilot record; `secondReview` recorded by a separate pass with the first result hidden and the 24-hour rule enforced from `reviewedAt`.
- **Completion semantics** shown in the UI: "fully reviewed" appears only when `stage1Complete` is set; partial coverage is labelled with its percentage and never as whole-video truth.

## 5. Headless, read-only commands

- `--event-inventory`: per recording — legacy marks with inferred `sourceMethod` (`auto_from_tracked_bounds | machine_proposed | manual_event | legacy_unknown` from history where possible), reviewed rallies, coverage fraction, `stage1Complete`; writes `manifests/event-inventory-<stamp>.{json,csv}` with the split-manifest hashes (protocol §8.2). Refuses nothing (it reads sidecars only) but lists withheld recordings as `withheld` with no times.
- `--review-status`: the coverage table alone, for the nightly report.
- Neither writes a sidecar or a ledger row.

## 6. Tests (RallyLabTests)

Schema round trip and version refusal; persistent id across edit/delete; coverage union and the gap refusal (off-by-one-frame cases at 29.97/59.94 fps); span-inside-coverage rule; ambiguity flag at 0.2 s; refusal of every withheld name/path/fingerprint through the closure (fixtures from `ReservationAndExposureTests`); ledger row written on open and open refused when the ledger is unwritable; `rallylabels.json` byte-identical after a review session and after a `LabelingSync` round; a `rallyevents.json` beside a session leaves `MultiFramePackage` and `LineagePackage` inputs unchanged; proxy-loaded commit refused; `--event-inventory` output on a fixture project.

## 7. PRs, in order (each RallyLab-only, Codex-reviewed, owner-merged)

| PR | Scope | After |
|---|---|---|
| S1-a | `RallyEventsFile` (schema, store, rules 1–6), `EventReview.open` (refusal + `.eventReview` ledger kind), `--event-inventory`, `--review-status`, tests; no UI | owner go-ahead; L2 export complete and verified |
| S1-b | `Rally Boundaries` tab: player, frame stepping, timeline, keys, coverage, commit/complete; tests of the model (no UI automation) | S1-a |
| S1-c | Pilot mode: frozen 24-rally selection, blind mode, second review, `boundary_audit.csv` writer (protocol §7) | S1-b; the pilot record frozen first (D-004) |
| S1-d | `RallyKind` in the shared `RallyEvents.swift` is **not** changed; if a shared enum ever needs the activity kinds, that is a dual-target change with both builds (CLAUDE.md) | only if needed |

G1b (protected-holdout refusal for routine scoring, `--score-heat`, `desktop.sh fetch`) stays as planned in [DATASET_REVIEW_GUI_PLAN.md](DATASET_REVIEW_GUI_PLAN.md) and is independent of this work.

## 8. Mac + iPhone: one annotation system (owner direction of 2026-10-26, [verbatim](../decisions/2026-10-26-stage1-mac-iphone-direction.md))

**What the survey found (2026-10-26).** The Labeler iPhone app (target `Labeler`, iOS 18, bundle `app.BumpSetCut.RallyLab`) plays a **re-encoded copy** of each recording, not the original: the Mac's `LabelingSync.publishVideos` runs ffmpeg (`-fps_mode passthrough -enc_time_base demux`, H.264, long side ≤ 1280, no audio; `copyVersion` 3 "frame times kept exactly") and uploads `rallylab/<project>/<session>-v3.mp4` to the private `labeling` bucket; the phone streams it through a signed URL or plays the downloaded file. The encoder is meant to keep every presentation timestamp, but nothing verifies it, and the phone's "frame" buttons move a fixed 1/30 s with zero-tolerance seeks, not from frame to frame. The phone knows nothing of withheld recordings: the Mac uploads every session and the server's only rule is `is_labeler()`. Rally times sync newer-wins on `updated_at` set by the client, and a pull overwrites `rallylabels.json` whole. `Labeler/Shared/` is compiled by both apps (RallyLab lists each file in its membership exceptions); `AVSampleCursor` is available on iOS 16+ for local files.

**Frame identity (the rule).** A Stage 1 event is a frame of the original recording. On the Mac the review runs on the original. On the phone, a copy may stand for the original only when its frames prove it: the Mac records the original's **frame-times digest** (`FrameIdentity.digest`: SHA-256 over every frame's presentation time in microseconds — on the presentation timeline, i.e. media times mapped through the track's edit list; corrected 2026-10-26, [evidence](IPHONE_COPY_FRAME_IDENTITY_2026-10-26.md)) in the record (`frameTimesDigest`) and publishes it with the copy; the phone enumerates the downloaded copy's frames with the sample cursor and compares. Match → commits enabled, events recorded against the original's `sourceFingerprint`; no match or no digest → playback allowed, commits refused with the reason. Nothing rounds a time, substitutes a frame or trusts an unverified copy. A streamed item (no cursor) is playback only.

**PRs and dependencies.**

| PR | Scope | Depends on |
|---|---|---|
| **1 — shared logic** (`feat/stage1-shared-record`) | `EventReview` record, rules and mutations, `BoundaryEditor`, `FrameClock`, `SeekClock` and `FrameIdentity` moved to `Labeler/Shared/` (one schema, one set of rules, compiled by both apps); the record gains `frameTimesDigest` and `revision` (decoded with defaults from older files); the Mac records the original's digest on open; Mac-only open/refusal/ledger stay in `RallyLab/EventReview.swift` | S1-b (merged) |
| **2 — sync and storage** | Supabase: `label_rally_events(video_id, project, session_name, record jsonb, annotation_version, revision, updated_by, updated_at)` with a server-side trigger that bumps `revision` and sets `updated_at`, an RPC `rally_events_save(video_id, expected_revision, record)` that refuses a stale `expected_revision` (optimistic concurrency, the conflict returned to the client, never last-write-wins), RLS `is_labeler()` plus a server-side **withheld list** (`label_withheld(project, session_name)` written by the Mac from `lineageWithheldNames`; the RPC and a policy refuse events for a withheld recording), Realtime broadcast as today; Mac `LabelingSync` publishes the frame digest with the copy, pushes and pulls `rallyevents.json` with the revision, surfaces conflicts (both versions kept, the user chooses) and never touches `rallylabels.json`; phone client methods; offline outbox entries for events. Migration numbered after `047`. | 1 |
| **3 — iPhone UI and frame-accurate playback** | `Labeler/Views/RallyBoundariesView` (touch): recording list with coverage, player on the downloaded copy, frame step buttons driven by `FrameClock` from the copy's real frame times, a scrubber, hold-to-step, large buttons for S / ⇧S / D / ⇧D / occluded / kind / edge / spans / reviewed-through / commit / complete / withdraw / undo, previous/next rally, the same `BoundaryEditor`; the frame-identity gate before any commit; resume at the first unknown stretch | 1, 2 |
| **4 — pilot** (`feat/stage1-pilot`) | `RallyLab --project <p> --pilot-freeze [--seed N] [--dry-run] [--new-draw]` (`PilotDraw`): the pool (every fully marked development recording the review would open, the withheld closure refused), one pipeline pass per recording (exposure `rally_scoring` recorded first), every legacy mark a candidate with its strata (short < 4 s, long > 12 s, far-end serve = the pipeline's serve approaching the camera, auto-from-track = the mark on a finished track's bounds, selector-flagged ambiguity = the ball seen in under a third of the first second or the mark at the file's edge, hard case = serve contact vs mark > 1 s), the seeded draw of 8 per surface in the strata's order spread over independent recording groups (alias group ∪ clip card ∪ uploader), the windows `[legacyStart − 5 s, legacyEnd + 5 s]` clamped, the repeat set of 8, the label-file SHA-256s, the manifest hashes and the frozen raw/padded predictions and serves, written to `manifests/pilot/<stamp>-pilot.{json,md}` and never overwritten (a new draw names the record it supersedes); `--dry-run` runs no pipeline and writes nothing. Blind mode on both platforms: inside a pilot window the legacy marks stay hidden until its rally is committed (Mac; the phone has no pilot record and keeps its legacy toggle off by default); the **second review** is a shared editor mode (`BoundaryEditor.Mode.secondReview`): the selected rally's first result is hidden on the timeline and in the list, S and D mark it again, ⏎ records `secondReview` with the method — another person at once, the same person only ≥ 24 h after the first review — and the recording tool, never changing the first result. `--boundary-audit` writes `manifests/pilot/<stamp>-boundary_audit.csv` (one row per event: legacy time, reviewed interval, width, flags, annotator, tool, second review, delta, adjudication > 0.1 s, window exceeded) with the per-surface offsets, ambiguity shares and repeat agreement by platform pair — the Mac-vs-iPhone comparison on identical source frames. The sensitivity scorer (`boundary_label_sensitivity.json`) waits for SCORING_CONTRACT PR A. The draw itself is run only on the owner's go. | 1, 3 |

**TestFlight (fastest safe route).** PRs 1–3 merged → `scripts/rallylab_ios_release.sh` (archive scheme `Labeler`, upload to App Store Connect app 6820196175, internal group only, no App Review) — owner-only, no external testers. Pre-upload checks: both targets built and tested, record round trip and schema compatibility, withheld refusal on client and server, offline edits and a concurrent-edit conflict, frame identity against known recordings, clean Codex reviews, no protected footage in the bucket.

## 9. Decisions requested from the owner

1. Eligibility: confirm that **val-side development recordings** are reviewable in Stage 1 (boundary truth is not model exposure); the alternative is train only.
2. Confirm the span kinds `nonRallyActivity | transition | uncertain` and that `nonRallyActivity` needs only a start and an end, no per-throw frames.
3. Confirm `withdrawn` (kept, not deleted) for a rally the reviewer removes, so ids never disappear.
4. Confirm the default key map and that the complete action refuses any unknown gap wider than one frame.
5. Whether the first PR (S1-a, no UI) may start before L2 training starts, or only after, per the D-024 direction's condition.
