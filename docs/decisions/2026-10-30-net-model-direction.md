---
name: net-model-direction
status: accepted
created: 2026-10-30T21:54:35Z
updated: 2026-10-30T21:54:35Z
source: owner, delivered to Claude Code on 2026-10-30 (afternoon, MDT), after the net-dataset proposal and the handheld analysis
---

> Verbatim record of the owner's direction, reproduced as received (two messages). In summary:
> - The new net model is **not** an Ultralytics model, and the current Ultralytics `net.mlpackage` is to leave the code base. The implementer's recommendation, awaiting the owner's word: remove it in the PR that lands the replacement, so the pipeline's net gates never run without a net.
> - Handheld recordings are not a supported input for the temporal pipeline; the product may say so. Whether they hurt the training data was asked and answered in [NET_MODEL_PLAN.md](../ml-roadmap/NET_MODEL_PLAN.md) §3 (they don't, on the evidence available; kept in train, left out of the net dataset).
> - The net dataset is labeled by hand in RallyLab (the Net labels tab), one frame per recording, for every recording the project has; Roboflow is connected for the existing public dataset.
>
> Logged as a decision when the replacement model's PR removes `net.mlpackage` (the change that gives it effect).

yes this will be a non ultralytics net model we need to remove the current ultralytics net model from this code base. for handheld we might need to rethink because with our temporal model i think handheld shots unless super still just wont work and shouldnt work. i think thats something we can tell our user. now as far as using that data to train i need you to tell me if thats hurting more than helping our dataset.

roboflow is connected and you can build upon rallylab to make that manual labeling addon for all the frames of the videos we currently have.
