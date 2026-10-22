---
name: scoring-implementation-plan
status: plan for owner/Codex review; no code until the L2 export completes
created: 2026-10-22T05:50:00Z
updated: 2026-10-22T05:50:00Z
---

# Implementing the scoring contract in Swift: plan for PRs A, B and C

Source of truth: [SCORING_CONTRACT.md](SCORING_CONTRACT.md) (accepted v1, D-021), the 23 fixtures under `BumpSetCutTests/Fixtures/Scoring/` with their pinned `expected`, and the Python reference `scripts/scoring/reference_scorecard.py`. The Swift scorers must reproduce every pinned number. Nothing below is implemented or built until the running L2 export finishes.

## What exists today (from the 2026-10-22 audit, main at `5739139`)

| Component | File | Role today | Fate |
|---|---|---|---|
| `Interval`, `LabeledRally`, `ScoringConfig`, `ScoringResult`, `RallySegmentationScorer` | `BumpSetCut/Features/Processing/Optimization/RallySegmentationScorer.swift` | greedy IoU matcher on `Double` seconds; `paddingToSubtract` overload; `optimizerScore` | kept for one release behind the new scorer, then removed; `paddingToSubtract` removed in PR A (wrong for short rallies, unused) |
| `RallyCutScore.Tally` / `diagnose` / `report` | `RallyLab/RallyCutScore.swift` | headless `--score-rallies`, scores **padded** clips at IoU 0.3 | PR B: raw boundaries + export scorecard, two tables |
| `PipelineTuner.Score` | `RallyLab/PipelineTuner.swift:197-248` | D-011 objective on padded union | PR B: contract metrics; legacy value kept by name |
| `EvidenceReplayer.decidedRallies` | `RallyLab/EvidenceReplayer.swift` | replays `FrameEvidence` through decider + builder; `padded: false` zeroes padding then merges on raw gaps | PR B uses `padded: true` and takes `.raw` from each `BuiltSegment` (production's finalized raw); PR C fixes the inputs (D-008) |
| `SegmentBuilder.finalizeWithRaw(until:)` → `[BuiltSegment]` (`padded`, `raw` `CMTimeRange`s) | `BumpSetCut/Features/Processing/Logic/SegmentBuilder.swift:82` | production finalization | unchanged; PR A tests it against the fixtures' `decided → raw/padded` |
| `RallyKind`, `RallyMarkRecord {startTime, endTime, kind?, contacts?}` | `Labeler/Shared/RallyEvents.swift` (RallyLab/Labeler targets, **not** the iOS app) | the mark sidecar | PR B decodes marks as `[RallyMarkRecord]` at the five sites that decode `[LabeledRally]` today |

## PR A — `RallyScorecard`: interval library, two scorers, fixture tests (shared target, no behaviour change)

**Files (new, `BumpSetCut/Features/Processing/Scoring/`, listed in RallyLab's `membershipExceptions` like the rest of the shared pipeline):**

- `TickTime.swift` — `typealias Tick = Int` at 600/s; `Tick(seconds:)` rounds to the nearest tick (`Double` → `(x * 600).rounded()`), `seconds(_:)` back; `struct TickInterval { start, end }` half-open with `length`, `overlap`, `iou` as a `Rational`; `struct IntervalSet` (sorted disjoint) with `normalised`, `intersect`, `subtract`, `length`, `covers(instant:duration:)` implementing the §1 convention (`s ≤ t < e`, video-end exception).
- `Rational.swift` — `struct Rational { num, den: Int }` with `<`, `<=`, `==`, `*`; `init(decimal: String)` parsing `"1.3513"` as 13513/10000 exactly (no `Double` anywhere on the comparison path); `ScoringParams { iou, tolerance, complete, detected, split, merged: Rational }` with the contract defaults and `init(decimals:)`.
- `EventTruth.swift` — `struct EventTruth { start, end: Tick; kind: RallyKind?; contact: Tick }` plus `enum TruthKind { rally, missedServe, other }` local to the shared target (the Labeler `RallyKind` is not an app-target type); `kind == nil → .rally`; `contact == nil → start`.
- `RawBoundaryScorer.swift` — `struct RawBoundaryScore: Codable, Equatable` with exactly the fixture keys (`rallies, predictions, unscoredPredictions, tp, fp, fn, precision, recall, f1, startMAE, endMAE, startMedianSigned, endMedianSigned, startWithinTolerance, endWithinTolerance, split, merged, excludedTimeDiagnostics{…}, matches[]`), and `static func score(truth: [EventTruth], raw: [TickInterval], params:) -> RawBoundaryScore` implementing §2: excluded union mask, scorable pieces per prediction (disconnected pieces kept), unscored when empty, greedy matching on masked IoU with the (−iou, truth start, prediction start) tie-break, errors from the scorable span's ends, split/merged on pieces with rational thresholds, conventional median, diagnostics.
- `PaddedExportScorecard.swift` — `struct PaddedExportScore: Codable, Equatable` with the fixture keys (`rallies, clips, complete, clipped, missed, completeRallyRecall?, mergedRallies, rallySeconds, exportSeconds, excludedSecondsDelivered, scorableDeadSecondsDelivered?, deadSeconds?, deadSecondsRetained?, deadTimeRetention?, falseClips?, fullyMarked, perRally[], legacyCoveredMinusQuarterDead?`) and `static func score(truth:, segments: [TickInterval], duration: Tick, params:, fullyMarked: Bool) -> PaddedExportScore` implementing §3: per-rally retention and status with `covers`, `inMergedExport` (segment shared by ≥ 2 truth rallies), false clips per original segment, delivered time split, every dead-time field `nil` unless `fullyMarked == true`, legacy diagnostic.
- `RallyScorecard.swift` — `enum RallyScorecard { static let contract = "SCORING_CONTRACT v1"; static func score(fixture-shaped inputs) -> (raw, export) }` plus the JSON shape used by `evaluation_v2.json` later (PR B); `Double` outputs rounded to 6 decimals like the reference.

**`fullyMarked` is an explicit argument with no default.** A caller must pass the session's `ralliesMarked == true`; the compiler enforces it.

**Tests (`BumpSetCutTests/Domain/Scoring/`):**

- `ScoringContractFixtureTests.swift` — loads every `Fixtures/Scoring/*.json` from the test bundle (`Bundle(for:)`; the synchronized test folder copies non-source files as resources — confirmed by `FrameExtractorTests` loading `test_rally.mp4`; if the subfolder is flattened, load by the `NN_` name prefix), builds `EventTruth`/`TickInterval` inputs, runs both scorers, and compares with `expected`: integers and strings exactly, `Double`s within 1e-6 (the reference rounds to 6 decimals; Swift rounds the same way, and the tolerance guards float-repr ties), `null` ↔ `nil`. One test per fixture, named after the file, so a failure names the case.
- `ProductionFinalizationFixtureTests.swift` — for every fixture, feeds `decided` into a `SegmentBuilder(config: ProcessorConfig())` (defaults: preroll 2.0, postroll 0.5, merge 1.3513, min 2.6131) as closed segments and asserts `finalizeWithRaw(until:)` gives the pinned `raw` and `padded` within 1/600 s. This is the Swift twin of the reference's production-consistency check and the first test of inconsistency #8's premise. If `SegmentBuilder`'s input path cannot be driven from `decided` ranges without the decider, the test drives it through `closeSegment` via `@testable` access.
- `RationalTests.swift` — exact decimal parsing, comparisons at the 810/811-tick boundary, 2/5 split threshold.
- `IntervalSetTests.swift` — union/intersect/subtract, half-open touching, `covers` at `t == end`, `t == duration`.

**Evidence for the PR:** both targets build (shared files); `BumpSetCutTests` 23 fixture tests + unit tests green; `python3 scripts/scoring/reference_scorecard.py BumpSetCutTests/Fixtures/Scoring/*.json` all `matches expected` on the same commit (parity by construction: one JSON, two implementations).

**Not in PR A:** no caller changes, no report format, no replay changes; `RallySegmentationScorer` stays as is (its `paddingToSubtract` overload is deleted as dead and wrong).

## PR B — wire the callers; `evaluation_v2.json`; D-007 objective (RallyLab + shared callers)

1. **Truth loading:** a shared `RallyTruthLoader` (RallyLab) decodes `<video>.rallylabels.json` as `[RallyMarkRecord]` (kind, contacts) at the five sites that decode `[LabeledRally]` today — `RallyCutScore.swift:71`, `PipelineTuner.swift:360`, `TrainingDataExporter.swift:169`, `SamplerModel.swift:462`, `RallyLabModel.swift:808` — and maps to `[EventTruth]` (`kind nil → rally`, `contacts.first(.serve)?.time ?? startTime` as contact). `fullyMarked = session.ralliesMarked == true`, never defaulted.
2. **Raw boundaries = production's finalized raw:** `EvidenceReplayer.decidedRallies(…, padded: true).map(\.raw)`; the `padded: false` path is deleted (inconsistency #8).
3. **`RallyLabModel.recomputeScore`** → `RawBoundaryScorer` for the Pipeline/Compare tabs and the sweep objective (today `optimizerScore`; replaced by complete-rally recall at the padded level with raw F1 shown next to it — the tab shows both tables).
4. **`RallyCutScore` / `--score-rallies`:** two tables per video and pooled — raw-boundary and padded-export — plus the diagnostics; the legacy IoU-0.3 tally and `diagnose`'s 30 % rule are removed; old reports are not rewritten, their semantics are labelled "pre-contract" in `BASELINE.md`.
5. **`evaluation_v2.json`** (`RallyLab/EvaluationReport.swift`): per video (name, split, recording group from the manifest, `fullyMarked`, both scores, diagnostics) and per rally (`perRally` rows + match rows), header with `contract`, `scorerVersion` (git sha), `ProcessorConfig` hash, model id/sha, manifest hashes, and the paired-group bootstrap (95 %, labelled distinct from the trainer's 90 % clip intervals — roadmap Phase 2 §5). Written by the shared function the CLI and the tab both call; refusal of withheld recordings and the `rally_scoring` ledger row stay inside it.
6. **`PipelineTuner`:** objective → complete-rally recall subject to a dead-time-retention ceiling (D-007), `legacyCoveredMinusQuarterDead` reported by name; `enableRallyScoreGate` removed from `rallyKnobs` (D-008, part of PR C's scope but one line here).
7. **`PipelineCompare` and `TrainingDataExporter`:** their truth is the visible-ball span / the raw replay; both are labelled as such in their output headers and are **not** called boundary truth.
8. Tests: `RallyLabTests` for the loader (kind nil, contacts), for `--score-rallies` on a synthetic session (refusal of a withheld name, `fullyMarked` false → null dead-time fields in the JSON), and a snapshot test of `evaluation_v2.json` on one fixture-backed session.

Behaviour change: headless report numbers change (padding no longer counted as error; IoU 0.5); the sweep objective changes. Both are the point of D-007; `BASELINE.md` gets a dated note.

## PR C — replay parity and D-008 (shared pipeline; both targets; physical-iPhone gate)

1. `FrameEvidence` carries what production fed the decider: the `ballY` production used (`activeTrack.positions.last.y ?? courtMidY`), the above-net sample source, and the frame's `isProjectile`; `EvidenceReplayer` consumes those fields instead of recomputing from `trackPoint` (inconsistency #7). Old evidence caches without the fields are replayed with the old inputs and flagged `legacyEvidence: true` in the report.
2. `EvidenceReplayer` drops `enableRallyScoreGate` (production never applies it) — D-008.
3. `ProcessingMetadata.rallySegments` gain `rawStartTime`/`rawEndTime` via `decodeIfPresent` (inconsistency #9), written by `VideoProcessor` from `BuiltSegment.raw`.
4. **Parity test:** one synthetic `FrameEvidence` stream through `VideoProcessor`'s decision path and through `EvidenceReplayer` with identical `ProcessorConfig`; raw and padded segments equal within 1/600 s; tolerance `0.2 s` in the tuner becomes an assertion, not a log line.
5. `minRallySec` default unified to 1.1653 in `RallyLabModel` and the sweep (inconsistency #11).

Gate: shared-pipeline files → `scripts/build.sh both`, unit suites green, and the owner's physical-iPhone check before merge (processing output must be unchanged except for the two added metadata fields).

## Order, sizes, dependencies

| PR | Needs | Size | Blocks |
|---|---|---|---|
| A | export finished (builds + tests) | ~900 lines Swift + tests | B, C's parity test, Phase 1A sensitivity scorer, GUI C6 validation panel |
| B | A merged | ~600 lines | Phase 2 report, D-007 tuning |
| C | A merged; B for the report fields | ~300 lines + iPhone check | Phase 2 pass rule ("scoring a frozen fixture is deterministic and does not change app output") |

Open question for the owner before PR B: the dead-time-retention ceiling for the D-007 objective (the roadmap says "at a fixed dead-time removal level or a recall-vs-dead-time curve"); PR B ships the curve and reports recall at the current operating point unless a level is chosen.
