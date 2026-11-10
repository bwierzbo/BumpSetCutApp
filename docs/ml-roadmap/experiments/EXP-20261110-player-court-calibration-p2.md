---
id: EXP-20261110-player-court-calibration-p2
status: built and piloted 2026-11-10 (research only; no training); courts await the owner's confirmation in Player Lab
created: 2026-11-10T20:04:02Z
updated: 2026-11-10T20:04:02Z
approved_by: owner 2026-11-10 ("P2 Assisted Court Calibration", PR #166 continuation; "If there are methods that work better depending on what type of volleyball you're at I don't mind asking the user")
decision: D-034 (proposed), P2 paragraph
pr: research/player-pose-feasibility-p0 (#166)
---

# EXP-20261110-player-court-calibration-p2 — assisted court calibration

**Purpose.** Propose a court automatically, have a person correct and confirm it, and sort players into court zones against confirmed geometry only. Full method and results: [PLAYER_COURT_CALIBRATION_P2_2026-11-10.md](../PLAYER_COURT_CALIBRATION_P2_2026-11-10.md).

## Inputs

| What | Identity |
|---|---|
| Run | `p1-rfdetr-keypoint-3x2` (P1 §9), features manifest `8374cd9e52862fa5…`: six development recordings, 1,350 frames |
| Footage | The experiment's scrub-proxy copies (no SMB, no source project opened) |
| Net | The person's net labels, as carried into the run manifest (all six `person_label`) |
| Audit | `runs-comparison/p1/audit-p1-rfdetr-keypoint-tiles.csv` (reviewer counts, not owner-verified) |

## Runs

| Run | Code | Output |
|---|---|---|
| `--player-lab-court … --report p2-court-pilot-r2 --propose` | `55984ec` (binary marked dirty: docs uncommitted, no code change) | `court-evals/p2-court-pilot-r2/summary.json` `f29d63fd4fa7d0e1…`; 6 calibration files (proposals only); 6 experiment-ledger rows |
| `p2-court-pilot` (first; identical numbers) | `2737e69` | Kept; its reads came before proposals logged them (report §5) |
| Scripted GUI check (throwaway copy of the experiment) | `2737e69` | Calibration with a `player_lab_script` confirmation (never used); editor renders `court-*-editor.png` |

## Results

- Proposals made on all six recordings: net-guided on 6, court lines on 6, combined on 1. By eye, the court lines are sensible on 3 and wrong on 2; the net-guided depth is off on every camera (report §5.1).
- Over the 36 audited frames, people counted "in" beyond the auditor's count: lane 4.3 per frame, net-guided 0.7, court lines 0.4. Short of it: 0.2 / 0.4 / 3.1. These are against unconfirmed geometry.
- Smoothing cuts zone changes per track per 10 observations from 0.11–0.53 to 0.02–0.12.
- Time: net-guided under 1 ms; court lines 4.0–6.0 s per camera view (Debug).
- Courts confirmed by a person: **0**. Human adjustment, boundary accuracy after confirmation, and servers classified outside are pending.

## Tests

- CourtCalibrationTests 17: maps, refusals, zones, feet, smoothing, the file's round trip and staleness, confirmation rules, segments, the store's refusals, the net-guided geometry, the line search on a drawn court, the ledger before the first frame, error against a confirmed court, and the assembler.
- LaunchGuardTests: `--player-lab-court`.
- Python: validator zone checks, 24/24.
- Full RallyLabTests: see the PR.

## Next (owner)

1. Confirm the six courts in Player Lab, then re-run the pilot without `--propose`.
2. Decide whether the line search stays.
3. Address the split boxes from tiling separately.
