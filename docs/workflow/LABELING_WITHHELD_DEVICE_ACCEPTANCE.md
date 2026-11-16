---
name: labeling-withheld-device-acceptance
status: prepared — not run; needs a Labeler build on a physical iPhone, which needs a TestFlight build the owner approves separately
created: 2026-11-15T06:45:31Z
updated: 2026-11-15T06:45:31Z
---

# Device acceptance for PR #181: no model task on a withheld recording, by hand only for the lead

Owner, 2026-11-14 ([verbatim](../decisions/2026-11-14-classifier-readiness-authorization.md)): "Prepare #181 for physical-device acceptance and a subsequent separately approved TestFlight build."

PR #181 changed the phone app's labeling code (`Labeler/Store/LabelerModel.swift`, `Labeler/Tracking/TrackSession.swift`, the track and marking views). The shared rule (`LabelAccess`, `TrackWork`, `ModelLeave`) is covered by `RallyLabTests`; the phone-only glue has no test target and was build-verified only. This checklist is what a person does on a phone to accept it. Nothing here is run until the owner approves a Labeler TestFlight build.

## What the server already does (checked read-only on 2026-11-14)

| Check | Result |
|---|---|
| `label_withheld` for Scratch | 24 names, equal to the local withheld closure (16 lineage holdouts, their 3 train copies, 5 legacy holdouts); listed 2026-11-13T02:06Z |
| An ordinary labeler (row-level security, simulated with a non-lead labeler's identity inside a rolled-back transaction) | sees 119 of the 130 Scratch videos and none of the 11 withheld ones that have a server row; sees no track of a withheld recording |
| The lead | exempt by `private.is_lead()`: sees every row. The restriction for the lead is in the app (PR #181) and therefore only in a build that contains it |
| Withheld recordings with server rows | 11 of the 24 have a `label_videos` row with a clip; they hold 38 tracks, 36 of them machine tracks, all written before the list named them (kept: historical) |

## Before starting

- A Labeler build from `main` at or after the merge of #181 on the test iPhone (TestFlight, separately approved), signed in as the **lead**; a second device or account signed in as an **ordinary labeler** if one is available.
- RallyLab on the Mac has synced since the correction (the server list shows 24 names).
- Pick one withheld recording that has a server row with existing tracks (W₁, e.g. a legacy holdout) and one ordinary recording (O).

## Checks

| # | Account | Do | Expect | Pass |
|---|---|---|---|---|
| 1 | lead | Pull to refresh; open the queue | no track job is offered for any withheld recording; a marking job for W₁ may be offered | ☐ |
| 2 | lead | Open W₁ → an existing tracked rally | opens **by hand**: frames and existing boxes load; the screen says why; "look again" and "more frames" are off; no detector progress appears | ☐ |
| 3 | lead | In that rally, move one box and save | only that frame changes; the correction syncs (check the Mac after its next sync) | ☐ |
| 4 | lead | Open W₁ → start a rally that has no track yet | nothing starts; the reason is on screen | ☐ |
| 5 | lead | Open W₁ → mark rallies | marking works; no found-rally suggestions and no snapping to a ball path | ☐ |
| 6 | lead | Airplane mode on; open O → a rally not tracked yet | nothing starts (the list cannot be fetched), with the reason; airplane mode off, retry → tracking starts | ☐ |
| 7 | lead | Open O → a rally not tracked yet (online) | the detectors run as before; the result is saved and syncs | ☐ |
| 8 | lead | While a track task on O is open, nothing else changes | no regression: boxes, "look again", "more frames" behave as before | ☐ |
| 9 | labeler | Pull to refresh | no withheld recording appears anywhere (queue, overview); a previously cached row of one disappears after the refresh | ☐ |
| 10 | labeler | Work one track job and one marking job on O | unchanged from before the update | ☐ |
| 11 | lead | Fresh install, first launch before the first successful reload | withheld recordings show as closed until the reload completes (an unknown role is not lead) | ☐ |

Record the build number, the device, the date, and for any failure the on-screen reason and a tagged console excerpt (see the device-logs skill). A failure of 1, 2, 4, 6 or 9 blocks wider distribution of the build.

## Known limits (from the PR, unchanged)

- Installed older builds have none of this: for a lead an old build is unrestricted until the new one is installed.
- A phone learns of a change to the list only at a pull or a fetch.
- The phone's "Process" tab runs the pipeline on any Photos video with no identity check; it is not a labeling task and is outside this change. A final-test recording must not be processed there ([final-test plan](../ml-roadmap/FINAL_TEST_FOOTAGE_ACQUISITION_PLAN.md) §3).
