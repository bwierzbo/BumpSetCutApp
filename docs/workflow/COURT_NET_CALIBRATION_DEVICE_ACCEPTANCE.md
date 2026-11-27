---
name: court-net-calibration-device-acceptance
status: prepared; sections A–F scripted on the simulator, device run not done
created: 2026-11-25T01:23:16Z
updated: 2026-11-27T20:39:37Z
---

# Court & Net Calibration — device acceptance (Release 1, manual)

The checks a person makes on a **physical iPhone** before the manual Court & Net release goes to internal TestFlight (D-042; authorisation §10 and §12). Prepared with the editor's PR; **not run**. Unit tests cover the geometry, the file's rules and the editor's state; they cannot cover touch, zoom, the loupe or how the screen reads in the hand — this list does.

No model and no proposal is involved anywhere in these steps.

**Since D-043 (2026-11-27)** the court and the net are marked on their own pages of the setup before a run — Trim, Camera position, Court, Net — and nowhere else; the steps below are written for that. "Start again" means: Start AI Processing, Skip the Trim page, Continue on Camera position, which lands on the Court page.

**Scripts.** A1–A3, B1–B11, C1–C4, D1–D4, E1–E4, F2 and F3 run as UI tests on the simulator on a real recording, each attaching a screenshot named by its step for the owner to confirm (`BumpSetCutUITests/Tests/CourtNetAcceptanceTests.swift`). Left to the phone: the loupe in B2, F1, F4–F6, G and H.

## Installing from Xcode (no TestFlight)

