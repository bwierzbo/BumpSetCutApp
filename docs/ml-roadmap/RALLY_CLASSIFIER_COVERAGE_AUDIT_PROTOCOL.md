---
name: rally-classifier-coverage-audit-protocol
status: frozen 2026-11-14 on the owner's authorisation; pilot not yet reviewed
created: 2026-11-15T07:03:36Z
updated: 2026-11-15T07:31:25Z
decision: D-001, D-002, D-021, D-028, D-030, D-032, D-033, D-036, D-037; the owner's authorisation of 2026-11-14 ("Merge Remaining Corrective PRs and Complete Classifier Readiness", section "Negative-coverage audit")
---

# Negative-coverage audit of `rc-v1-20261112`: are the unmarked seconds really non-rally?

Owner requirement (2026-11-03): "Confirming a recording's type as continuous is necessary, but it does not independently prove that every rally was marked. Before authorizing training, prepare a small, independently reviewed coverage-audit protocol for the legacy declared-complete recordings. The audit should identify missed rallies and incorrectly labeled dead-time intervals. Do not automatically promote unreviewed time to trusted negatives."

Owner authorisation (2026-11-14), the parts that bind this document: "The owner does not waive negative-label verification." "Adapt the protocol and sample-draw tool from PR #138 to the actual corrected dataset `rc-v1-20261112`." "Freeze the audit protocol, sample selection and pass/fail criteria. Preserve group independence. Sample four eligible continuous recordings per surface where feasible. Refuse all protected recordings and aliases. Bind the draw to the dataset, current marks and source identities." "Hide ball-path and pipeline predictions during the audit. Do not fabricate human review or automatically certify unmarked intervals." "Record missed rallies, missed serves, boundary errors, non-rally activity, edited footage and uncertainty separately." "Start with the 12-recording pilot." "Arrange the blind repeat sample and document reviewer independence accurately." "If the pilot passes, proceed to review the remaining eligible continuous recordings supplying negative labels. A passing sample does not automatically certify unaudited recordings." "Only explicitly reviewed clean intervals or eligible Stage 1 verified coverage may supply trusted negatives under the adopted G7 policy." "Do not allow edited footage to supply full-video negative labels." "Never modify a sealed dataset or frozen folds file in place."

This protocol is the one proposed on PR #138 (not merged), adapted to the dataset that exists. What changed, and why, is in §11. It follows the shape of [EVENT_BOUNDARY_REVIEW_PROTOCOL.md](EVENT_BOUNDARY_REVIEW_PROTOCOL.md) (D-004) but certifies something different and cheaper: not where a rally's boundaries are, but whether the time **between** marks contains play. It is the condition under which a `NON_RALLY` label of the [dataset contract](RALLY_CLASSIFIER_DATASET_CONTRACT.md) may carry weight in the first classifier experiment ([preregistration](experiments/EXP-20261103-temporal-rally-classifier-prereg.md)).

The sample, the verdicts, the record and the pass / fail criterion below were fixed before any draw was made and before any interval was reviewed. This document is not edited afterwards: results go into their own record, and a change to the protocol is a new document that supersedes this one.

## 1. What is certified, and what is not

- **Certified:** for each reviewed unmarked interval of a recording, that a person played the whole interval and saw **no rally and no served ball** in it, and that the neighbouring marks do not leave more than 1.0 s of play inside it. Only such an interval — recorded `clean` — may supply trusted negatives (§9).
- **Not certified:** rally boundaries (Stage 1, `rally_event_truth_v1`), ball boxes, whether a mark has the right *kind*, anything about a withheld recording, anything about an edited recording, anything about an interval nobody reviewed.
- An interval nobody reviewed stays `UNKNOWN` (weight 0). Nothing is promoted by inference: not by an interval's length, not by the recording's type, not by the declaration `ralliesMarked`, not by a model, and not by a passing pilot.
- The audit writes **no rally mark**. What it finds is handed to the normal marking pass (D-028) as a list; the auditor's approximate times are evidence for the marker, not labels.

## 2. The inventory the audit rests on

Read from the manifest of `rc-v1-20261112` (manifest SHA-256 `eaa95c08…`, digest `1b1e6898…`) and from the project's metadata. No video was opened for any figure here.

