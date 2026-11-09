---
id: EXP-20261108-player-detector-p1
status: done — detector comparison run 2026-11-08 (research only; no training; next step needs the owner)
created: 2026-11-09T01:02:44Z
updated: 2026-11-09T05:22:28Z
approved_by: owner 2026-11-08 ("go route B for now and look for a version we can use without training from scratch"; "yes, run the RF-DETR comparison"); GUI and experiment-folder rules of the P0 authorisation
decision: D-034 (proposed)
pr: research/player-pose-feasibility-p0
---

# EXP-20261108-player-detector-p1 — Vision, RTMDet + RTMPose and RF-DETR

**Purpose.** Can a stronger person detector or tiling fix P0's 28 % on-court recall on the same frames? And which detectors could ship without training from scratch? Full method and results: [PLAYER_DETECTOR_COMPARISON_P1_2026-11-08.md](../PLAYER_DETECTOR_COMPARISON_P1_2026-11-08.md).

## Inputs

| What | Identity |
|---|---|
| Plans (frozen) | `EXP-20261108-player-detector-p1-vision-1x1.plan.json` `8ff6626c…`, `-vision-3x2` `71429bfb…`, `-rtm-1x1` `ec6f010c…`, `-rtm-3x2` `aed310ae…`, `-rfdetr-small-1x1` `d2d3e46f…`, `-rfdetr-medium-1x1` `7443ee64…`, `-rfdetr-keypoint-1x1` `12484ac1…` — P0's recordings and intervals plus `detector` / `tiles` |
| Source project (read only) | Scratch; unchanged before and after (file listing, ledger, manifest hashes) |
| Footage | the P0 experiment's scrub-proxy copies |
| RTM weights (research only, experiment folder) | RTMDet-m person `235e820939cb2ff3…` (COCO + Objects365 v1; ImageNet-1k backbone init); RTMPose-m `5e55be2a03f6e5dc…` (AI Challenger + COCO) |
| RF-DETR weights (Apache-2.0, experiment folder) | rfdetr 1.12.0 checkpoints, MD5-checked: Small `d81979a9213a2109…`, Medium `749ff6071828aaff…`, Keypoint preview `2b70ddf51d2b9e02…` (COCO; DINOv2 backbone; Objects365 pretraining per the paper, unresolved) |
| RF-DETR packages | rfdetr's own Core ML export via `scripts/player_features/convert_rfdetr_coreml.py`: Small fp32, Medium fp16, Keypoint fp32; parity report `models/rfdetr/conversion-report.json` |
| Converted models | `rtmdet_m_person.mlpackage` fp16, digest `ea945f1f037f9a4a…`; `rtmpose_m_coco17.mlpackage` fp32, digest `f3cf72524151090e…`; converter `scripts/player_features/convert_rtm_coreml.py`; parity report `models/rtm/conversion-report.json` in the experiment |

## Runs

| Run | Code | Features manifest SHA-256 |
|---|---|---|
| `p1-vision-1x1` | `62ff13a` | `06f6ed4e1001d16cb05ed9b70123ea68d7743c25d800f510e596541c73711f7c` |
| `p1-vision-3x2` | `62ff13a` | `17406665cba19e9da04b964c0d55ef73ed80a64b3262b4c38af5bace29d6a1a0` |
| `p1-rtm-1x1-r2` | `c416ae2` | `e4cadf3db576b0c062c8fbd4fadcea58477c78928beabc687ac0c9c7cf0ef5fb` |
| `p1-rtm-3x2-r2` | `c416ae2` | `7274074510f82315bfc3acb540e67fe5311021ec2b764aade6583a2eefe30c89` |
| `p1-rfdetr-small-1x1` | `bee388d` | `b9025e01fd76251213b693cfba8f642ae8e9e098363c10f3c00d5b6b853a178e` |
| `p1-rfdetr-medium-1x1` | `bee388d` | `73fd2d364af9b06ae5e980b4f9874cdcf7712b37476fdaceb99b4835de90d538` |
| `p1-rfdetr-keypoint-1x1` | `bee388d` | `cfd5a89a195ac7f89fe0ffa31c3660579e1fceeddbf6f64be7d8b9e367094e88` |

The first `p1-rtm-1x1` / `p1-rtm-3x2` runs (`62ff13a`) read strided Core ML outputs as packed. They were discarded and their outputs deleted; their rows remain in the experiment ledger. Seven RF-DETR runs were also discarded: a dirty-tree build, an enlarged-crop pose variant (worse), runs overlapping other work or stopped, and three whose binary carried `7added3-dirty` (outputs identical to the kept runs). Report §8.1 lists them; their ledger rows remain too.

## Results

| | vision-1x1 | vision-3x2 | rtm-1x1 | rtm-3x2 | rfdetr-small | rfdetr-medium | rfdetr-keypoint |
|---|---|---|---|---|---|---|---|
| On-court recall (247 visible, 36 frames; reviewer counts, not owner-verified) | 0.26 | 0.76 | **0.96** | 0.96 | **0.96** | 0.96 | 0.71 |
| False "in" per frame | 0.1 | 1.5 | 2.9 | 4.6 | 3.9 | 3.8 | 0.6 |
| Share of detected people posed | 0.69 | — | 1.00 | — | 0.26 (Vision on crops) | 0.26 | 1.00 |
| Wall time per frame (M3 Pro, Debug build) | 15 ms | 63 ms | 204 ms | 596 ms | 193 ms | 233 ms | 203 ms |
| Detector model alone (Core ML) | — | — | 38 ms | — | 18 ms | 29 ms | 49 ms |

## Conclusion

RTMDet + RTMPose and RF-DETR Small tie on detection (0.96). RF-DETR Small's weights are Apache-2.0, its model runs about 2× faster than RTMDet-m's, and it boxes no floor reflections, so it is the detector to carry forward (the Objects365 question aside). The licence-clean pose options fall short: Vision on crops poses mainly players ≥ 150 px tall in the 960 px proxies, and RF-DETR Keypoint misses small players. Court membership remains the bottleneck. Next steps, each the owner's call:
1. a pose route for the shippable stack (report §8.6);
2. a court-membership fix, measured on this audit;
3. an Objects365-lineage question to Roboflow.
