---
name: scoring-contract
status: proposed (contract v1 for owner/Codex review; Swift implementation and tests follow after the L2 export)
created: 2026-10-22T02:30:00Z
updated: 2026-10-22T02:30:00Z
---

# Rally scoring contract v1: raw boundaries vs padded export

Phase 2 of the roadmap ([ROADMAP_REVISED_2026-10-20.md §Phase 2](ROADMAP_REVISED_2026-10-20.md)) and decisions D-007 (complete-rally recall primary, the 0.25 score a named diagnostic) and D-008 (reconcile replay with production). This page is the **contract**: exact definitions, what the code does today and where it disagrees, and the deterministic fixtures that pin the contract. The Swift implementation is a separate PR once the running L2 export releases the RallyLab binary.

The one rule everything else follows (roadmap §"Critical scoring rule"): **raw decider boundaries are scored against event truth; padded export clips are scored against what the viewer gets. Never mix them.**

## 1. Inputs and time base

| Input | Definition |
|---|---|
| Event truth | the recording's rally marks: `startTime` = first serve **contact**, `endTime` = ball dead, `kind ∈ {rally, missedServe, other}`; `contacts[0]` (kind serve) is the contact when present, else `startTime`. Only `kind == rally` are truth rallies. `missedServe` and `other` are **excluded spans**. A mark with `kind == nil` (pre-live-tag) is `rally` for now and gets `legacy_unverified` provenance under Phase 1A. |
| Raw boundaries | `SegmentBuilder`'s `raw` ranges after merge and minimum-length filtering: the decider's rally start (serve-primed when seen) to its rally end, **no preroll/postroll**. Note the merge is decided on *padded* gaps (`finalizeWithRaw`), so two rallies whose padded clips touch become **one raw range**; the raw scorer then reports a merged prediction, which is the correct account of what production decided |
| Padded export | the `padded` ranges the app actually exports (`VideoProcessor.rallySegments`): preroll 2.0 s (0.5 s when the raw rally is under 2.5 s), postroll 0.5 s, clamped to `[0, duration]`, merged when gaps ≤ 1.3513 s, dropped under 2.6131 s |
| Duration `T` | the video's duration |
| Time base | integer ticks at **600/s** (the pipeline's CMTime timescale). Doubles from marks and metadata are rounded to the nearest tick on load. Intervals are **half-open** `[start, end)`. Containment of a point is inclusive at both ends (the end tick is the last frame shown). |
| Tie-break | greedy matching by descending IoU; ties by earlier truth start, then earlier prediction start |

Per-rally trim adjustments and flywheel padding are **not** scored (they are user edits after export).

## 2. Raw-boundary scorer (event quality)

Inputs: truth rallies, excluded spans, raw boundaries, `iou` (default 0.5), `tolerance` (default 1.0 s), `split` 0.25, `merged` 0.5.

- A prediction that overlaps an excluded span at all is **unscored** (neither hit nor false): the decider fired on something a person marked as not a rally. Counted as `unscoredPredictions`.
- Matching: one-to-one, greedy by descending temporal IoU, accepted when IoU ≥ `iou`. `tp`, `fp` (unmatched scored predictions), `fn` (unmatched rallies); precision, recall, F1.
- Boundary errors on matched pairs only, **signed** (`prediction − truth`): `startMAE`, `endMAE`, `startMedianSigned`, `endMedianSigned` (conventional median: the mean of the two middle values for an even count), `startWithinTolerance`, `endWithinTolerance` (fraction with |error| ≤ `tolerance`). A serve-primed start that sits at the toss shows as a negative start error; that is a finding, not a padding artefact.
- `split`: rallies overlapped by ≥ 2 predictions each covering ≥ 25 % of the rally. `merged`: predictions overlapping ≥ 2 rallies each by ≥ 50 % of that rally. Both fractional (today one is fractional and one is 0.5 s absolute).

## 3. Padded-export scorecard (delivered quality)

Inputs: truth rallies, excluded spans, padded clips, `T`, `complete` 0.98, `detected` 0.5.

Let `G` = union of rally intervals, `P` = union of padded clips, `X` = union of excluded spans, scorable time `S = [0, T) ∖ X`, dead time `D = S ∖ G`.

- Per rally: `retainedFraction = |rally ∩ P| / |rally|`; `contactInExport`, `deadBallInExport` (point containment in `P`); status **complete** when retained ≥ 0.98 **and** both events are inside the export, **clipped** when retained ≥ 0.5 but not complete, **missed** otherwise. (0.98 is the roadmap's starting proposal, to be reviewed, not a product standard.)
- `completeRallyRecall = complete / rallies` (null when there are no rallies).
- `deadTimeRetention = |P ∩ D| / |D|` (null when `|D| = 0`); `deadSecondsRetained`, `deadSeconds`, `rallySeconds`, `exportSeconds`.
- `falseClips`: clips of `P` with no overlap with `G` **and** no overlap with `X`.
- `legacyCoveredMinusQuarterDead` = `|G ∩ P| / |G| − 0.25 · |P ∖ G| / |G|`: the D-011 tuner objective on the same inputs, kept under its own name as the historical diagnostic (D-007). Note it counts time inside `X` as dead; the contract metrics do not.

The two scorers share one interval library (union, intersection, subtraction on ticks). No frame counting.

## 4. What the code does today, and where it disagrees (from the 2026-10-22 review)

| # | Finding | Where |
|---|---|---|
| 1 | **Padded clips scored as if they were boundaries.** Every headless report (`--score-rallies`, `--diagnose-rallies`, the tuner, the serve report's clip scores, PipelineCompare) feeds *padded* `rallySegments` to a boundary scorer; the Pipeline/Compare tabs and the sweep feed *raw* ranges. With default padding every rally ≥ 2.5 s carries a 2.0 s start and 0.5 s end "error" before any model error; the IoU threshold was lowered to 0.3 to compensate. | `RallyCutScore.swift:41,77,86,119`; `RallyLabModel.swift:1131-1133`; `PipelineTuner.swift:250-253`; `PipelineCompare.swift:76` |
| 2 | **Five definitions of "found/missed"**: IoU ≥ 0.3 match; unmatched-with-zero-overlap miss; `diagnose`'s > 30 % overlap FOUND; the tuner's ≥ 50 % coverage; PipelineCompare's ≥ 50 % against the *visible-ball span*, not marks. | `RallyCutScore.swift:40-46,102`; `PipelineTuner.swift:216`; `PipelineCompare.swift:97-105` |
| 3 | `split` measured in seconds (0.5 s absolute), `merged` as a fraction of the rally. | `RallyCutScore.swift:45-46` |
| 4 | **Rally kinds ignored**: `missedServe` and `other` marks are decoded as rallies by every scorer; `contacts` never used; production dates a rally at the serve *toss* (up to 1.5 s before contact) while truth is the contact. | `RallyCutScore.swift:70-71`; `PipelineTuner.swift:360`; `TrainingDataExporter.swift:199`; `RallyLabModel.swift:1149`; `RallyDecider.swift:89,154`; `ServeDetector.swift:86` |
| 5 | **D-007 not implemented**: no complete-rally recall, no dead-time retention anywhere; the tuner still optimises `covered − 0.25·dead`. | `PipelineTuner.swift:197-248` |
| 6 | **D-008 not implemented**: `EvidenceReplayer` still applies `enableRallyScoreGate`, production never does; the tuner still searches it. | `EvidenceReplayer.swift:81-94`; `PipelineTuner.swift:85-86` |
| 7 | **Replay ≠ production inputs**: production feeds the decider the raw track `y` (fallback court mid-y), replay the smoothed `trackPoint.y` (nil without a track); above-net sampling differs likewise; the 0.2 s replay-vs-production tolerance is logged, not enforced. | `VideoProcessor.swift:755,765,770-772,1037`; `EvidenceReplayer.swift:47-51,64-65,105-109`; `PipelineTuner.swift:430-433` |
| 8 | **Raw replay ≠ raw of a padded replay**: with `padded: false` the replayer zeroes padding and then merges on *raw* gaps, so merge decisions differ from production's merge on padded gaps. | `EvidenceReplayer.swift:47-51`; `SegmentBuilder.swift:105` |
| 9 | **Raw boundaries are not persisted** in the app's metadata (only padded segments and the preroll/postroll config), so raw cannot be recovered exactly from an iOS run. | `VideoProcessor.swift:1046,1157-1159`; `ProcessingMetadata.swift:170-171,262-281` |
| 10 | `paddingToSubtract` overload subtracts constant padding — wrong for short rallies (0.5 s cap) and clamped starts. Unused. | `RallySegmentationScorer.swift:91-105` |
| 11 | `minRallySec` default 3.0 in the UI model and the sweep fallback vs 1.1653 in decider, tuner and trainer. | `RallyLabModel.swift:382,487,1216`; `RallyDecider.swift:48` |
| 12 | `RallyCutScore.report`'s "today" row replays with `ProcessorConfig()` rather than the run's camera/heat config; unchecked claim of equality. | `RallyCutScore.swift:132-133`; `HeadlessProjects.swift:315-338` |
| 13 | **No test covers any scorer**: `RallySegmentationScorer`, `RallyCutScore.Tally`, `PipelineTuner.Score`, `EvidenceReplayer`, `ServeReport` have zero tests. | grep over `BumpSetCutTests`, `RallyLabTests` |

## 5. Fixtures (deterministic, pinned)

`BumpSetCutTests/Fixtures/Scoring/*.json`: twelve cases, each with `truth`, `raw`, `padded`, `duration`, optional `params`, and an `expected` scorecard written by the reference implementation `scripts/scoring/reference_scorecard.py` (pure Python, integer ticks, no dependencies). The Swift scorers must reproduce `expected` exactly; the reference is the independent computation the Phase 2 pass rule asks for.

| Fixture | What it pins |
|---|---|
| 01 exact raw, padded export `[10,14]` / `[8,14.5]` | the roadmap parity case: 0 raw error, export complete, 2.5 s dead retained |
| 02 short rally | 0.5 s preroll cap; complete |
| 03 two rallies 1.0 s apart | production merges on *padded* gaps and unions the raw ranges → raw is one range `[10,19]`: fn 2, fp 1, merged 1 (the merge itself loses the boundary; inconsistency #8 is about replay doing it differently); export: one clip, both complete, not a false clip |
| 04 split rally | raw: both pieces below IoU 0.5 → fn 1, fp 2, split 1; export: retained 0.95 → clipped |
| 05 false clip | raw fp 1; export falseClips 1; dead retained grows |
| 06 zero truth | recall null, everything false, retention over the full video |
| 07 edges | clamping at 0 and at `T`; both complete |
| 08 missedServe + other | excluded spans: predictions touching them unscored, no false clips, denominator shrinks |
| 09 toss-primed start | −1.2 s start error, outside 1.0 s tolerance; export complete |
| 10 custom tolerance | 0.5 s tolerance; errors inside it |
| 11 touching rallies | half-open intervals; production merges the touching ranges → raw `[10,18]`, whose IoU with each 4 s rally is exactly 0.5: the tie-break matches the earlier rally (tp 1, end error +4.0 s), fn 1, fp 0, merged 1; one clip covers both completely |
| 12 one prediction over two rallies | raw: merged 1, fn 2, fp 1; export: both complete |

Still to add once the Swift side exists (they need `FrameEvidence`, not intervals): replay-vs-production equality of raw and padded within 1/600 s on one synthetic evidence stream; the D-008 gate removal; non-integer frame times; a video with no marks at all (no `ralliesMarked`) must refuse dead-time metrics rather than report 0.

## 6. Implementation plan (separate PRs, after the export)

1. **PR A — interval library + two scorers + fixtures as tests** (BumpSetCutTests, shared target): `RallyScorecard` with `rawBoundary(...)` and `paddedExport(...)` over tick intervals; load each fixture, assert equality with `expected`. No production behaviour change.
2. **PR B — wire the callers**: `RallyLabModel` (raw) and `RallyCutScore`/`--score-rallies` (raw **and** export scorecard, two tables), `PipelineTuner` objective → constrained complete-rally recall with the legacy score reported by name (D-007), `TrainingDataExporter` and `PipelineCompare` label their truth explicitly (visible-ball span ≠ event truth). `evaluation_v2.json` per video/rally with scorer version, config and model hashes. Old reports are not rewritten; their semantics are labelled "pre-contract".
3. **PR C — replay parity (D-008)**: remove the gate from the replayer and the tuner's search space; feed the replayer the same `ballY`/above-net inputs as production (persist what production saw in `FrameEvidence` if needed); persist raw boundaries in `ProcessingMetadata` (backward-compatible `decodeIfPresent`); parity test on a synthetic evidence stream within 1/600 s. Touches the shared pipeline → both targets build, physical-iPhone check before merge.
4. Kinds and provenance in truth loading wait for Phase 1A's label schema (`source_method`, `review_state`, uncertainty) — the scorer takes `kind` now and ignores unknown fields.
