---
name: setup-pages-authorization
status: accepted (owner instruction); D-043
created: 2026-11-27T20:39:37Z
updated: 2026-11-27T20:39:37Z
source: owner, delivered to Claude Code on 2026-11-27 while trying the Court & Net editor on the simulator
---

> Verbatim record of the owner's instructions, reproduced as received, with what he had been told between them.
> In summary: before a run the app shows four pages — trim, camera position, court, net — each of which can be
> skipped; the Court & Net row leaves the video's screen, and the court and net are marked on those pages only (D-043).

**The owner's instruction (2026-11-27), after opening the editor from the Court & Net row on the simulator:**

I would prefer that the court & net calibration shows up automatically after the camera position adjustment and you put it in or skip it make it three seperate but similar screens, you trim, tell it where the camera is, then the court then the net. each one you can skip each has its own dedicated page.

**After the four pages were built and shown to him:**

you can remove the bottom of the page that says court & net not calibrated before the processing

**What the owner was then told (Claude Code):** that with the row gone before a run, the row appeared only on the results screen right after a run, so a processed video had no way back to the editor, and that the acceptance scripts opened the editor through that row; with a recommendation to add Court & Net to the video card's long-press menu.

**The owner's answers:**

like a long press available even post processing?

wait dont add it now, what does that give us? why would we add that post processing instead of only allowing it preprocessing

**What the owner was then told:** that the confirmed net is read only when a video is processed, so changing the marks afterwards changes no rally until the video is processed again, and that reprocessing is a Debug Features tool; with a recommendation to remove the row completely, remove the stand-alone editor (the Court/Net tabs and Save draft), and repoint the acceptance scripts at the setup pages — at the cost that a normal user cannot fix bad marks on a processed video. Listed as step 1 of three (step 2: a feasibility check of recalibrating from saved ball data; step 3: building it if the check came out well).

**The owner's answers:**

maybe a calibrate setting added to you dont need to reprocess the entire video but you can recalibrate the camera angle net and court lines and it will redo the rally math not finding the ball

yes go all three

**Not asked back, and done on the implementer's judgement.** A reprocess goes through the camera, court and net pages (it has no trim page). The camera position page, which could not be skipped before, has a Skip like the others. A shape confirmed earlier and untouched shows "Continue" in place of "Confirm court" / "Confirm net". The line that said, before a run, that rallies are not checked against an unconfirmed net went with the row and has no replacement.
