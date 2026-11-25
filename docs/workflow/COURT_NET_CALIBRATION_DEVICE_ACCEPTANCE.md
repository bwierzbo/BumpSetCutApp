---
name: court-net-calibration-device-acceptance
status: prepared, not run
created: 2026-11-25T01:23:16Z
updated: 2026-11-25T01:23:16Z
---

# Court & Net Calibration — device acceptance (Release 1, manual)

The checks a person makes on a **physical iPhone** before the manual Court & Net release goes to internal TestFlight (D-042; authorisation §10 and §12). Prepared with the editor's PR; **not run**. Unit tests cover the geometry, the file's rules and the editor's state; they cannot cover touch, zoom, the loupe or how the screen reads in the hand — this list does.

No model and no proposal is involved anywhere in these steps.

## Before starting

- A build of the branch on the phone, with at least one landscape and one portrait volleyball video in the library, each a minute or longer; one of them with a near end line that is out of the picture, if there is one.
- Note the phone model and iOS version in the results table.

## A. Opening

| # | Do | Expect |
|---|---|---|
| A1 | Library → open a video that has not been processed | A **Court & Net** row under the buttons reads "Mark the court and net on this video" or "Not calibrated". Processing can still be started without touching it. |
| A2 | Tap the row | The editor opens on a frame of the video. Status "Not calibrated". The hint asks for the court's near-left corner. |
| A3 | Open a processed video's screen | The same row is there; View Rallies still works. |

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
| B9 | **Save draft**, close, reopen | Everything is where it was. The row on the video screen reads "Draft". |
| B10 | **Confirm court** | "Court confirmed"; the Court tab shows ✓. |
| B11 | Place three points on top of each other on another video and confirm | Refused with the reason; the points are kept as a draft. |

## C. Net, by hand

| # | Do | Expect |
|---|---|---|
| C1 | Switch to **Net**, tap its four corners | A four-sided shape that follows the net's tilt — not a level rectangle. The court dims but stays visible. |
| C2 | Hide the court (orange eye), then the net (green eye) | Each overlay hides and shows on its own. |
| C3 | Save with only three corners placed | "Saved. The net needs all four corners…"; the three stay on screen. |
| C4 | **Confirm net** | "Court and net confirmed". The row on the video screen says the same. |

## D. Later edits

| # | Do | Expect |
|---|---|---|
| D1 | Reopen, move a court point | The Court tab reads "✓ edited"; the status stays confirmed. Close without saving, reopen: the confirmed court is unchanged. |
| D2 | Move a point and **Confirm court** | Confirmed again with the new position. |
| D3 | ⋯ → **Start the court over** | The points go. Close and reopen: the earlier confirmed court is shown (it stays until another is confirmed). |
| D4 | ⋯ → Surface and Players a side | Kept after closing and reopening. |

## E. Frames and camera views

| # | Do | Expect |
|---|---|---|
| E1 | Step one frame forward and back; ±5 s; drag the slider | The picture follows; the time reads to hundredths; the marks stay put. |
| E2 | Go to the middle of the video, ⋯ → **Camera changed here → Start from these marks** | "Camera view 2 of 2". The marks are there but not confirmed; the video screen's row reads "Needs review" until view 2 is confirmed. |
| E3 | Scrub back before the split | "Camera view 1 of 2" with its confirmed marks. |
| E4 | In view 2, ⋯ → **Not a stable court view** | A banner says so; taps place nothing. **It is a stable view** undoes it. |

## F. Orientation, size and endurance

| # | Do | Expect |
|---|---|---|
| F1 | Repeat B1–B10 on a portrait video | The frame is upright; points land where tapped. |
| F2 | Turn the phone to landscape in the editor | The picture is on the left, the controls scroll on the right; marks are where they were. |
| F3 | Largest Dynamic Type size | Every control is reachable; nothing is cut off beyond use. |
| F4 | VoiceOver on | Close, Save draft, Confirm, the eyes, zoom, the frame buttons and the point chips are announced with their state. (Placing points by touch on the picture is not a VoiceOver flow in this release.) |
| F5 | A 30-minute video, scrub end to end, zoom to the limit | No stall beyond a moment per frame, no crash, no heat warning. |
| F6 | Delete a calibrated video from the library | Nothing of it is left (its calibration goes with it). Processing a calibrated video again keeps its calibration. |

## Results

| Date | Phone / iOS | Build | Passed | Failed (ids) | Notes |
|---|---|---|---|---|---|
| | | | | | |
