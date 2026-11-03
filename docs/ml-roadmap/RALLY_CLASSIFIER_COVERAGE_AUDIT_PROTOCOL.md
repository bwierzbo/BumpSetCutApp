---
name: rally-classifier-coverage-audit-protocol
status: proposed — not approved; no audit has been drawn or performed
created: 2026-11-03T23:06:45Z
updated: 2026-11-03T23:06:45Z
---

# Independent coverage audit of declared-complete recordings: are the unmarked seconds really non-rally?

Owner requirement (2026-11-03): "Confirming a recording's type as continuous is necessary, but it does not independently prove that every rally was marked. Before authorizing training, prepare a small, independently reviewed coverage-audit protocol for the legacy declared-complete recordings. The audit should identify missed rallies and incorrectly labeled dead-time intervals. Do not automatically promote unreviewed time to trusted negatives. Record annotation provenance and distinguish legacy-declared coverage from independently verified Stage 1 coverage."

This protocol follows the shape of [EVENT_BOUNDARY_REVIEW_PROTOCOL.md](EVENT_BOUNDARY_REVIEW_PROTOCOL.md) (D-004) but certifies something different and cheaper: not where a rally's boundaries are, but whether the time **between** marks contains play. It is the condition under which a `NON_RALLY` label in [`rally_activity_truth_v1`](RALLY_CLASSIFIER_DATASET_CONTRACT.md) may carry weight. The plan it belongs to is [RALLY_CLASSIFIER_DATA_READINESS_PLAN_2026-11-03.md](RALLY_CLASSIFIER_DATA_READINESS_PLAN_2026-11-03.md) §2.

## 1. What is certified, and what is not

- **Certified:** for each reviewed unmarked interval of a recording, that it contains **no rally** (no serve contact followed by play) and that the neighbouring marks do not leave play inside it beyond the ignore band. A recording whose every unmarked interval is certified is `audited_clean`.
- **Not certified:** rally boundaries (Stage 1, `rally_event_truth_v1`), ball boxes, the count of rallies the marks got right in *kind* (a rally marked as a missed serve, say — that is a Stage 1 kind check), anything about withheld recordings.
- An interval nobody reviewed stays `UNKNOWN` (weight 0). The audit never promotes by inference, never by recording type, never by the declaration `ralliesMarked`.
- The audit writes **no rally mark**. A rally it finds is handed to the normal marking pass (D-028 live pass) as a listed correction; the auditor's approximate times are evidence for the marker, not labels.

## 2. Inventory the audit rests on (2026-11-03)

| Fact | Consequence |
|---|---|
| 34 declared-complete development recordings, 561 rally marks, 47 missed-serve and 1 other marks; 527 inter-rally gaps, 185 of them under 3.85 s (readiness §3) | the population of unmarked intervals is ≈ 527 inter-mark gaps + 68 edges; most are short |
| A mark is `{startTime, endTime, kind?, contacts?}`; no annotator, no timestamp (`Labeler/Shared/RallyEvents.swift:70-75`); `ralliesMarked` is a toggle a person sets ("counts in rally scoring", `RallyMarkModel.swift:95-104`); the queue treats it as a declaration, coverage nil (`WorkQueueReconciler.swift:108-112`) | declared ≠ verified; the audit record must carry its own provenance |
| Marks were made on 960 px scrub proxies; live-tag presses are backed up 0.25 s × rate and snapped within 0.4 s to ball-path changes (`LiveTagger.swift:67-87`); starts are toss-or-contact, ends press-time-or-path-end | an unmarked interval's edges are uncertain by up to ≈ 0.5 s — the ignore band of the label schema; `play_bleeds` is only recorded beyond that |
| Phone sync overwrites a sidecar wholesale when the row is newer (`LabelingSync.swift`) | the audit record is a **separate** sidecar that sync does not know |
| 0 `rallyevents.json`; Stage 1 refuses `stage1Complete` while any unknown gap wider than one frame remains (`EventReviewRecord.swift:245`) | Stage 1 coverage, when it exists, supersedes this audit for that recording (§7) |
| The detector packager takes unmarked time in declared-complete recordings as dead-time windows with no coverage check (`MultiFramePackage.swift:416-424`) | the contamination estimate of §5 is also the first measurement of that risk (reported, not acted on) |
| The 21 withheld recordings (16 lineage holdout, 5 legacy holdout) and their aliases are refused by name/source/fingerprint everywhere this protocol touches | the draw tool refuses them (§3); the sample is from development recordings only |

