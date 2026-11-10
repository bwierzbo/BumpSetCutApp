---
name: player-court-calibration-p2
status: proposed (owner review); assisted court calibration built and piloted 2026-11-10; research only, no training, no production change; no court confirmed by a person yet
created: 2026-11-10T20:04:02Z
updated: 2026-11-10T20:04:02Z
decision: D-034 (proposed), P2 paragraph; owner authorisation "P2 Assisted Court Calibration" (PR #166 continuation), 2026-11-10
experiment: EXP-20261110-player-court-calibration-p2
---

# Assisted court calibration (P2)

**Question.** P1 left court membership as the bottleneck. The net-only lane let in 3–5 spectators and next-court players per frame. Can RallyLab propose the court automatically, let a person correct it in seconds, and then sort detected players into near court, far court, serving areas and outside — without any of that becoming evidence until a person confirms it?

**Answer.**
- **The workflow is built.** Player Lab now has a *Court calibration* mode. RallyLab proposes a court. The person answers three questions about the court (surface, format, what marks it), drags points or lines until they sit on the court, and presses Confirm. Players are sorted into zones live as the court moves.
- **Only a person's Confirm makes a court evidence.** A proposal never does, and a scripted test's confirmation never does either. Every proposal is kept as made, and the confirmation records which points the person moved.
- **The automatic proposals are a starting point, not an answer.**
  - On these six recordings, the line search put sensible lines on 3 of 6 courts and was clearly wrong on 2.
  - The net-guided estimate always lands in the right area, but misjudges depth on every camera.
  - The proposals' accuracy against a confirmed court can't be measured yet: no court has been confirmed by a person. The pilot command measures it as soon as one is.
- **Membership against a court, even an unconfirmed one, is far tighter than the net lane.**
  - Over the 36 audited frames, the lane counts at least 4.3 people per frame as "in" beyond those the auditor counted on court.
  - The net-guided court counts 0.7, and the line court 0.4. The line court pays for that by losing about 3 real players per frame to `unknown` or outside where it found no far half.
  - Smoothing cuts zone changes per track from 0.3–0.5 to 0.02–0.12 per 10 observations.
- **Owner's direction during the work:** "If there are methods that work better depending on what type of volleyball you're at I don't mind asking the user." Hence the three questions. The marking answer decides whether the line search runs at all, and the surface and format decide the court size the proposal assumes.

Nothing here changes the ball detector, the rally decision pipeline, the rally-classifier exporter or `rcf_v1`.

## 1. Court geometry: `court_geometry_v1`

Six ground points in the upright, Vision-normalised frame (origin bottom-left, the space of every box and joint):

| Point | Court coordinates (u across, v along) |
|---|---|
| near left, near right | (0, 0), (1, 0): the near end line, nearest the camera |
| net left, net right | (0, ½), (1, ½): where the net's ground line meets the sidelines |
| far left, far right | (0, 1), (1, 1): the far end line |

- **Perspective.** Each half of the court is its own perspective map (a homography from the court half to the image). The court is never assumed rectangular on screen. A net line that sits off the court's perspective midpoint stays where it was placed.
- **Points that can't be seen.** Each point is `seen`, `estimated` (off the frame, hidden or assumed) or `unknown`. A half with an unknown point has no map, and anyone standing on it is `unknown`, never guessed. Points may lie outside the frame, down to −1.5 and up to 2.5 of its size: an end line below the picture is common.
- **Courts the tool refuses.** A half that folds or crosses itself, and halves that overlap across the net line, are refused (`problems`).
- **Court size.** It is metadata, and comes from the person's answers:
  - 16 × 8 m for beach, and for grass doubles;
  - 18 × 9 m for indoor, and for grass 4v4 and 6v6.

  It changes only the proposal's assumptions and the depth of the serving areas, never where a confirmed court is.
- **Serving areas.** 4 m deep behind each end line, and 10 % of the court's width wider than it on each side. It is a band, not a painted line.

**Calibration files** live at `<experiment>/court-calibrations/<recording>.json`, one per recording, and never in a RallyLab project.
- **What a file is bound to:**
  - the recording's identity (project.json's fingerprint);
  - the decoded copy's fingerprint;
  - the upright frame size and orientation.

  A file whose binding no longer matches is `stale`: the GUI shows it and nothing uses it. "Start over" renames it aside; nothing is deleted.
- **What a file holds:**
  - the person's answers (`setup`);
  - segments, each covering one stable camera view.
- **What each segment keeps:**
  - every proposal as it was made: method, score, the evidence behind each point, assumptions, frame times, run time, code SHA;
  - the person's draft, and which proposal it started from;
  - and only after Confirm, the confirmation: the geometry, the starting point, the roles moved, time, person, method, the net label checked against, court size and format;
  - earlier confirmations, in `history`.