The release is on `main` (#206–#208, merged 2026-11-25); the setup pages of D-043 are on `feat/processing-setup-steps` until that is merged.

1. **First, with the builds already on the phone**, do section H's "before" column. Installing from Xcode replaces the TestFlight build of the same app, so the comparison has to be taken first.
2. Open the project of a checkout of the branch in Xcode. It needs `BumpSetCut/Core/Networking/Secrets.swift` (gitignored; copy it from the usual checkout if the checkout is new).
3. Plug in the phone, pick it as the run destination, and run the **BumpSetCut** scheme. Then run the **Labeler** scheme (RallyLab on the iPhone). Both install over the existing apps and keep their data.
4. Xcode's console, with the phone attached, is where the log lines in section G appear.

Nothing is uploaded or distributed by these steps. Both schemes archive for a device in Release with no Ultralytics-derived model and no research detector code (`scripts/check_shipping_build.sh <archive>`).

## Before starting

- A build of the branch on the phone, with at least one landscape and one portrait volleyball video in the library, each a minute or longer; one of them with a near end line that is out of the picture, if there is one.
- Note the phone model and iOS version in the results table.

## A. Opening

| # | Do | Expect |
|---|---|---|
| A1 | Library → open a video that has not been processed | The screen offers Start AI Processing. There is no Court & Net row: the setup pages ask. |
| A2 | Start AI Processing; Skip the Trim page; Continue on Camera position | The **Court** page ("Step 3 of 4") opens on a frame of the video. Status "Not calibrated". The hint asks for the court's near-left corner. Only the court's points are offered. |
| A3 | On each of the four pages, read the heading and the buttons | Each names itself and its place ("Step n of 4"), has a Skip, and can be cancelled (Cancel, or ✕ on Trim), which starts nothing. After the Net page the run starts. |

## B. Court, by hand

| # | Do | Expect |
|---|---|---|
| B1 | Tap each of the six points as the hint asks | Each appears as a ring with its label; lines join them; a dashed centre line appears once a half has its four points. |
| B2 | Drag a point | It follows the finger. A round loupe above the finger shows the corner magnified with cross-hairs; the finger never hides the point. Near the top of the picture the loupe moves below the finger. |
| B3 | Drag a line (the near end line) | Both its ends move together; the other points stay. |
| B4 | Turn on **Move all**, drag inside the court | The whole court moves. Turn it off again. |
| B5 | Pinch on a corner | The picture zooms about the fingers, up to a limit; nothing that was placed moves. Drag the picture off the shape: it pans. |
| B6 | Zoom out (− button), tap below the picture for a near corner that is out of frame | The point sits outside the frame, drawn with a dashed ring (estimated). |
| B7 | Select a point in the picture, switch **Hidden — my best guess** on | Its ring becomes dashed. |
| B8 | Select a far corner, **Can't place it** | The point goes; its chip greys; the hint does not ask for it again. Tap its chip, then the picture: it is placed. |
| B9 | **Skip** the Court page; on the Net page, Cancel; start again | Skip kept what was placed: everything is where it was, and the status reads "Draft". |
| B10 | **Confirm court** | The **Net** page opens; its status reads "Court confirmed". |
| B11 | On another video's Court page, put three points on top of each other and confirm | Refused with the reason; the page stays; the points are kept as a draft. |

## C. Net, by hand

| # | Do | Expect |
|---|---|---|
| C1 | On the **Net** page, tap its four corners | A four-sided shape that follows the net's tilt — not a level rectangle. The court dims but stays visible. |
| C2 | Hide the court (orange eye), then the net (green eye) | Each overlay hides and shows on its own. |
| C3 | With only three corners placed, Cancel → **Save draft and close** | "Saved. The net needs all four corners…"; the three stay on screen and the page stays. |
| C4 | **Confirm net** | The run starts. Cancel it and start again: the Court page reads "Court and net confirmed" and its button reads **Continue**. |

## D. Later edits

| # | Do | Expect |
|---|---|---|
| D1 | Start again; on the Court page move a point | "Not saved" beside the status, which stays confirmed; the button reads Confirm court. Cancel → **Close without saving**, start again: the confirmed court is unchanged and the button reads Continue. |
| D2 | Move a point and **Confirm court** | The Net page opens; the court is confirmed again with the new position. |
| D3 | ⋯ → **Start the court over** | The points go. Cancel and start again: the earlier confirmed court is shown (it stays until another is confirmed). |
| D4 | ⋯ → Surface and Players a side | Kept after cancelling and starting again; each submenu ticks what was chosen. |

## E. Frames and camera views

| # | Do | Expect |
|---|---|---|
| E1 | Step one frame forward and back; ±5 s; drag the slider | The picture follows; the time reads to hundredths; the marks stay put. |
| E2 | On the Court page go to the middle of the video, ⋯ → **Camera changed here → Start from these marks** | "Camera view 2 of 2". The marks are there but not confirmed; the status reads "Needs review" until view 2 is confirmed. |
| E3 | Scrub back before the split | "Camera view 1 of 2" with its confirmed marks. |
| E4 | In view 2, ⋯ → **Not a stable court view** | A banner says so; taps place nothing. **It is a stable view** undoes it. |

## F. Orientation, size and endurance

| # | Do | Expect |
|---|---|---|
| F1 | Repeat B1–B10 on a portrait video | The frame is upright; points land where tapped. |
| F2 | Turn the phone to landscape on the Court page | The picture is on the left, the controls scroll on the right; marks are where they were. |
| F3 | Largest Dynamic Type size | Every control is reachable; nothing is cut off beyond use. |
| F4 | VoiceOver on | Close, Save draft, Confirm, the eyes, zoom, the frame buttons and the point chips are announced with their state. (Placing points by touch on the picture is not a VoiceOver flow in this release.) |
| F5 | A 30-minute video, scrub end to end, zoom to the limit | No stall beyond a moment per frame, no crash, no heat warning. |
| F6 | Delete a calibrated video from the library | Nothing of it is left (its calibration goes with it). Processing a calibrated video again keeps its calibration. |

## G. Processing without YOLO (the removal PR)

Run on the build that has the YOLO removal. For each of one beach, one grass and one indoor recording that is not withheld, filmed from behind an end line — three recordings, each through G1–G3, with the numbers written in the record at the end.

| # | Do | Expect |
|---|---|---|
| G1 | Start AI Processing and Skip the Court and Net pages | The run starts with no net. Known gap since D-043: nothing on screen says that rallies aren't checked against a net that is not confirmed; G2's log line does. |
| G2 | Let it run | It completes. The console has one "ℹ️ No net geometry (no court and net calibration): the under-net, off-court, above-net rules were skipped." line and a "⏱ [timing] multi-frame only (ball_heat)" line with **YOLO 0.0 s (0 frames, none)**. Note the rally count, the processing time and whether the phone warmed. |
| G3 | Reprocess (Debug Features → Reprocess Video): its pages are Camera position, Court and Net; confirm the net on its page | It completes; no "No net geometry" line. Compare the rallies with G2: a rally on a neighbouring court or a ball rolled under the net that G2 kept should be gone; no real rally should be lost. Write down any that is. |
| G4 | Debug Features on → Debug Processing on a short video | A full-length video with the balls boxed, the track's trail, and the HUD (det, proj, rally, R²). It is made in two passes: the progress bar runs twice. |
| G5 | Settings → Debug Features | No Ball Model or Ball Finder row. |
| G6 | In RallyLab on the iPhone: track a rally not tracked before | Candidates appear (from the multi-frame model); fixing a point re-solves and looks again. Note the frames where no candidate is offered and the ball had to be placed by hand. |
| G7 | In RallyLab on the iPhone: open a rally tracked before this build | It opens as it was saved; nothing moved. |
| G8 | In RallyLab on the iPhone: Run pipeline on a video | It runs; the title says "Multi-frame only"; no net box is drawn. |
| G9 | Split a video into two camera views and confirm the net in both, then let it run | Processing it logs "No net geometry (the camera view changes during the video)". (The line that said so on the video's screen went with the row, D-043.) |
| G10 | Start processing a long video with a confirmed net, leave the app until the run is suspended, start again and change the net on the Net page | The run starts from the beginning, not from where it stopped (the progress bar starts at zero). |

## H. Assisted tracking in RallyLab on the iPhone, before and after

The new build finds candidates with the multi-frame model alone; the build before it also ran a single-frame detector. This measures what that costs. Use two recordings that are not withheld, each with at least six rallies not tracked yet.

| # | Do | Write down |
|---|---|---|
| H1 | **Before installing the new build:** on each recording track three rallies not tracked before | For each rally: frames in the rally, frames where no candidate was offered and the ball was placed by hand, fixes made, minutes taken |
| H2 | **After installing:** on the same two recordings track three other rallies not tracked before | The same four numbers |
| H3 | In either build, after a fix | Whether "look again" filled in frames either side |

The rallies differ between the two columns, so this is a comparison of rates (hand-placed frames per hundred frames), not of the same frames. A clearly worse rate on the new build is a result to report, not a reason to change a label.

## Results

| Date | Phone / iOS | Branch head | Sections passed | Failed (ids) | Notes |
|---|---|---|---|---|---|
| | | | | | |

Processing record (section G):

| Recording | Surface | Length | No net: rallies · time to process · phone warm? | Confirmed net: rallies · time | Rallies lost with the net | False rallies removed by the net |
|---|---|---|---|---|---|---|
| | beach | | | | | |
| | grass | | | | | |
| | indoor | | | | | |

Tracking record (section H):

| Recording | Build | Rally | Frames | Placed by hand | Fixes | Minutes |
|---|---|---|---|---|---|---|
| | before | | | | | |
| | after | | | | | |