| Fact | Consequence |
|---|---|
| 49 recordings in 25 recording groups. 31 are `recordingType == continuous` with `eligibility.fullVideoNegatives == standard`: beach 9 in 4 groups, grass 9 in 6, indoor 13 in 8 — 18 groups. 18 are `edited` (`restrictedUse`, positives only) | the audit's population is the 31; an edited recording is never audited for negatives and never supplies one |
| Over the 31: 402 unmarked intervals, 6,040.5 s; 15 intervals shorter than 3 s. Per recording 8 to 20 intervals (mean 13) and 125 to 260 s of unmarked time (mean 195 s); each recording is a card of about five minutes | every interval is reviewed, whatever its length; a recording costs about three minutes of video at 1× |
| Over the 31: 340 rally marks (7 to 16 per recording, mean 11), 31 missed-serve marks, 8 cut ranges on 7 recordings; no time-breaking span on any recording | twelve drawn recordings hold roughly 100 to 180 rally marks (§8's table) |
| Of the 31, 26 are in the split `train`, 5 in `tune`, none in `dev_val`. The experiment is grouped five-fold over the frozen folds file ([`…folds-rc-v1-20261112.plan.json`](experiments/EXP-20261103-temporal-rally-classifier-prereg.folds-rc-v1-20261112.plan.json), SHA-256 `b5e4b4ef…`); the 18 groups lie 2, 4, 4, 4, 4 over folds 0 to 4 | the split names no longer partition the experiment's use of a recording (§4, §11); fold 0 has no group to spare (§9) |
| Every recording's `coverage.state` is `declared_complete`, `labelProvenance.method` is `legacy_declared`, and `labelProvenance.marksSha256` is the marks file at export. No Stage 1 record (`rallyevents.json`) exists | declared is not verified; the audit record carries its own provenance (§7) |
| A mark is `{startTime, endTime, kind?, contacts?}` — no annotator and no time of marking (`RallyMarkRecord`, `Labeler/Shared/RallyEvents.swift`) | who made a given mark cannot be read from the data (§6) |
| Marks were made on 960 px scrub proxies; a live-tag press is backed up 0.25 s × rate and snapped within 0.4 s to a ball-path change (`Labeler/Shared/LiveTagger.swift`) | an interval's edges are uncertain by up to about 0.5 s, the label schema's ignore band; a boundary error is recorded only beyond 1.0 s |
| Phone sync replaces a marks sidecar whole when the server's row is newer (`RallyLab/LabelingSync.swift`) | the audit record is a **separate** sidecar that live tagging and sync never write |
| The detector packager takes unmarked time in declared-complete recordings as dead-time windows with no coverage check (`RallyLab/MultiFramePackage.swift`) | the pilot's result is also the first measurement of that risk; it is reported, not acted on here |
| The withheld closure the dataset was exported against: 24 names, 8 confirmed sourceIds, 45 fingerprints (`closureSha256 ff4f7f7b…`, D-036 / D-037) | every tool of this protocol refuses the closure by every identity (§4.4) |

On 2026-11-15 the inventory adapter (§3) was run read-only against the project, writing outside it and drawing nothing: all 49 marks files hash to the dataset's `marksSha256`; the project's `project.json`, `validation.json` and sessions digest equal the dataset's; the adapter's rallies, excluded spans and cut ranges equal the manifest's for all 31 recordings, tick for tick; the folds file is the dataset's and unedited (`folds.load`); 31 eligible, 18 left out (all edited), 402 intervals. The frozen draw file, not this paragraph, is the record of the state the audit starts from.

## 3. Population, unit and the inventory adapter

**Population.** The dataset's recordings with `recordingType == continuous` and `eligibility.fullVideoNegatives == standard`.

**Unit.** An *unmarked interval* of a recording: a maximal interval of `[0, duration)` that no rally, no excluded span (`missedServe`, `other`) and no cut range covers. Overlapping or touching spans are merged first; the time before the first span and after the last are intervals. Ticks are the dataset's (600 per second). **Every interval is reviewed, whatever its length**: a sub-second interval can hold a missed serve, and an edge interval can hold a rally the recording clipped.

**Current marks, the exporter's arithmetic.** Intervals are computed from the project's marks and cut ranges **as they are when the inventory is built**, read as `RallyClassifierExporter` reads them: the marks through `RallyTruth` over the session's normalised cut ranges (a piece a cut leaves shorter than 0.1 s is dropped), a rally starting at its marked serve contact when the mark has one, ticks `round(seconds × 600)` with halves to even, the recording's duration as the dataset recorded it. An interval is therefore exactly the time the exporter labels outside every rally, excluded span and cut range. A recording whose marks changed since the export is still audited, on its current marks, and is listed (`marksChangedSinceExport`): the audit serves the next export, not the old one.

**The adapter** — `scripts/rally_classifier/coverage_audit_inventory.py --dataset <dir> --project <dir> --closure <closure.json> --folds <folds.json> --out <inventory.json>` — reads the dataset manifest, the frozen folds file, the export's withheld-closure file and the project's JSON (`project.json`, `manifests/manifest.json`, `pipeline_tuning/validation.json`, `sessions/`, `footage-properties/`, the `<video>.rallylabels.json` sidecars). It never opens a video. It writes `coverage_audit_inventory_v2`:

- `dataset` (name, manifest SHA-256 and digest — `validate_dataset.dataset_identity` — timescale, label schema, counts, surfaces), `folds` (file SHA-256), `splitManifest` (the four hashes at export and now, and which changed), `withheld` (the closure file's SHA-256 and counts; the names, sourceIds, fingerprints and alias groups refused);
- `recordings`: per eligible recording its group, surface, camera, split, fold, duration in ticks, card fingerprint, content fingerprint (the original's file identity, from the split manifest), confirmed sourceId, alias group, the SHA-256 of its marks file now and at export and whether they differ, its rallies, excluded spans and cut ranges in ticks and whether they differ from the dataset's, its mark counts, and `intervals: [{index, startTick, endTick}]`;
- `leftOut`: **every** dataset recording that is not eligible, with the reason — none is dropped silently.

Left out, with the reason: withheld by any identity (§4.4); edited, or full-video negatives not `standard`; not in the current split manifest; card fingerprint or confirmed sourceId changed since the export; no fold; typed other than continuous now, or no footage-type record now (`footage-properties/`); the pass no longer declared complete; a Stage 1 record beside the video (its coverage is Stage 1's to verify); no marks file, or one RallyLab could not decode; a rally mark overlapping a cut range, or two rally marks overlapping (the exporter's own refusals); no content fingerprint.

Refused, nothing written: an empty closure; a closure file that does not hash to its own `closureSha256` or is not the closure the dataset carries; a folds file that `scripts/rally_classifier/folds.py load` refuses — drawn for another dataset (name, manifest SHA-256 or digest), or changed since it was drawn; a split manifest older than `project.json` or `validation.json` (the closure read from it would be stale).

## 4. Sample and draw

### 4.1 The pilot (stage 1)

Twelve recordings: **four per surface, at most one per recording group**, drawn by `scripts/rally_classifier/coverage_audit_draw.py` from the inventory. Procedure `coverage_draw_v2`; every number is fixed here and none is a command-line option:

1. One generator, `random.Random(20261114)`. It is only ever asked for `random()` — the one method Python guarantees to reproduce for a seed across versions. "Drawn order" of a list means: one `random()` key per element, taken in the order the list is given, and the list sorted by key.
2. The dataset's surfaces in alphabetical order (beach, grass, indoor). For each surface: the recording groups that hold an eligible recording on that surface and have not been drawn from, sorted by group id, are put in drawn order; the first four are the surface's groups. Then, for each of those groups in group-id order, its eligible recordings on the surface, sorted by recording id, are put in drawn order and the first is the group's recording.
3. **Where feasible.** A surface with fewer than four eligible groups gives one recording from each group it has; the draw file says so per surface (`whereFeasible`). The tool never takes two recordings from one group. With the inventory of §2, beach has exactly four eligible groups, so the beach draw is one recording from each beach group, and the three surfaces give 4 + 4 + 4.

Expected size, from §2's means: about 156 intervals and 39 minutes of unmarked video. The exact intervals, seconds and rally marks are in the draw file.

### 4.2 The blind-repeat set

For each drawn recording, in (surface, recording id) order and with the same generator: its interval indices in drawn order, the first max(2, ⌈n / 5⌉) of them — a fifth, at least two, all of them when it has fewer than two. **Plus** every interval the first review leaves `uncertain` (§5), which cannot be drawn in advance.

### 4.3 Stage 2

Every remaining eligible recording — 19 with the inventory of §2 — every interval, with a repeat set drawn the same way (the pilot's seed, a fresh generator). Stage 2 is listed by `coverage_audit_draw.py --stage2 --follows <pilot draw> --project <dir>` from a **fresh** inventory, since marks may have changed since the pilot draw. The tool refuses unless the fresh inventory is of the same dataset, folds file and protocol document as the pilot draw, and unless the pilot has **passed** — which it establishes itself by evaluating the audit records (§8), not from a claim. A pass certifies nothing about a recording that was not audited: a stage 2 recording supplies trusted negatives only from its own reviewed-clean intervals.

### 4.4 Refusals

By the inventory adapter and again by the draw tool (one function, `withheld_identity`, over the trainers' rule in `scripts/desktop_training/withheld_closure.py`), and by the recording operation in RallyLab:

- any recording whose **name**, confirmed **sourceId**, card **fingerprint** or content **fingerprint** is in the withheld closure, or whose **alias group** is a withheld recording's. The closure is the closure file's three lists together with the project's closure as it is now (`scripts/content_lineage/audit.py withheld_closure`: reserved splits, `validation.json`'s lists, and every recording that shares an identity with one). An empty closure is refused, as the dataset validator refuses it;
- any recording that is not in the dataset, not continuous, or whose full-video negatives are not `standard`;
- at recording time: a recording whose file identity now differs from the draw's `contentFingerprint`.

The draw tool also refuses a protocol document whose frontmatter status does not start with `frozen`, or that is not committed, or differs from its committed text; an existing draw file; and a second draw of the same stage for the same dataset without `--reason` (a new draw is a new file beside the old one, with the reason and the draws it supersedes recorded in it).

### 4.5 The draw file

`<project>/manifests/coverage-audit/<stamp>-draw.json`, `schemaVersion "coverage_audit_draw_v2"`, written once before anyone opens a video and never overwritten. `<stamp>` is `yyyyMMdd-HHmmss` (UTC) and is the `drawId`. It records:

- the dataset's name, manifest SHA-256 and digest; the folds file's SHA-256; the inventory's SHA-256; the split-manifest hashes at export and at the inventory; the withheld closure's `closureSha256`, the closure file's SHA-256 and the counts refused; the seed and the procedure; this document's path, SHA-256 and git commit;
- for each drawn recording: its group, surface, split, fold, camera, duration in ticks, card fingerprint, content fingerprint, sourceId, the SHA-256 of its marks file at the inventory, whether its marks changed since the export, its rally-mark count, `intervals: [{index, startTick, endTick}]` and `repeatIndices`;
- `whereFeasible` per surface; `notDrawn`, the eligible recordings left for stage 2; `leftOut`, the inventory's list;
- `criterion`: *n* (the rally marks of the drawn recordings at the draw), the confidence, the bound, the largest *m* that passes for that *n*, and the per-recording limit (§8) — so the criterion is a number in the frozen file before the first interval is played;
- for a stage 2 file: `follows` (the pilot's `drawId` and file SHA-256), the pilot's outcome, and the recordings already in the pilot.

### 4.6 Constraints of PR #138 that are dropped

PR #138 required "at least one `tune` and one `train` recording per surface" and excluded the `dev_val` recording `bch_ele_sun_port_self_03`. Both are dropped, not carried over:

- The experiment is grouped five-fold over the frozen folds file; the split names no longer partition its use of a recording, so balancing the sample over them serves nothing.
- The exclusion existed because that recording was one of three scan-flagged recordings whose type had not been decided. Recording types have since been confirmed by a person (D-032, D-033); that recording is typed `edited` in the dataset and is outside the population for that reason, like every edited recording.
- With one recording per group and four beach groups, the beach draw has no freedom left for a split constraint; and none of the 31 is in `dev_val`.

Instead the draw file records each drawn recording's split, fold, group and camera, so the spread of the sample can be read.

## 5. Review procedure and verdicts

**Blind to the pipeline.** The review surface is a queue driven by the frozen draw file: recordings, then intervals, with progress and "next unreviewed". It shows no ball path, no detector overlay, no pipeline clip and does no snapping; it does not construct or read them. Existing marks appear only as the bounds of the interval under review. What the pipeline misses therefore cannot steer what the reviewer sees.

**Per interval.** The interval is played with up to 1 s before and after it (clamped to the recording) for context. One review record per interval:

- `clean` — no rally, no served ball, no ball in play: dead time, walking, talking, ball retrieval. It is recorded **only by the reviewer's explicit action after the whole interval has been played** at no more than 2×: the surface tracks which ticks of the interval were played and refuses `clean` until all are covered; scrubbing and seeking do not count. Nothing else — length, recording type, a declaration, a model — ever produces `clean`.
- `not_clean` — with one or more findings, each `{kind, approxStartSec?, approxEndSec?, edge?, note?}`:

| `kind` | Definition | Recorded with it |
|---|---|---|
| `missed_rally` | a serve contact followed by play that no mark covers, including one clipped by the recording's start or end | approximate start and end (± 1 s is enough; the marker fixes them); `edge: start` or `end` when clipped |
| `missed_serve` | a served ball that does not become a rally (D-028's `missedServe`) that no mark covers | approximate start and end |
| `boundary_error` | the neighbouring mark starts after the serve contact, or ends before the ball is dead, by **more than 1.0 s** (twice the ignore band) | `edge: leading` (the mark before the interval ends early) or `trailing` (the mark after it starts late); the approximate seconds of play inside the interval |
| `non_rally_activity` | ball in flight that is not a rally: pepper, drills, warm-up hitting, a toss and catch, a ball rolled back | approximate start and end |
| `edited_footage` | replay, slow motion, montage, a camera cut, black frames, an overlay covering play | approximate start and end; a note |
| `uncertain` | cannot tell: the court is hidden, the file's edge, a proxy artefact | a note (required) |

The six kinds are counted separately everywhere (§8). An interval may carry several findings, of one kind or of several. Every verdict is saved at once, through the one save operation (§7).

**What happens to a finding.** A missed rally or missed serve goes to the marking pass as a correction. A boundary error goes to the marking pass (or Stage 1). Non-rally activity is recorded for the hard-negative class and does not make the interval a negative. Edited footage in a recording typed continuous goes to the footage-type pass: until the owner re-confirms the type, that recording supplies no negatives (§9).

## 6. Reviewer independence and the blind repeat

Stated as it is, not as it would be convenient:

- **The auditor is the owner.** In most cases the owner is also the person who made the original marks. A marks file records no annotator and no time of marking, so for a given recording this cannot be established from the data; marks that reached a sidecar through phone sync may be another labeler's.
- **The first review is therefore a second look by, mostly, the same person — blind to the pipeline, not an independent annotation.** It differs from the original pass in what is on screen (no ball path, no overlay, no snapping) and in what is asked (is there play *between* the marks), and it can find what the first pass overlooked. It cannot find what that person would consistently not count as a rally or a serve. Its result is reported as "second look, pipeline-blind", never as independent verification.
- **The blind repeat.** The repeat set of §4.2 is reviewed again with the first verdicts hidden — by a second person when one is available (`second_reviewer`), otherwise by the same reviewer **at least 24 hours** after that reviewer's first verdict on the interval (`same_reviewer_after_24h`). The record carries the method. A repeat by the same reviewer inside 24 hours is not accepted, and neither is one whose recorded method does not match who made it.
- **How agreement is reported.** Two looks at an interval agree when they give the same verdict and the same number of findings of each kind (approximate times are not compared). Agreement is reported per verdict class — `clean` and each finding kind: the intervals where both looks have the class, only the first, only the repeat — and separately per method. A `same_reviewer_after_24h` repeat is reported as a repeat by the same reviewer; it is **never reported as independent inter-rater agreement**.
- **Disagreement.** A disagreement is resolved by a third look with both verdicts visible (`resolutions`); the resolution is what counts. Until it is resolved the interval has no verdict: it is not clean, its recording is `partial`, and the pilot cannot be evaluated.

## 7. The record

A sidecar next to the marks sidecar, `<video>.coverageaudit.json`, `annotationVersion "coverage_audit_v2"`. It is written only by the audit's save operation in RallyLab — never by live tagging, never by phone sync — one verdict at a time, atomically.

```json
{"annotationVersion": "coverage_audit_v2", "recordingId": "…", "sourceFingerprint": "file:…",
 "drawId": "<stamp>", "drawSha256": "…", "datasetName": "rc-v1-20261112", "marksSha256": "<marks at review>",
 "timescale": 600, "blindToPipeline": true, "tool": "RallyLab <git sha or build>",
 "intervals": [{"index": 0, "startTick": 0, "endTick": 3120, "verdict": "clean",
                "reviewer": "<id>", "reviewedAt": "…Z", "playedAllAtMaxRate": 2.0},
               {"index": 7, "startTick": 71040, "endTick": 78600, "verdict": "not_clean", "reviewer": "…", "reviewedAt": "…Z",
                "findings": [{"kind": "missed_rally", "approxStartSec": 121.0, "approxEndSec": 127.5}]}],
 "repeat": {"method": "second_reviewer",
            "intervals": [{"index": 3, "verdict": "clean", "reviewer": "…", "reviewedAt": "…Z", "findings": []}]},
 "resolutions": [{"index": 3, "verdict": "…", "findings": [], "reviewer": "…", "resolvedAt": "…Z", "note": "…"}]}
```

- `sourceFingerprint` is the original's content fingerprint (the draw's `contentFingerprint`); `drawSha256` is the SHA-256 of the draw file's bytes; `marksSha256` is the marks file as it was at the review. `repeat.method` is `second_reviewer` or `same_reviewer_after_24h`. Times are UTC, `YYYY-MM-DDTHH:MM:SSZ`. `reviewer` is the signed-in labeler's id when there is one, otherwise a name the reviewer types once per session.
- `playedAllAtMaxRate` is the highest rate at which the interval was played for coverage; a first `clean` verdict without it, or with a rate above 2.0, is not accepted.
- **Void.** A record is void for a recording — every interval counts as not reviewed and it supplies nothing — when its `drawId` / `drawSha256` are not the draw's, its `datasetName` or `timescale` are not the dataset's, `blindToPipeline` is not true, or the recording's file identity differs from `sourceFingerprint`.
- A verdict is not accepted — its interval counts as not reviewed — when the interval's bounds are not the draw's, the verdict or a finding kind is unknown, `clean` carries findings or `not_clean` none, `uncertain` has no note, the reviewer or the time is missing, an edge or an approximate time is malformed, or the interval is recorded twice.
- **The recording's state is derived, never stored as authority**: `partial` when any interval of the draw is not reviewed or has an unresolved disagreement, or any verdict carries `uncertain` or `boundary_error`; `contaminated` when any verdict carries `missed_rally` or `missed_serve`; `audited_clean` otherwise (every interval reviewed; each clean, or carrying only `non_rally_activity` or `edited_footage`). Verdicts are taken after resolution. Contaminated outranks partial in reporting; a recording that is both is shown as both. The state is a summary: negatives come from intervals (§9), never from the state.
- **Ledger.** One `coverage_audit` row per recording per draw (a new `ExposureLogRow.Kind`: a person's use of the recording, like `event_review`, not model exposure), ref `coverage-audit <drawId>`, written by the shared save operation. An unwritable ledger fails the save.
- Three coverage provenances are then distinguishable and never conflated: `legacy_declared` (the toggle), `declared_audited` (this protocol), `stage1_verified` (Stage 1).

## 8. Pass / fail

Fixed here, before the draw, so the result cannot be read to taste.

**When the pilot can be evaluated.** Only when every interval of all twelve recordings has an accepted first verdict, every interval of the repeat set (§4.2, including every interval first left `uncertain`) has an accepted repeat verdict, and every disagreement has a resolution. Until then the outcome is `incomplete`; the report lists what is missing and gives no pass or fail.

**The criterion.** Let *m* be the number of `missed_rally` and `missed_serve` findings in the pilot, after resolution, and *n* the number of rally marks in the twelve recordings at the draw (the draw file's `criterion.n`). The pilot **passes** when both hold:

1. the exact one-sided binomial (Clopper–Pearson) upper 90 % bound on *m / n* is **≤ 5 %** — the bound is the *p* at which P(X ≤ *m*) = 0.10 for X ~ Binomial(*n*, *p*), and is 1 when *m* ≥ *n*;
2. **no single recording holds more than 2** such findings.

Otherwise it **fails**. The largest *m* that satisfies (1), computed with `coverage_audit_report.py` (bisection on the binomial distribution function; no approximation):

| *n* (rally marks in the pilot) | largest *m* that passes | bound at that *m* | bound at *m* + 1 |
|---|---|---|---|
| 100 | 1 | 3.83 % | 5.23 % |
| 110 | 2 | 4.77 % | 5.97 % |
| 120 | 2 | 4.37 % | 5.48 % |
| 130 | 2 | 4.04 % | 5.07 % |
| 140 | 3 | 4.71 % | 5.63 % |
| 150 | 3 | 4.40 % | 5.26 % |
| 160 | 4 | 4.93 % | 5.72 % |
| 170 | 4 | 4.65 % | 5.39 % |
| 180 | 4 | 4.39 % | 5.09 % |

With no finding at all the bound is 1 − 0.1^(1/n), which is within 5 % from *n* = 45 on. For the *n* of the actual draw the largest passing *m* is in the draw file.

**What the number is, and is not.** *m / n* is the ratio of missed to marked rallies and serves, treated as a binomial proportion over *n* trials. The missed events are not among the *n* marks (the share of all events that were missed is *m / (n + m)*, which is smaller), so the criterion errs toward failing. The bound assumes misses fall independently; in practice they cluster by recording, which condition (2) limits but does not remove. It is a statement about these twelve recordings' marks under this second look (§6), not about the corpus.

**Reported besides.** Missed rallies and missed serves each on their own; boundary errors, non-rally activity, edited footage and uncertain intervals, each with its count and its seconds against the seconds reviewed (a finding without approximate times has unknown seconds, counted apart, not zero; an `uncertain` finding without times takes its interval's length); intervals reviewed and not reviewed; each recording's derived state; the repeat's agreement by class and method; the marks that changed between the draw and the review.

**After a pass.** Stage 2 (§4.3) is reviewed the same way. The pass does not clear any unaudited recording or interval.

**After a fail.** The owner is told the corpus's declared coverage is unreliable, with the findings. The findings list goes to the marking pass for corrective labeling; the intervals the corrections change are audited again (a new inventory and a new draw file with its reason); **no negative is used meanwhile**.

**Edited footage found.** An `edited_footage` finding in a recording typed continuous is reported to the footage-type pass. Until the owner re-confirms the type, that recording supplies no negatives; a recording typed `edited` supplies none in any case.

## 9. Trusted negatives: G6 and G7 reconciled

**G7, as adopted** ("Only explicitly reviewed clean intervals or eligible Stage 1 verified coverage may supply trusted negatives"). A step is `NON_RALLY` only if the existing rule of the dataset contract (§5 there) makes it so **and** either it lies inside an interval the recording's audit record holds as `clean` after resolution, **or** the recording has eligible Stage 1 verified coverage. Otherwise it is `UNKNOWN`.

- Because a clean interval was watched whole, any part of it is clean. When marks change later, trusted time = (the time unmarked now) ∩ (the reviewed-clean intervals). Time that was under a mark at the review and is unmarked now lies in no clean interval and is `UNKNOWN`.
- The rule is per interval, not per recording: a `contaminated` or `partial` recording still supplies negatives from its clean intervals, and an `audited_clean` recording supplies none from an interval that carries `non_rally_activity`. (PR #138 worded G7 per recording; the interval rule is the one adopted.)
- A void record (§7) supplies nothing. An edited recording supplies no `NON_RALLY` whatever any record says. A recording with an `edited_footage` finding supplies none until its type is re-confirmed. No audited negative is used in an experiment while the pilot has not passed (§8).
- In the dataset manifest, per recording: `coverage.audit: {state, auditSha256, drawId, cleanIntervals: [{startTick, endTick}], findings}` with the findings' counts; `labelProvenance.method` gains `declared_audited`. Because this changes the labeling rule, the label schema is versioned: `rally_activity_truth_v2`. A `v1` dataset stays readable and is reported as "negatives declared, not audited". **Neither existing dataset is touched**; `rc-v1-20261112` and its frozen folds file stay as they are, and audited negatives arrive with a new export.

**G6, counted over trusted negatives.** G6 as amended (A3 in §11 of the preregistration): at least two-thirds of the dataset's recording groups contribute valid negatives, and at least two such groups lie in every fold. Under G7 a group contributes only **trusted** negatives. For 25 groups that is at least 17 groups.

- Only 18 groups hold a continuous recording, 2, 4, 4, 4, 4 over folds 0 to 4. The pilot's twelve groups cannot meet G6 alone: **stage 2 is needed**.
- After stage 2, G6 holds only if at least 17 of the 18 groups end with a reviewed-clean interval that yields a negative, and both groups of fold 0 are among them. At most one group can fall out, and not from fold 0.
- If fewer than 17 groups contribute, or a fold has fewer than two, the exact deficiency is reported — which groups, which fold. **The gate is not weakened.** The experiment is then *need data*, as the preregistration says of a failed G6.

The preregistration's §11, written on 2026-11-13, lists G7 as proposed and the audit as an open decision. The owner's authorisation of 2026-11-14 decides it: the audit is run and G7 is the rule above. That record is amended in a change of its own; this protocol does not edit it.

`coverage_audit_report.py` estimates this count from the records: a group counts when one of its recordings has a reviewed-clean interval longer than the two 0.5 s ignore bands at its ends (a shorter one holds only `TRANSITION` steps) and no edited-footage finding. The authority is the label count of the `v2` export, checked by the validator.

## 10. Tooling

| Tool | What it does | Where |
|---|---|---|
| Inventory adapter | §3. Metadata only; lists every recording it leaves out | `scripts/rally_classifier/coverage_audit_inventory.py` |
| Draw | §4. The frozen pilot draw and, after a pass, the stage 2 listing | `scripts/rally_classifier/coverage_audit_draw.py` |
| Report | §8, §9. Reads the draw and the records; reviewed and not reviewed, each finding kind's count and seconds, derived states, repeat agreement by method, *m*, *n*, the bound, pass / fail / incomplete, the trusted-negative groups against G6. Exit status 0 only on a pass | `scripts/rally_classifier/coverage_audit_report.py` |
| Tests | Synthetic projects, inventories and records only | `scripts/tests/test_coverage_audit_inventory.py`, `…_draw.py`, `…_report.py` |
| Review queue and the save operation | §5, §7. The queue over the draw file; the shared save (refusals of §4.4, atomic sidecar write, ledger row) | RallyLab, a separate change |
| Exporter and validator, `rally_activity_truth_v2` | §9 | RallyLab and `scripts/rally_classifier/validate_dataset.py`, a separate change |

```bash
python3 scripts/rally_classifier/coverage_audit_inventory.py --dataset <dataset dir> --project <project dir> \
    --closure <project>/manifests/rally-classifier/<stamp>-closure.json --folds <folds.json> --out <inventory.json>
python3 scripts/rally_classifier/coverage_audit_draw.py <inventory.json> --out-dir <project>/manifests/coverage-audit
python3 scripts/rally_classifier/coverage_audit_report.py <pilot draw.json> --project <project dir> [--stage2 <stage 2 draw.json>]
python3 scripts/rally_classifier/coverage_audit_draw.py <fresh inventory.json> --out-dir <project>/manifests/coverage-audit \
    --stage2 --follows <pilot draw.json> --project <project dir>
```

## 11. Differences from the protocol proposed on PR #138

| | PR #138 (proposed 2026-11-03, not merged) | This protocol | Why |
|---|---|---|---|
| Status | proposed; nothing drawn | frozen on the owner's authorisation of 2026-11-14 | the owner did not waive negative-label verification |
| Dataset | the 34 declared-complete development recordings of the 2026-11-03 readiness audit | the 31 continuous recordings with standard negatives of `rc-v1-20261112` (49 recordings, 25 groups) | the corrected dataset is the one the experiment reads; 18 of its recordings are edited and outside the audit |
| Withheld closure | 21 recordings | the dataset's closure (24 names, 8 sourceIds, 45 fingerprints) and the project's closure as it is now; alias groups and content fingerprints also refused | D-036, D-037 |
| Sample constraints | 4 per surface, one per group, at least one `train` and one `tune` per surface, `bch_ele_sun_port_self_03` excluded, infeasible → refused | 4 per surface where feasible, one per group; the split constraint and the exclusion dropped; a surface with fewer groups gives one from each, stated | §4.6 |
| Seed and generator | `random.Random(20261103)`, re-shuffling until the constraints hold | `random.Random(20261114)`, `random()` keys only, no retry | nothing left to retry for; reproducible across Python versions |
| Stage 2 | only if the pilot fails the bound or the owner wants it | entered when the pilot **passes**: the remaining recordings are reviewed before their negatives are used; refused by the tool otherwise | "If the pilot passes, proceed to review the remaining eligible continuous recordings"; a pass certifies nothing unaudited |
| Unit | seconds, from an inventory of marks | ticks, from the current marks and cut ranges with the exporter's arithmetic; cut ranges are not unmarked time | intervals must agree with the labels the exporter writes; D-030 |
| Verdicts | one verdict per interval; `missed_rally` covers missed serves (a `kind` field); `play_bleeds`, `not_footage`, `unresolved` | `clean` or `not_clean` with one or more findings; `missed_rally` and `missed_serve` apart; `boundary_error`, `edited_footage`, `uncertain` | "Record missed rallies, missed serves, boundary errors, non-rally activity, edited footage and uncertainty separately" |
| `clean` | the reviewer's verdict | only after the whole interval was played at ≤ 2×, tracked by the surface | "Do not fabricate human review or automatically certify unmarked intervals" |
| Review surface | the existing Live-tag view with snapping off | a queue over the draw that constructs no ball path or overlay | "Hide ball-path and pipeline predictions during the audit" |
| Pass / fail | bound on missed rallies / rally marks ≤ 5 %, ≤ 2 per recording | the same criterion with *m* = missed rallies + missed serves; evaluated only when the pilot, its repeat set and its resolutions are complete; the largest passing *m* frozen in the draw file | the criterion is kept; completeness made a precondition |
| Stale marks | a changed marks file makes the whole audit stale | trusted time = time unmarked now ∩ reviewed-clean intervals | a clean interval was watched whole, so any part of it is clean |
| G7 | per recording: `audited_clean` or `stage1_complete` | per interval: inside a reviewed-clean interval, or Stage 1 verified coverage | the adopted policy names intervals |
| Contract | `coverage.audit` added to `v1`, "additive" | label schema `rally_activity_truth_v2`; `v1` datasets readable, reported "declared, not audited" | the labeling rule changes |
| G6 | "≥ 12 groups with negatives", counted over audited recordings | two-thirds of the groups and two per fold (A3), over trusted negatives: 17 of 25, so stage 2 is needed | 25 groups, five frozen folds |
| Record | `coverage_audit_v1`: one auditor per file, seconds, a stored `verdict` | `coverage_audit_v2`: reviewer and time per verdict, ticks, repeat and resolutions, the state derived | per-interval saving; provenance per verdict |
| Reviewer independence | "independently reviewed" in the requirement; repeat rule as here | §6 states that the auditor is mostly the original marker and that the first review is a second look, not an independent annotation | "document reviewer independence accurately" |

## 12. What this protocol does not authorise

- No training, no tuning and no model run. The audit runs no model and reads no model output.
- No merge of PR #138, and no use of its draw tool or inventory format.
- No change to `rc-v1-20261112`, to its frozen folds file, or to any sealed dataset. Audited negatives exist only in a later export under `rally_activity_truth_v2`.
- No mark is written, moved or deleted by the audit. Corrections go through the marking pass.
- No protected recording is listed, drawn, opened or reviewed; a withheld recording's coverage belongs to a separately authorised protected-annotation workflow, never to a draw from this tool.
- No interval is certified without a person's recorded verdict, and a passing pilot certifies no recording it did not review.
