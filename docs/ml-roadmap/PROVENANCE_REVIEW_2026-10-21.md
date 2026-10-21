---
name: provenance-review-2026-10-21
status: awaiting owner answers
created: 2026-10-21T14:22:38Z
updated: 2026-10-21T14:22:38Z
decisions: D-015, D-016
---

# Task B.1 — visual provenance review

A local page where the owner looks at frames of each final-test candidate next to the training recordings that may be from the same outing (Q1 of [PROVENANCE_QUESTIONS_2026-10-21.md](PROVENANCE_QUESTIONS_2026-10-21.md)) and at the four Dianne Gan recordings (Q3), and writes down venue, session and camera per recording plus a "same outing?" verdict per group. Q0 is settled by [D-016](../decisions/DECISION_LOG.md#d-016) (strict); Q4 stays deferred.

Nothing on the page is pre-filled or inferred. The hints in the questions document (adjacent Photos numbers, shared uploader) are not shown as answers; they only decided which recordings sit next to each other. "Unknown" is always an acceptable answer and is recorded as such.

## Generate and open

```bash
scripts/provenance_review.py                 # Scratch project, 5 frames per recording
open ~/Movies/RallyLab/Projects/Scratch/manifests/provenance-review/index.html
```

Options: `--project DIR`, `--out DIR`, `--frames N`, `--groups groups.json` (to review other recordings). Needs `ffmpeg`/`ffprobe` on PATH. The script reads `project.json`, `manifests/manifest.json`, `sessions/*.json` and RallyLab's 960-px review proxies in `scrub_proxies/`; it does not read or modify the footage, the sessions, the labels or the manifest, and does not need the desktop. Output goes only under `manifests/provenance-review/`: `frames/<video>/f1..f5.jpg`, `index.html`, `mapping.json`, `mapping.md`, `groups.json`. Re-running reuses existing frames only when `frames/<video>/source.json` still matches the proxy (path, size, mtime), its duration and the frame times; a changed `--frames` or a replaced proxy remakes them. RallyLab ignores that folder (it reads only `exposure-log.json`, `exposure-seed.json` and `exposure-log.unmerged-*.json` in `manifests/`).

Frames are taken at 10 %, 30 %, 50 %, 70 % and 90 % of each proxy, at proxy resolution (960×540 landscape or 540×960 portrait), aspect preserved. Click a frame to see it full size.

## Using the page

1. Each group shows the candidate (shaded) first, then the neighbouring training recordings, with split, card, source file, origin (a YouTube link where the recording was downloaded; the uploader is shown but is **not** evidence of venue), import dates, proxy dimensions, machine-track count and current exposure.
2. For every recording fill what you know: `venueId` (any stable name you will reuse), `sessionId` (the outing: date plus a tag), `camera / mount`, and set **status** to *confirmed*, *unsure* or *unknown*. Only *confirmed* rows are ever written to the project.
3. At the bottom of each group answer **Same outing?** (same venue and session / same venue, different session / different venues / unknown) and, if the candidate is not independent, which you would prefer: drop the candidate or move the training recordings out of train.
4. The page keeps a draft in the browser (saved on every change and with "Save draft"). **Download answers JSON** exports `provenance-answers.json`; save it outside the frames folder, for example `~/Movies/RallyLab/Projects/Scratch/manifests/provenance-review/answers/`, and hand it over. "Load answers JSON" restores an exported file into the form.

The page is a single file with no network access; it works from `file://` in Safari and Chrome.

### On the phone: the private artifact

The script also writes `artifact.html`, the same page for publishing as a **private claude.ai artifact** with the frames as supporting files, so the owner can review from a phone without the Mac. Published 2026-10-21 (private, owner only): the link is in the owner's claude.ai artifacts gallery ("Scratch Provenance Review"). On that copy the answers save as you type into the artifact's own database (one document per recording at `answers/<video>`, one per group at `groups/<groupId>`, same field names as the answer file plus `project` and `updatedAt`; the page restores only documents whose `project` is its own), and Claude Code reads them back with the ArtifactData tool and converts them to the `provenance-answers/1` form below. "Copy answers as JSON" puts the same export on the clipboard as a backup. Republish after regenerating: `Artifact` tool, same URL, `artifact.html` plus `frames/**`.

## Answer file

```json
{"schema": "provenance-answers/1", "project": "/Users/…/Projects/Scratch", "exportedAt": "…",
 "answers": {"<video>.venueId": "…", "<video>.sessionId": "…", "<video>.camera": "…",
             "<video>.status": "confirmed|unsure|unknown|", "<video>.notes": "…",
             "group.<groupId>.sameOuting": "same|same-venue|different|unknown|",
             "group.<groupId>.preference": "drop-candidate|move-training|n/a|",
             "group.<groupId>.notes": "…"}}
```

Empty strings mean "not answered". `project` names the project the page was generated for: the page refuses to load a file for another project, the browser draft is keyed by it, and the dry run refuses a file whose project differs from `--project`. The answers are never applied automatically. `scripts/provenance_review.py --answers provenance-answers.json` prints, as a dry run, the `RallyLab --project Scratch --set-provenance <video> --venue-id … --session-id …` commands that the *confirmed* rows imply and lists the unsure/unknown rows and the group verdicts as comments. Applying them is a separate reviewed PR with the before/after provenance report and a re-run of `--audit-dataset`, per D-015 §4.

## What is reviewed

Eight groups, 22 recordings, 110 frames (`mapping.md` and `groups.json` next to this file under [`manifests/Scratch/provenance-review/`](manifests/Scratch/provenance-review/) list every thumbnail with its time offset, source file, origin and exposure).

| Group | Candidate | Compared with (split) | Why these |
|---|---|---|---|
| Q1-bch_extra_self_05 | `bch_extra_self_05` (IMG_4969) | `bch_extra_self_31` (IMG_4970), `_30` (IMG_4967), `_29` (IMG_4966) — train | Photos numbers Δ1–3 |
| Q1-bch_extra_self_18 | `bch_extra_self_18` (IMG_0612) | `bch_extra_self_10` (IMG_0643), `_02` (IMG_0668) — train | nearest numbers, Δ31/56 (weak) |
| Q1-grs_extra_self_06 | `grs_extra_self_06` (IMG_0823) | `grs_extra_self_12` (IMG_0822) — train | Δ1 |
| Q1-grs_extra_self_07 | `grs_extra_self_07` (IMG_2378) | `grs_extra_self_02` (IMG_2379) — train | Δ1 |
| Q1-grs_extra_self_14 | `grs_extra_self_14` (IMG_4372) | `grs_extra_self_15` (IMG_4374), `_16` (IMG_4394) — train | Δ2/22 |
| Q1-grs_extra_self_21 | `grs_extra_self_21` (IMG_4778) | `grs_extra_self_20` (IMG_4776) — train | Δ2 |
| Q1-ind_extra_self_09 | `ind_extra_self_09` (IMG_0043) | `ind_extra_self_06` (IMG_0041) — train | Δ2 |
| Q3-dianne-gan | — | `bch_onl_sun_land_onl_03`, `_v2` (legacy_holdout); `grs_onl_sun_land_onl_04`, `grs_sid_shade_land_self_02_v2` (train) — YouTube links on the page | same uploader |

All 22 had a review proxy on the Mac; no recording is missing from the page.

## What is still unknown (as of this page)

- **Venue and session**: unconfirmed for all 22 recordings on the page, and for all 54 training `*_extra_self_*` imports and every YouTube-sourced recording. Confirmed provenance in Scratch today is the 73 YouTube `sourceId`s only (D-015 §5); no `venueId` or `sessionId` exists anywhere.
- **Candidate independence**: six of the seven candidates have a training import with an adjacent Photos number. Whether that is the same outing is exactly what Q1 asks; the audit records nothing until the owner answers.
- **Candidate promotability**: none, regardless of the answers. Under D-016 the `pre_tracking` exposure of 2026-10-18 stands, so the seven stay `CANDIDATE-BLOCKED` and protected; the verified final test comes from new footage. The Q1 answers still matter: they label the training outings (Q2), decide whether the candidates are even usable as the limited evaluation resource of D-015 §2, and tell the future collection which venues to avoid.
- **Dianne Gan overlap** (Q3): the two beach legacy-holdout recordings and the two grass training recordings share an uploader; the audit keeps this a soft finding until the owner gives venue IDs.
- **Q4** (Grace Qian / Blake Seegers cards across tune and dev_val): deferred to the D-007 tuning work, as before.

## What happens next

1. Owner fills the page and exports `provenance-answers.json`.
2. Implementer runs the dry run, opens a PR that applies the *confirmed* rows with `--set-provenance`, commits the before/after report and the regenerated manifest/audit, and states the group verdicts and preferences in the PR.
3. The audit decides what the answers imply (training neighbours sharing a venue/session with a candidate; Dianne Gan venues). Any split change is a further owner decision.
4. Task B.2 starts only after that PR is reviewed.
