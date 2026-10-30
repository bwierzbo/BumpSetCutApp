---
name: l2-promotion-and-net-model
status: accepted
created: 2026-10-30T21:32:22Z
updated: 2026-10-30T21:32:22Z
source: owner, delivered to Claude Code on 2026-10-30 (afternoon, MDT) after the H1 paired comparison (PR #109) was reported
---

> Verbatim record of the owner's direction, reproduced as received. In summary:
> - PR #109 is approved for merge. It was merged 2026-10-30 as `c195ae4`.
> - The L2 model (`l2_scratch_768_color_s20261021`, epoch 47) replaces the shipped L1 heat model everywhere the current one is used: the bundled `ball_heat` in BumpSetCut, RallyLab and RallyLab on the iPhone. This is D-026; it lands through its PR.
> - A new net model is to be trained on the desktop on a Roboflow dataset the owner is fetching.
>
> Not stated, so not assumed: protected-holdout evaluation, a second L2 seed, or a change to the public-launch licensing rule for Ultralytics-derived weights (2026-10-09).

merge 109 and use l2 for everything that we currently have and lets start the net model on the desktop ill grab the roboflow dataset