- **Segment status:** `unreviewed`, `confirmed`, `rejected`, or `unknown_view` (a cut, pan, zoom or replay). Players in an unknown-view segment are `unknown`.
- **Splitting.** "Camera changed here" splits a segment at the current frame. The new segment starts unconfirmed, with the earlier court as its draft.
- **The net label.** The net input is the person's net label from `net-labels.json`, carried into the run manifest. It is never written or overwritten here. The net-line points in this format are where the net's *ground* line meets the sidelines: a court quantity, not the net label.

## 2. Automatic proposals

| Method | Evidence | Points it gives |
|---|---|---|
| `net_guided_v1` | The person's net label. It assumes the following: a 2.35 m tape and 1 m mesh, so the ground lies 1.35 mesh-heights below the mesh; a mesh 0.5 m wider than the court, so the sidelines sit 3 % inside the posts; a 68° field of view across the long side; a camera height of 1.5 m at ground level or 3 m elevated, from the card; no roll and no yaw. | All `estimated`; near points `unknown` when the assumed camera would stand inside the court |
| `court_lines_v1` | The median of 9 frames spread over the segment, so the players vanish. A ridge response picks out painted lines, tape and rope but not the edges between surfaces. A sideline must cross the net's ground line near one end and slant outward at least 8°; it is scored on the near half only, because the post stands where the sideline runs above the net line. End lines are the outermost lines between the sidelines that stand out. An indoor centre line under the net, when one stands out, gives the net's ground line. | `seen` where two found lines meet inside the frame, `estimated` outside it, `unknown` with no line |
| `combined_v1` | The court-line proposal, with any missing end line taken from the net-guided estimate and cut by the found sidelines | Made only when both sidelines were found and an end line was missing |

Scores are only a count of the lines found (0.1 per line); the report shows that is not accuracy, and every line proposal says "unvalidated". With markings answered "Nothing marks it", the line search does not run.

## 3. The calibration mode in Player Lab

`RallyLab --player-lab <experiment>` → **Court calibration**:
- **The picture.** The frame is shown with a quarter of its size of margin on every side, so off-frame corners can be placed.
  - Lines are dashed orange as proposed, cyan once moved, and green when confirmed.
  - The near half is tinted blue and the far half orange, with the serving areas dashed.
  - Points are filled dots when seen and hollow when estimated.
  - The net label is outlined in white, as reference only.
  - Each player's ground point is drawn in the colour of their zone, with a label such as `near`, `far-srv` or `out`, and `~` when in doubt.
- **Editing.** Drag a dot to move a point, or drag the middle of a line to move the whole line. Drag elsewhere to pan, and use the slider or a pinch to zoom (0.5–12×). The players, IDs, skeletons and court layers can each be shown or hidden.
- **Panel controls:**
  - *About this court*: surface, format, and "Court marked by" (lines/tape, rope or cord, nothing). The automatic proposal waits for the markings answer.
  - Segments, *Propose automatically*, *Reset to* each proposal, *Place by hand* (a starting shape under the net), *Edit confirmed* and *Discard draft*.
  - Per point: seen / estimated / unknown, and *Place* for an unknown point.
  - *Confirm court* (⌘↩, disabled while the court has problems), *Reject proposals*, *Camera changed here* and *Not one court view*.
  - The current frame's zone counts, the proposal's assumptions, and status messages.

A scripted Player Lab run (`--script`, new steps `mode`, `surface`, `format`, `markings`, `propose`, `start`, `move`, `split`, `scriptConfirm`) exercised the mode end to end on a throwaway copy of the experiment. It answered the questions, proposed, started from the net-guided proposal, moved two corners, confirmed and switched back to Players. Its confirmation is recorded as `player_lab_script` by "scripted GUI test (not a person)" and is never used. The editor is rendered beside each snapshot (`<name>-editor.png`): a window capture needs a screen-recording permission this tool doesn't have.

## 4. Player zones: `court_polygon_v1`

- **The ground point.** It is the mean of the reliable ankles (score ≥ 0.3, inside the box), placed 3 % of the box height below the lower one. Otherwise it is the box's bottom centre.
- **Zones:** `near_court`, `far_court`, `near_serving_area`, `far_serving_area`, `outside_court` and `unknown`. A person is `unknown` when no confirmed court covers the frame, when the point is beyond the horizon, or when it is on a half with no map.
- **Doubt.** A zone is uncertain within 0.03 court units of its edge (`boundary`), when the box is cut by the bottom of the frame (`truncated`), or when the foot is more than 0.25 of the body's height above its track's usual ground line (`airborne`).
- **Smoothing.** An uncertain observation keeps the track's previous zone (`held`). A change of zone needs two certain observations in a row, and a tracker reset forgets everything.
- **Nobody is dropped for being one too many.** The number of players is not used. Players who leave the court, such as servers and chasers, keep their track and are shown where they are.
- **What a run writes.** A new `--player-lab-run` reads a person-confirmed court where one covers a frame. It writes the person's `zone` and sets `court` to `in` for the court and serving areas, `out` outside, and `unknown` otherwise. The manifest says which method applied (`courtMethod`, `courtPolygon`). The net lane stays the fallback outside confirmed segments, and lines written before P2 decode unchanged.