## 3. Sample and draw

**Unit.** An *unmarked interval* of recording *r*: a maximal interval of `[0, duration)` that no mark of any kind covers (rally, missedServe, other all count as marked; marks that overlap are merged first). Edges (before the first mark, after the last) are intervals. **Every interval is reviewed, whatever its length**: a sub-second interval can hold a missed serve, and an edge interval can hold a rally the recording clipped (Codex on PR #138) — "too short for a rally" certifies nothing. Short intervals cost seconds to review.

**Stage 1 (the pilot).** 12 recordings, **4 per surface**, drawn with `random.Random(20261103)` from the 34 by `scripts/rally_classifier/coverage_audit_draw.py` from a frozen inventory (§3.1), under these constraints checked by the tool: at most one recording per recording group (readiness §4 groups); at least one `tune` and one `train` recording per surface; the dev_val recording (`bch_ele_sun_port_self_03`) is excluded from stage 1 because it is one of the three scan-flagged recordings whose type is decided under G2 first; every unmarked interval of a drawn recording is reviewed. Expected size: ≈ 12 × 15 intervals ≈ 180 intervals, ≈ 60–80 min of unmarked video.

**Stage 2.** The remaining 22 recordings, same procedure, only if stage 1 fails the corpus bound (§5) or the owner wants every recording audited before its negatives are used.

**Freeze first.** The draw file records: the inventory's SHA-256 (the marks it was computed from), the split-manifest hashes, the seed, the drawn recordings and their intervals with indices. It is written to `manifests/coverage-audit/<stamp>-draw.json` **before** anyone opens a video, never overwritten (a new draw is a new file with a new stamp and a stated reason).

### 3.1 The inventory the draw reads

A JSON file produced by a small adapter (a later RallyLab command or the readiness-audit script extended; it reads only `manifest.json`, `sessions/`, and the `<video>.rallylabels.json` sidecars — never a video):

```json
{"schemaVersion": "coverage_audit_inventory_v1", "createdAt": "…", "project": "Scratch",
 "splitManifest": {"projectJson": "<sha256>", "sessions": "<sha256>", "validationJson": "<sha256>", "manifestJson": "<sha256>"},
 "withheld": {"names": ["…"], "sourceIds": ["…"], "fingerprints": ["…"]},
 "recordings": [{"recordingId": "bch_ele_ovc_land_self_02", "groupId": "g-…", "surface": "beach", "camera": "…", "split": "train",
                 "durationSec": 312.4, "ralliesMarked": true, "fingerprint": "file:…", "marksSha256": "<sha256 of the sidecar>",
                 "marks": [{"start": 5.2, "end": 12.9, "kind": "rally"}, {"start": 34.0, "end": 36.1, "kind": "missedServe"}]}]}
```

The tool refuses an inventory whose `withheld.names` is empty (as the dataset validator does), refuses any recording named in the closure or sharing a source id or fingerprint with it, and refuses a recording with `ralliesMarked != true`.

## 4. Review procedure and rubric

**Independence.** The auditor reviews **blind to the pipeline**: no detector overlay, no FSM clips, no ball path (the Live-tag view's path snapping is off), so that what the pipeline misses cannot steer what the auditor sees. The auditor sees the existing marks only as the boundaries of the interval under review (they define it). The original file is used where the proxy's timing matters (replay/zoom suspects); otherwise the proxy at 2× is sufficient for "is there play here".

**Per interval.** Watch the whole interval (plus 1 s on each side so a bleeding rally is visible). Record exactly one verdict:

| Verdict | Definition | Recorded extras |
|---|---|---|
| `clean` | no serve, no rally, no ball in play; dead time, walking, talking, warm-up without a served ball | — |
| `missed_rally` | a serve contact followed by play (any length), or a missed serve, that no mark covers — including a rally clipped by the recording's start or end (an edge interval) | `approxStart`, `approxEnd` (± 1 s is enough; the marker fixes them), `kind` rally / missedServe, `edge: start|end` when clipped |
| `play_bleeds` | the neighbouring mark starts after the serve contact or ends before the ball is dead by **more than 1.0 s** (twice the ignore band) | which edge, approximate seconds of play inside the interval |
| `non_rally_activity` | ball in flight but not a rally: pepper, drills, a toss and catch, a ball rolled back — the hard-negative class `NON_RALLY_ACTIVITY` of the label schema | `approxStart`, `approxEnd` |
| `not_footage` | replay, slow motion, montage, a camera cut, black frames — a time-breaking span or a cut-range matter (D-030/D-031), not dead time | `approxStart`, `approxEnd`, trait |
| `unresolved` | cannot tell (occluded court, file edge, proxy artefact) | note |

A `non_rally_activity` or `not_footage` finding does not fail the recording; it is handed to the properties/cut-range pass. A `missed_rally` always does (§5). `play_bleeds` beyond 1 s fails the interval; it is a boundary error the Stage 1 pass fixes, and until then that interval's edge seconds are `UNKNOWN`, not `NON_RALLY`.

**Blind repeat.** 20 % of the reviewed intervals (drawn by the tool with the same seed, at least 2 per recording) plus every `unresolved` are reviewed again blind — by a second person if available, otherwise by the same auditor after **at least 24 hours** with the first verdicts hidden. Agreement is reported per verdict class; a same-reviewer repeat is reported as a *repeat*, "never reported as independent inter-rater agreement" (boundary protocol §6.3). A disagreement is resolved by a third look with both verdicts visible and the resolution noted.

**Time per recording.** ≈ 5–7 minutes of unmarked video at 2×, plus notes: ≈ 6 min; stage 1 ≈ 1.5 h plus ≈ 20 min for the repeat.

## 5. Pass / fail

**Per recording.** `audited_clean` when **every** interval of the recording has been reviewed and each is `clean`, `non_rally_activity` or `not_footage` (the latter two recorded as spans for the properties pass) and none is `play_bleeds`; `contaminated` when any interval is `missed_rally`; `partial` when any interval is `unresolved`, `play_bleeds` or **not reviewed** (an aborted session). Whatever the recording's verdict, an interval that is not recorded `clean` in the sidecar stays `UNKNOWN` with weight 0: negatives come from reviewed-clean intervals, never from the recording-level verdict, and never from an interval's length. A `contaminated` recording regains `audited_clean` only after the found rally is marked in the normal marking pass **and** that interval (now split by the new mark) is re-audited.

**Corpus (stage 1).** Let *m* = missed rallies found, *n* = rally marks in the 12 recordings (expected ≈ 190). The estimate *m/n* with its exact binomial upper 90 % bound must be **≤ 5 %** (for *n* = 190 that allows at most *m* = 5), and no single recording may hold more than 2 missed rallies. If the bound holds, the stage 1 recordings' negatives may enter the dataset (subject to §7) and the remaining 22 recordings' negatives may enter **only after** their own audit (stage 2) — the pilot's pass does not clear unaudited recordings, it only tells the owner the corpus is worth auditing rather than re-marking. If the bound fails, the owner is told the corpus's declared coverage is unreliable; the recommendation is then corrective labeling (a marking pass over every unmarked interval of the 34, i.e. stage 2 as a marking job, not an audit) before any negative is used, and the detector packages' dead-time windows (B6 in the plan) are flagged with the measured rate.

**Pass/fail is fixed here, before the draw**, so the result cannot be read to taste.

## 6. Provenance and where the record lives

A new sidecar next to the marks, never written by live tagging or phone sync, written only by a reviewed RallyLab command from the auditor's sheet: `<video>.coverageaudit.json`.

```json
{"annotationVersion": "coverage_audit_v1", "recordingId": "…", "sourceFingerprint": "file:…",
 "marksSha256": "<sha256 of rallylabels.json at audit time>", "drawId": "<stamp>", "drawSha256": "<sha256>",
 "auditor": "<initials or id>", "auditedAt": "2026-11-xxTxx:xxZ", "tool": "RallyLab <git sha>", "blindToPipeline": true,
 "intervals": [{"index": 0, "start": 0.0, "end": 5.2, "verdict": "clean"},
               {"index": 7, "start": 118.4, "end": 131.0, "verdict": "missed_rally", "approxStart": 121.0, "approxEnd": 127.5, "kind": "rally"}],
 "repeat": {"by": "…", "method": "second_reviewer" | "blind_repeat_same_reviewer_24h", "intervals": [...], "agreement": {"clean": "11/12", …}},
 "verdict": "audited_clean" | "contaminated" | "partial"}
```

- `marksSha256` binds the audit to the marks it reviewed: if the sidecar changes (a corrective mark, a re-sync), the audit is stale and the exporter treats coverage as unaudited until a re-audit of the changed intervals is recorded (a stale audit is `partial` with every interval touching the change `UNKNOWN`).
- The ledger gets one row per audited recording, kind `coverage_audit` (a new `ExposureLogRow.Kind`, like `event_review`: a use of the recording by a person, not model exposure), ref `coverage-audit <drawId>`, written by the shared operation after the sidecar is saved; an unwritable ledger fails the save (`CLAUDE.md`: ledgers fail closed).
- Three coverage provenances are then distinguishable and never conflated: `legacy_declared` (the toggle), `declared_audited` (this protocol, `audited_clean`), `stage1_verified` (`stage1Complete` in `rallyevents.json`). Stage 1 supersedes the audit for a recording that has both.

## 7. Consequence for the dataset contract and the preregistration (proposed amendments, owner approval needed — D8)

- Contract `rally_classifier_dataset_v1` recording record gains `coverage.audit: {state: none | audited_clean | contaminated | partial, auditSha256, drawId, cleanIntervals: [{start, end}]}` (`none` when no sidecar); `NON_RALLY` (§5 of the contract) additionally requires that the step lies inside one of `cleanIntervals` (the intervals the sidecar records `clean`, copied by the exporter; the validator checks them against the sidecar's hash) **or** `coverage.state == stage1_complete`; everything outside them is `UNKNOWN` whatever `coverage.audit.state` says — the state is a summary for reporting, the intervals are the rule. The validator gains the field, the rule and a test; the version stays v1 because the change is additive and tightens, never loosens, what counts as a negative (a trainer that accepted v1 without the field accepted fewer negatives, not more) — the owner may prefer to call it `v1.1`.
- Preregistration gate **G7**: "Every recording that supplies `NON_RALLY` steps is `audited_clean` under the coverage-audit protocol (stage 1 bound met, the recording itself audited) or `stage1_complete`; recordings without it contribute positives only". Readiness gate **G6** (≥ 12 groups with negatives) is then counted over audited recordings.
- Reporting: the experiment's data table states, per recording, the coverage provenance (declared / audited / Stage 1) and the audit's findings; the dead-time metrics are null for anything not audited (the scoring contract's `fullyMarked` rule, now with teeth).

## 8. Tooling

| Tool | Status | Where |
|---|---|---|
| `coverage_audit_draw.py` — reads the inventory (§3.1), computes every unmarked interval (edges and sub-second ones included, all to be reviewed), draws stage 1 (4 per surface, one per group, train+tune per surface, exclusions explicit) and the 20 % repeat set with a fixed seed, refuses the withheld closure, writes the frozen draw with hashes; `--all` lists every recording's intervals for stage 2 | **in this PR**, standard library, 15 tests on synthetic inventories; not run on real data | `scripts/rally_classifier/coverage_audit_draw.py`, `scripts/tests/test_coverage_audit_draw.py` |
| Inventory adapter (manifest + sessions + sidecars → inventory JSON) | planned (next assignment) | RallyLab headless or the readiness script |
| `--record-coverage-audit <sheet> [--apply]` — validates the auditor's sheet against the draw, writes the sidecar atomically, the ledger row, refuses withheld names and a stale `marksSha256` | planned (next assignment) | RallyLab |
| Review surface — the existing Live-tag / Rally times view with path snapping off and overlays hidden, navigated by the draw's interval list | existing; no new UI required | RallyLab, Labeler |

## 9. What this protocol does not authorise

No audit is drawn or performed until the owner approves this document and decides D6 (sample) and D8 (amendment). The draw tool is not run on the Scratch project in this PR. No mark is written, moved or deleted by the audit; corrections go through the marking pass. No protected recording is listed, drawn, opened or scored.
