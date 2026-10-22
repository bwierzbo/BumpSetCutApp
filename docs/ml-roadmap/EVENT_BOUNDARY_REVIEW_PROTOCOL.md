---
name: event-boundary-review-protocol
status: proposed (Task B.2 / Phase 1A calibration pilot; for owner review before any reviewing starts)
created: 2026-10-22T02:30:00Z
updated: 2026-10-22T02:30:00Z
---

# Independent review of serve-contact / dead-ball boundaries: protocol for the 20–30 event calibration pilot

Decision D-004 and roadmap Phase 1A: before any claim about rally-boundary quality, a modest, frame-accurate, independently reviewed set of rally event boundaries, with uncertainty and provenance, kept apart from the dense ball tracks. This page is the protocol. Nothing in it runs until the owner approves it; the running L2 export and the current project annotations are not touched.

## 1. What is being certified, and what is not

- **Certified:** for each selected rally, the **first serve contact** time (hand meets ball, not the toss) and the **ball-dead** time (the ball hits the ground, lands out, is caught, or the referee's whistle ends play — see §4), each with an `[earliest, latest]` uncertainty interval, plus the rally's **kind** (`rally`, `missedServe`, `other`).
- **Not certified:** ball boxes (the dense tracks stay as they are, "human-verified complete-rally" per D-019), rally counts for the whole video (that is the full-video marking, a separate activity), or the pipeline's own serve detector output (a prediction, never a label).
- A rally mark that nobody reviewed under this protocol stays `legacy_unverified`; it is never promoted by inference.

## 2. What the current data can and cannot support (inventory, 2026-10-22)

| Fact | Consequence for the protocol |
|---|---|
| A mark is `{startTime, endTime, kind?, contacts?}` in `<video>.rallylabels.json`, nothing else: no annotator, timestamp, origin or uncertainty (`Labeler/Shared/RallyEvents.swift:70-75`) | reviewed events need **new fields or a separate file**; a corrected mark written in place would erase the legacy one |
| Marks come from four indistinguishable paths: live tagging (key press backed up 0.25 s × rate, snapped to the nearest ball-path change within ±0.4 s), rally-times mode (1 s / 5 s arrow steps, no frame stepping), auto-from-track completion, phone sync (`LiveTagger.swift:67-121`; `RallyMarkModel.swift:283-342`; `LabelTrackTask.swift:200-205`; `LabelingSync.swift:540-548`) | existing starts are **toss-or-contact ± snap**, existing ends are **press-time-or-path-end ± snap**: the pilot measures that offset |
| Frame stepping exists only in the Track tab for ball boxes (`TrackLabelModel.swift:507`) | the review tool must add frame stepping on the rally-times timeline (one frame, 5 frames, 1 s) |
| Phone sync overwrites a sidecar wholesale when the Supabase row is newer (`LabelingSync.swift:411-419`) | reviewed events must live where sync cannot touch them (§5) |
| Playback off the Mac uses scrub proxies; originals are on the desktop, now mounted read-only (`FOOTAGE_SHARE.md`) | review on the **original** through the mount; proxies are not frame-exact |
| `legacy_holdout` is not in `reservedAsListed`, so `--score-rallies` and `--render-pipeline` will run on its 3 marked videos (`ReservedVideos.swift:33-54`) | the pilot selects from **development recordings only** and the tool refuses every withheld name by the L2 closure (`lineageWithheldNames`), not only `reservedNames` |
| 22 development recordings are fully marked (train 12, dev_val 1, tune 9); no lineage-holdout recording has marks | the pool for the pilot |

## 3. Sample: 24 events from development recordings

- **Pool:** the 22 development recordings with `ralliesMarked`, minus nothing; every withheld recording (21: lineage holdout 16 + legacy holdout 5, with aliases) is excluded by name through the L2 closure, and the tool refuses them.
- **Size:** 24 rallies (within the 20–30 of D-004) = 48 events, plus every `missedServe`/`other` mark inside the chosen rallies' neighbourhoods. A calibration pilot, **not** statistically powered: it measures the offset and spread of existing marks and calibrates the uncertainty rubric.
- **Stratification** (8 per surface, drawn with a fixed seed from a frozen list of candidate rallies written to the pilot record before anyone looks at frames): per surface 2 short rallies (< 4 s), 2 long (> 12 s), 2 with the serve from the far end, 1 whose existing start was auto-from-track, 1 flagged ambiguous by the selector (occlusion, cut, replay). Plus 4 events chosen *because* the pipeline's serve detector and the existing mark disagree by > 1 s (hard cases are over-sampled on purpose and reported separately).
- **Freeze first** (D-004, roadmap §131-140): before reviewing, record the hashes of the label files, the split manifest, the model and config, and the pipeline's frozen raw/padded predictions on the pool, so the sensitivity analysis re-scores *identical* predictions against old and corrected marks.

## 4. Event definitions (the rubric)

| Event | Definition | Recorded as |
|---|---|---|
| Serve contact | the first frame where the server's hand/arm has struck the ball (ball begins its flight); **not** the toss, not the ready position | `contact.earliest`, `contact.latest`: the last frame before and the first frame after the strike when the strike frame is not itself unambiguous; equal when it is |
| Ball dead | the first frame where play is over: ball touches the floor/sand, lands or is called out, is caught/held, touches a non-playing object, or the whistle (when audible) | `dead.earliest`, `dead.latest` likewise |
| Missed serve | serve contact occurred but the ball never crossed into play (net, out, foot fault) | `kind: missedServe`, contact recorded, dead = when the ball is dead |
| Other / not a rally | warm-up, replay, no-play, camera cut inside the span, practice drills | `kind: other`, both events recorded if identifiable, else `unresolved` |
| Occluded / departed | the event frame is not visible (ball out of frame, occluded) | the interval widens to the last and first visible frames; `visibility: occluded` |
| Truncated file edge | the recording starts after contact or ends before dead | `edge: start|end`; the missing event is `unresolved`, the rally is excluded from boundary metrics but kept for coverage |
| UI click delay | n/a for the reviewer (frame stepping); recorded only as a property of the *legacy* mark being compared | — |

Uncertainty rule: an interval wider than **6 frames** (0.2 s at 30 fps) marks the event `ambiguous`; the pilot reports the share of ambiguous events per surface and per event type.

## 5. Where reviewed events live (provenance)

A new sidecar next to the legacy one, never written by live tagging or phone sync: `<video>.rallyevents.json`, one record per reviewed rally:

```json
{"rallyId": "<uuid>", "legacyIndex": 3, "legacyStart": 61.25, "legacyEnd": 73.4,
 "kind": "rally",
 "contact": {"earliest": 61.433, "latest": 61.467, "visibility": "clear"},
 "dead":    {"earliest": 73.133, "latest": 73.200, "visibility": "occluded"},
 "flags": ["ambiguous_dead"], "edge": null,
 "sourceMethod": "manual_event", "reviewState": "reviewed",
 "annotator": "<initials or id>", "reviewedAt": "2026-10-2xT..Z",
 "secondReview": {"annotator": "...", "contact": {...}, "dead": {...}} ,
 "annotationVersion": "rally_event_truth_v1",
 "tool": "RallyLab <git sha>", "sourceFingerprint": "file:<sha>", "frameRate": 29.97}
```

- The legacy mark keeps its place in `rallylabels.json` untouched and is tagged in the inventory as `legacy_unverified` (`source_method` inferred from history where possible: `auto_from_tracked_bounds`, `machine_proposed`, `manual_event`, `legacy_unknown`).
- `ball_track_truth_v1` (the existing tracks) and `rally_event_truth_v1` (this file) are two inventories tied to the same split manifest hashes; registry rows are minted for both.
- Scorers (SCORING_CONTRACT.md) take `rally_event_truth_v1` when present and refuse to report boundary metrics on `legacy_unverified` marks unless the report is labelled as such.

## 6. Review procedure

1. Open the rally in the review tool at the legacy start − 3 s on the **original** video (mounted footage), playback paused. The tool shows the legacy mark and the pipeline's frozen prediction only **after** the reviewer has committed both events (blind to both).
2. Step frames to the serve contact; record `earliest`/`latest` per §4. Step to ball dead; record likewise. Choose `kind`. Add flags.
3. Second review: a random 8 of the 24 plus every `ambiguous` event are reviewed blind by a second pass (a second person if available; otherwise the same reviewer after ≥ 24 h, with the first result hidden). Disagreements > 3 frames go to adjudication and are reported.
4. The tool writes `rallyevents.json` atomically, logs the review as `event_review` in the exposure ledger (a use of the recording), and refuses any withheld name.

## 7. Outputs

- `boundary_audit.csv`: one row per event (video, rally, event, legacy time, reviewed earliest/latest, width, flags, annotator, second-review delta).
- `boundary_label_sensitivity.json`: the frozen predictions scored twice (legacy vs reviewed truth) with the contract's raw-boundary scorer: counts, IoU at 0.3 and 0.5, start/end MAE and signed medians, tolerance coverage, complete-rally recall and dead-time retention on the padded export, and every rally whose match status flips.
  **Evaluation scope, identical for both passes.** Only 24 of a recording's rallies are reviewed, so a reviewed sidecar is a *subset* and must not be read as the recording's whole truth. Each selected rally defines an **evaluation window** from information available at selection time only: `[legacyStart − 5 s, legacyEnd + 5 s]` (clamped to the video), frozen together with the candidate list, the legacy labels and the frozen predictions **before** any frame is reviewed; the union of windows per recording is the scope. In both passes, truth, predictions, exported clips and the dead-time denominator are **clipped to the scope**; everything outside it is dropped from every count. Inside a window, the *legacy* pass uses the legacy marks and the *reviewed* pass uses the reviewed events; an unreviewed legacy rally that falls inside a window (an adjacent rally) is kept as legacy in **both** passes and flagged `unreviewed_in_window`, so the two passes differ only by the reviewed corrections. A reviewed event that lands outside its window (a correction of more than 5 s) does not widen the window: the rally is flagged `window_exceeded`, reported on its own, and excluded from both passes' boundary statistics, so no window depends on what the reviewer later finds. Because the windows are fixed before review from legacy information alone, the two passes differ only by the reviewed corrections.
- A short pilot report in `experiments/EXP-<date>-b2-boundary-pilot.md`: offset and spread of legacy starts vs contact (expect negative: toss-primed and snap), legacy ends vs dead (expect positive: press delay), ambiguity rate, and a recommendation on whether the full-video marks need systematic correction or only a documented bias.

## 8. Tooling needed (separate PRs, after the export)

1. **Review tool in RallyLab** (macOS, `RallyLabTests`): frame stepping on the rally timeline, blind mode, the `rallyevents.json` writer, the withheld-name refusal through the L2 closure, the `event_review` ledger row. Shared-pipeline files untouched.
2. **Inventory command** `--event-inventory`: lists marks per recording with inferred `source_method`, flags `legacy_unverified`, writes the two inventory files with manifest hashes.
3. **Sensitivity scorer**: the contract scorer run twice; depends on SCORING_CONTRACT PR A.

## 9. Blockers and open questions for the owner

- Approve the 24-event design, the 0.2 s ambiguity rule, the 0.98 completeness cut (contract), and the second-review rule.
- Whether the reviewer may be the owner alone (then the blind revisit after 24 h stands in for a second person).
- `legacy_holdout` recordings are reachable by the current scoring tools; the pilot excludes them by rule, and the review tool must refuse them by code. Confirm that `--score-rallies` should also start refusing them (a behaviour change for L1 diagnostics).