## 5. Pilot

- **Command:** `RallyLab --player-lab-court ~/Movies/RallyLab/Experiments/player-pose-p0 --run p1-rfdetr-keypoint-3x2 --report p2-court-pilot-r2 --propose --audit runs-comparison/p1/audit-p1-rfdetr-keypoint-tiles.csv`.
  - Run at code `55984ec` (the build says `-dirty` because this report was uncommitted; no code differed) on 2026-11-10T20:08:51Z. Summary SHA-256 `f29d63fd4fa7d0e1…`.
  - An identical first run (`p2-court-pilot`, code `2737e69`) read the same frames before proposals logged their reads. Its six recordings are the ones already on the experiment's ledger from P0 and P1. r2 wrote the six `--player-lab-court p2-court-pilot-r2 court proposals` rows.
- **Recordings:** the six P0/P1 recordings and their 1,350 frames: beach and grass, each at ground level and elevated; indoor landscape and indoor portrait.
- **What it reads:** the run's frame lines and the experiment's footage copies. No project, and no detector run.
- **What it writes:** `court-calibrations/` (proposals only), the experiment ledger (one `detector_evaluation` row per recording, written before its frames are read) and `court-evals/p2-court-pilot-r2/`. That folder holds the summary, `zones/zones.csv` (every person, every frame, every source), a four-panel comparison per recording, the zones on each audited frame, and the line evidence on each median picture.
- **What isn't in the pilot.** Development runs during tuning (`court-evals/p2-court-dev*`, `p2-court-r1`) and the first pilot wrote proposals that were moved aside to `court-calibrations.dev-20261110/` and `court-calibrations.pilot-r1-20261110/` (renamed, not deleted) before r2, so its files hold only its own proposals. The development runs read the same six copies before reads were logged. No court is confirmed: the person-confirmed panel of every comparison reads "NOT REVIEWED".

### 5.1 Proposal quality before correction (reviewer's look at the panels; no confirmed court to measure against)

| Recording | Net-guided | Court lines | Combined |
|---|---|---|---|
| bch_ele (beach, elevated; rope) | Right area; far end too deep | Near rope and right rope right; left side off | Made (near points from net-guided): plausible |
| bch_gnd (beach, ground; tape) | Right area; too shallow | Near tape right; sidelines plausible; far end at the net line | — |
| grs_ele (grass, elevated; rope) | Right area | Wrong: only a far fragment | — |
| grs_gnd (grass, ground; blue tape, distant) | Right area; near end too high | Left sideline and near tape right; right sideline wrong | — |
| ind_land (indoor, landscape; crowded) | Ground under the net too low; near half missing (assumed camera inside the court) | Wrong: a floor line and a near-vertical side | — |
| ind_port (indoor, portrait) | Close | Near line and net line right; sidelines off the frame | — |

### 5.2 Membership against the proposals (unconfirmed; confirmed tracks; the audit's on-court counts are the reviewer's, not owner-verified)

| Recording | Net lane: "in" per frame / beyond audit / short of audit | Net-guided: "in" / beyond / short | Court lines: "in" / unknown / beyond / short |
|---|---|---|---|
| bch_ele | 12.1 / 1.3 / 0.0 | 10.9 / 0.3 / 0.0 | 7.3 / 2.9 / 0.0 / 4.0 |
| bch_gnd | 8.0 / 7.2 / 0.0 | 2.9 / 0.8 / 0.3 | 4.1 / 4.2 / 2.0 / 0.0 |
| grs_ele | 7.9 / 4.2 / 0.0 | 5.0 / 1.0 / 0.0 | 0.5 / 5.6 / 0.0 / 5.2 |
| grs_gnd | 2.9 / 0.3 / 0.8 | 2.7 / 0.3 / 1.0 | 2.7 / 0.0 / 0.3 / 1.0 |
| ind_land | 19.1 / 12.7 / 0.0 | 9.8 / 1.7 / 0.8 | 1.8 / 22.0 / 0.0 / 8.0 |
| ind_port | 6.0 / 0.0 / 0.3 | 6.0 / 0.0 / 0.3 | 5.9 / 0.0 / 0.0 / 0.7 |
| **Mean, audited frames** | beyond **4.3**, short 0.2 | beyond **0.7**, short 0.4 | beyond **0.4**, short 3.1 |

