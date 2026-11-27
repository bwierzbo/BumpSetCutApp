---
name: recalibrate-pipeline-split-authorization
status: accepted (owner instruction); D-044
created: 2026-11-27T20:43:15Z
updated: 2026-11-27T20:43:15Z
source: owner, delivered to Claude Code on 2026-11-27, after the setup pages of D-043
---

> Verbatim record of the owner's instructions, reproduced as received, with what he had been told between them.
> In summary: a processed video is to be recalibrated — camera position, court, net — and its rallies redone from the
> balls already found, without finding the ball again; the pipeline is split for that first (D-044).

**The owner's idea (2026-11-27), told that changing a processed video's net does nothing until the whole video is processed again:**

would it not require another full process of the video?

maybe a calibrate setting added to you dont need to reprocess the entire video but you can recalibrate the camera angle net and court lines and it will redo the rally math not finding the ball

**What the owner was then told (Claude Code), after a read-only check of the code:** that it cannot be done as things stand — an ordinary run saves no per-frame ball data (it is saved only with footage sharing on, and then only around the rallies that were kept); the only replay, RallyLab's, redoes the final rally decision and not the tracking the net and the camera position act in. That it needs: a file of every frame's ball detections saved on every run; the tracking-and-decision part of the pipeline as one function that a live run and a replay both call; trims, favourites and scores carried to the new rallies by overlap in time; and that after Free Up Space nothing can recover a missed rally. That it is a change to the core shared with RallyLab, for its own reviewed PRs, and helps only videos processed after it ships.

**The owner's answers:**

how much extra storage will that take for each user? i want every user automaticaly opted in for support and let them know and they can opt out if they want to in a onboarding page or something, and im okay with freeup space preventing people from reprocessing or recalibration, explain to me more how the carry over the edits would become. and tell me more about the split of the pipeline

**What the owner was then told:** an estimate of 1–3 MB per hour of video for the detections file in a compact form (not measured); that saving ball data on the phone needs no opt-in and is separate from footage sharing, with the question of which he meant; how edits would follow rallies by overlap; and what the split is — finding the ball apart from deciding what it means — with the proof proposed: the same videos processed before and after, identical rallies required.

**The owner's answer:**

i mean opting in to footage sharing for more training. yes lets split the pipeline that will also help with tuning rallies too,

**On RallyLab's tests, asked whether to run all or only those affected, and told they launch RallyLab:**

sure go ahead rallylab is closed

**Not part of D-044.** Footage sharing on by default with an onboarding page to opt out is the owner's instruction above; it is its own decision, to be logged with the change that makes it. The implementer told the owner that the App Store privacy label and the privacy policy must say so, and that in the EU and the UK uploading a user's video generally needs consent given first.
