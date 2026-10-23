---
name: owner-direction-progressive-rally-review
status: owner direction recorded for review
created: 2026-10-23
---

# Owner direction — progressive RallyLab review workflow (2026-10-23)

This is a concise *summary of the owner's voice discussion*, not a verbatim transcript. It records the requested roadmap change for review and does not authorise software implementation, dataset mutation, L2 training, holdout evaluation, or PR merge.

## Three distinct review stages

1. **Stage 1 — Rally boundary review, MVP priority.** Review the *entire duration* of each eligible development recording, not only previously selected rallies. Mark the exact serve-contact frame (not the toss), the first frame play ends (not when the ball finishes rolling), and the rally kind. Distinguish completed rallies, missed serves, and non-rally ball activity such as thrown balls, warm-ups, retrievals or bouncing; permit `uncertain` rather than guessing. Non-rally ball activity should be easy to flag without demanding exact timestamps for every toss. Record full-video review completion separately from a few rallies having annotations.
2. **Stage 2 — Contact review, optional and incremental.** Reuse Stage 1's persistent rally IDs and boundaries to present each known rally for detailed, contact-frame labeling: every touch, action (serve/pass/set/attack/block/free ball etc.) and technique (overhead/forearm/etc., with unknown where unclear). Work may be done gradually, recording per-rally progress. Stage 2 must not require redoing Stage 1.
3. **Stage 3 — Player identity/stats, deferred.** Later, when intentionally working on player statistics, associate contacts with individually tracked/identified players with an auditable correction path. No pose, tracking, re-identification or automatic statistics development under the present request.

## Scope and controls

- Implement and calibrate Stage 1 first using the previously approved **24-rally boundary pilot**, then extend to full-video coverage of eligible recordings. Do not confuse a 24-rally pilot with complete-video ground truth.
- Treat unreviewed intervals as **unknown**, not implicitly as dead time, non-rally, or negative ball-detector examples. Keep rally activity and ball visibility separate under D-010.
- Keep protected lineage/legacy holdouts and final-test candidates out of routine review by default; “every video” refers to review-eligible videos. Any exceptional protected access needs the already-approved separate process.
- Original video, ball boxes, earlier `rallylabels.json`, and frozen L2 training records remain unchanged; new reviewed events live in versioned, non-destructive annotations. Stage completion is tracked independently per recording (Stage 1) and per rally (Stages 2–3).
- After L2 training has been separately approved and **actually started**, implementation planning for the RallyLab Stage 1 tool may proceed under the PR/review workflow. This note does **not** initiate that training or any review operation.

## Source

Owner directions spoken in the ChatGPT conversation on 2026-10-23, summarized faithfully for owner review. Especially: “let's do path one for now,” “path one labels start and end of every single rally for every single video,” Stage 2 “takes our outputs of path one,” and “we won't do step three until much later.” The owner also agreed to quickly flag non-rally ball activity such as thrown balls.