- **How "beyond" and "short" are counted.** Both are measured on the audited frames. "Beyond" is the number of persons counted "in" (any track state) above the auditor's visible on-court count: a floor on false "in". "Short" is the opposite gap.
- **Servers.** The net-guided court puts 0.2–0.4 people per frame in a serving area on four recordings. Without a confirmed court, whether those are servers can't be scored.
- **Flicker.** Zone changes per track per 10 consecutive observations fell, raw to smoothed, from 0.26–0.53 to 0.04–0.12 against the net-guided court, and from 0.11–0.49 to 0.02–0.12 against the line court.
- **Duplicates and scene features.** Split boxes from tiling (§9 of the P1 report) and spectators are untouched by court zones: a split player's two pieces both count "in". Scene features (in-court speed, coherence) follow whichever court is confirmed. Re-running the features over confirmed courts is the next measurement.

### 5.3 What needs the owner

| Measure (assignment §7) | Status |
|---|---|
| 1. Automatic proposal quality | §5.1, by eye |
| 2. Human adjustment needed | **Pending owner review.** The pilot command reports each proposal's point error (pixels) and the points moved, once a court is confirmed |
| 3. Boundary accuracy after confirmation | Pending: a confirmed court is the reference |
| 4. Near/far membership | §5.2, against unconfirmed proposals |
| 5. False in-court from spectators and next courts | §5.2 "beyond" |
| 6. Servers classified outside | Pending: needs a confirmed court and a server count |
| 7. Stability across frames | §5.2 flicker |
| 8. Duplicate tracks and scene features | §5.2: unaffected by zones; re-measure after confirmation |
| 9. Court-detection time | Net-guided under 1 ms. Court lines 4.0–6.0 s per segment in the Debug build (3.6–7.9 s in the first run): decoding and taking the median of 9 frames, then the search. Once per camera view, not per frame |

### 5.4 Failure cases and unsupported views

- **Faint or patterned surfaces.** On grass with faint tape and on sand with footprints, the ridge evidence is mostly texture. The line search finds a sideline only where the tape is continuous.
- **Glossy indoor floors.** Reflections and several overlapping courts' lines give strong false lines (ind_land).
- **Rope courts seen from above** (grs_ele): the rope's shadow and its line compete.
- **The net-guided depth.** It depends on the assumed camera height and field of view, and was off on every recording. A zoomed or wide (0.5×) lens breaks it, and edited YouTube footage carries no field of view at all.
- **Unsupported:**
  - side views (the camera along the net; already excluded from net labels);
  - handheld footage;
  - footage with no person net label (no net-guided proposal; place the court by hand);
  - a view that changes within a segment: it needs "Camera changed here" or "Not one court view".

## 6. Data kept for a future court model (no training authorised)

Every confirmed calibration keeps the following:
- the automatic proposals, as made, with method and score;
- the corrected points and their status;
- the roles the person moved;
- when the court was confirmed and by whom;
- the recording's identity and the decoded file's;
- the frame size and orientation;
- the camera card, the person's answers, and the segment's time span.

These are candidate human-verified labels. Proposals are never labels.

## 7. Safety

- **Writes.** Everything is written in the experiment folder.
- **Scratch.** `net-labels.json`, `manifests/exposure-log.json` and `project.json` hash the same before and after: `d460d46e…`, `2574ead7…` and `1364ee92…`.
- **The experiment ledger.** Court proposals read footage only through `CourtProposer.propose`, which writes the experiment's ledger row before the first frame. The development runs and the first pilot read the same six recordings' copies before that row existed; those recordings were already on that ledger from P0 and P1. An answer of "Nothing marks it" reads no frames.
- **Not done:** withheld footage, SMB reads, training, iOS integration, and changes to the rally-classifier exporter, `rcf_v1` or the ball pipeline.

## 8. Recommendation and owner gate

1. **Confirm the six courts in Player Lab.**
   - About a minute each: answer the three questions, *Propose automatically*, drag, Confirm.
   - Then re-run `--player-lab-court <experiment> --run p1-rfdetr-keypoint-3x2 --report p2-court-confirmed --audit <audit csv>`, without `--propose`. It measures each proposal against your courts and gives membership against a real reference.
2. **Then decide whether the classical line search earns its place**, or whether the net-guided starting point plus dragging is enough. A learned court detector would need the confirmed calibrations as labels, and training is not authorised.
3. **Keep the split-box fix (P1 §9) separate:** court zones don't remove duplicates.
