---
id: EXP-20261108-player-detector-p1
status: done — detector comparison run 2026-11-08 (research only; no training; next step needs the owner)
created: 2026-11-09T01:02:44Z
updated: 2026-11-09T01:02:44Z
approved_by: owner 2026-11-08 ("go route B for now and look for a version we can use without training from scratch"); GUI and experiment-folder rules of the P0 authorisation
decision: D-034 (proposed)
pr: research/player-pose-feasibility-p0
---

# EXP-20261108-player-detector-p1 — Vision against RTMDet + RTMPose, whole frame and tiled

**Purpose.** Can a stronger person detector or tiling fix P0's 28 % on-court recall on the same frames? And which detectors could ship without training from scratch? Full method and results: [PLAYER_DETECTOR_COMPARISON_P1_2026-11-08.md](../PLAYER_DETECTOR_COMPARISON_P1_2026-11-08.md).

## Inputs

| What | Identity |
|---|---|
| Plans (frozen) | `EXP-20261108-player-detector-p1-vision-1x1.plan.json` `8ff6626c…`, `-vision-3x2` `71429bfb…`, `-rtm-1x1` `ec6f010c…`, `-rtm-3x2` `aed310ae…` — P0's recordings and intervals plus `detector` / `tiles` |
| Source project (read only) | Scratch; unchanged before and after (file listing, ledger, manifest hashes) |
| Footage | the P0 experiment's scrub-proxy copies |
| RTM weights (research only, experiment folder) | RTMDet-m person `235e820939cb2ff3…` (COCO + Objects365 v1; ImageNet-1k backbone init); RTMPose-m `5e55be2a03f6e5dc…` (AI Challenger + COCO) |
| Converted models | `rtmdet_m_person.mlpackage` fp16, digest `ea945f1f037f9a4a…`; `rtmpose_m_coco17.mlpackage` fp32, digest `f3cf72524151090e…`; converter `scripts/player_features/convert_rtm_coreml.py`; parity report `models/rtm/conversion-report.json` in the experiment |

## Runs

| Run | Code | Features manifest SHA-256 |
|---|---|---|
| `p1-vision-1x1` | `62ff13a` | `06f6ed4e1001d16cb05ed9b70123ea68d7743c25d800f510e596541c73711f7c` |
| `p1-vision-3x2` | `62ff13a` | `17406665cba19e9da04b964c0d55ef73ed80a64b3262b4c38af5bace29d6a1a0` |
| `p1-rtm-1x1-r2` | `c416ae2` | `e4cadf3db576b0c062c8fbd4fadcea58477c78928beabc687ac0c9c7cf0ef5fb` |
| `p1-rtm-3x2-r2` | `c416ae2` | `7274074510f82315bfc3acb540e67fe5311021ec2b764aade6583a2eefe30c89` |

The first `p1-rtm-1x1` / `p1-rtm-3x2` runs (`62ff13a`) read strided Core ML outputs as packed. They were discarded and their outputs deleted; their rows remain in the experiment ledger.

## Results

| | vision-1x1 | vision-3x2 | rtm-1x1 | rtm-3x2 |
|---|---|---|---|---|
| On-court recall (247 visible, 36 frames; reviewer counts, not owner-verified) | 0.26 | 0.76 | **0.96** | 0.96 |
| False "in" per frame | 0.1 | 1.5 | 2.9 | 4.6 |
| Wall time per frame (M3 Pro, under load) | 15 ms | 63 ms | 204 ms | 596 ms |

## Conclusion

RTMDet + RTMPose on the whole frame is the strongest of the four, but its weights are research-only. Court membership is now the bottleneck. Recommended next steps, each the owner's call:
1. the same comparison with RF-DETR S/M, whose weights are explicitly Apache-2.0 for commercial use;
2. a court-membership fix, measured on this audit.
