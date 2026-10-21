# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**BumpSetCut** is a SwiftUI iOS app for automatic volleyball rally detection and video processing. It uses CoreML and computer vision to identify and extract active volleyball rallies from recorded videos.

## Development Commands

All builds go through the canonical script — do NOT hand-write `xcodebuild build` invocations or hardcode simulator names/UDIDs (they rot when Xcode updates):

```bash
scripts/build.sh            # auto: builds target(s) affected by changed files
scripts/build.sh ios        # BumpSetCut on a live iPhone simulator
scripts/build.sh mac        # RallyLab (macOS)
scripts/build.sh both       # both targets
scripts/build.sh mac --run  # build RallyLab and relaunch the app
scripts/build.sh doctor     # print the resolved simulator UDID

# Run unit + UI tests (resolve destination first)
UDID=$(scripts/build.sh doctor | sed -n 's/^simulator: //p')
xcodebuild test -project BumpSetCut.xcodeproj -scheme BumpSetCut \
  -destination "platform=iOS Simulator,id=$UDID"

# Lint (requires swiftlint installed: brew install swiftlint)
swiftlint
```

Build rules:
- **Dual-target rule**: BumpSetCut (iOS) and RallyLab (macOS) share the processing pipeline (files listed in RallyLab's `membershipExceptions` in project.pbxproj). Any change to a shared file must build BOTH targets before being declared done — `scripts/build.sh auto` handles this. A shared-file change once silently broke RallyLab for days.
- `unable to attach DB` build errors mean the Xcode GUI holds the build database — the script retries once; after that ask the user to stop the Xcode build. Don't spam retries.
- Ignore SourceKit/IDE diagnostics completely ("Cannot find X in scope" after edits is noise) — never mention them; only build output counts.
- Don't rebuild targets untouched by the change.
- The unit suite is green (377/377 on 2026-10-04) — a failing test is most likely yours; confirm with the **preexisting** skill before debugging.

### Testing
Three XCTest targets exist: **BumpSetCutTests** (unit), **BumpSetCutUITests** (UI) and **RallyLabTests** (unit, macOS, hosted in RallyLab.app — run with `xcodebuild test -project BumpSetCut.xcodeproj -scheme RallyLab -destination 'platform=macOS'`; covers project/session decoding, the dataset split manifest and the leakage audit).
Strongest coverage is the processing/CV domain (Kalman, ballistics, parabolic,
rally decider, segment builder) and storage/models. Networking, uploads, and most
view models are under-tested — use the existing `StubAPIClient` to add VM tests.
Manual testing with sample videos still covers the end-to-end processing pipeline.

## Architecture

### Project Structure (Feature-Based)
```
BumpSetCut/
├── App/                    # App entry point and settings
├── Core/                   # Shared infrastructure
│   ├── ML/                 # YOLODetector, MLService (CoreML integration)
│   ├── Media/              # FrameExtractor (AVFoundation utilities)
│   ├── Storage/            # MediaStore, FolderManager, MetadataStore
│   └── Utilities/          # QuadraticFit, CMTime helpers
├── Features/               # Feature modules
│   ├── Library/            # Video library, folders, search, upload
│   ├── Processing/         # Video processing pipeline
│   │   ├── Logic/          # RallyDecider, BallisticsGate, SegmentBuilder
│   │   ├── Tracking/       # KalmanBallTracker
│   │   ├── Classification/ # MovementClassifier
│   │   └── Physics/        # ParabolicValidator
│   ├── RallyPlayback/      # Full-screen rally viewer with swipe navigation
│   ├── Export/             # VideoExporter, DebugAnnotator
│   ├── Settings/           # App settings
│   └── Onboarding/         # First-launch tutorial
├── DesignSystem/           # Reusable UI components and tokens
├── Services/               # UploadCoordinator, UploadManager, MetricsCollector
├── Models/                 # Core data models (Detections, ProcessingMetadata)
└── Extensions/             # Swift extensions
```

### Video Processing Pipeline
```
YOLODetector → KalmanBallTracker → BallisticsGate → RallyDecider → SegmentBuilder → VideoExporter
     ↓              ↓                    ↓               ↓
  CoreML       Kalman filter      Physics validation   State machine
  detection    tracking           (quadratic fit)      (hysteresis)
```

### Key Patterns
- **MediaStore**: File-based storage with manifest JSON, posts `.libraryContentChanged` notification on changes
- **VideoMetadata**: Tracks `isProcessed`, `originalVideoId`, `processedVideoIds` for processing relationships
- **URL-based uploads**: Videos stay on disk during upload (no Data loading into memory)
- **Orientation-aware video**: Uses `.fit` in portrait, `.fill` in landscape

## Code Guidelines

### Absolute Rules
- NO partial implementation or placeholder code
- NO code duplication - check existing codebase first
- NO dead code - delete unused code completely
- NO resource leaks - clean up video processing resources, file handles, observers

### Architecture
- Features are self-contained modules with their own views, view models, and components
- Core/ contains shared infrastructure used across features
- Services/ for cross-cutting concerns (uploads, metrics)
- MediaStore is the single source of truth for video state

### SwiftUI Patterns
- Use `@Observable` for view models
- Use `GeometryReader` for responsive layouts
- Use computed properties for reactive state (not stored state)
- Use `decodeIfPresent` for backwards-compatible Codable fields

### Memory Management
- Never load entire videos as `Data` - use URL-based file operations
- Use `VideoTransferable` for PhotosPicker imports
- Clean up AVPlayer instances in `onDisappear`

## CoreML Model
- **Processing default is multi-frame only** (`BallFinder.current` → `.multiFrameOnly`): the bundled `ball_heat.mlpackage` (9-frame heatmap, `HeatmapBallDetector`) finds the ball. `YOLODetector()` (default `ball_v2_small.mlpackage`; fallbacks bestv3, bestv2; net model `net.mlpackage`) remains for the debug picker and RallyLab pre-labeling.
- **Licensing (decision 2026-10-09):** every YOLO/Ultralytics-derived `.mlpackage` (ball_v2_small, bestv2, bestv3, ball_rallylab_*, net) must leave the public iOS bundle before launch. RallyLab and the internal Labeler build may keep them. Flag any change that would ship Ultralytics-derived weights.
- App functions without model but AI features are disabled
- **New models must be**: (1) added to `Resources/ML/`, (2) added to RallyLab's `membershipExceptions` in project.pbxproj, (3) **committed to git in the same commit that references them** — a pbxproj reference to an uncommitted mlpackage builds locally but breaks Xcode Cloud. Large blobs may need `git config http.postBuffer 524288000` to push.

## CI (Xcode Cloud)
- `Secrets.swift` is gitignored; `ci_scripts/ci_post_clone.sh` regenerates it from `SUPABASE_URL`/`SUPABASE_ANON_KEY` env vars set in the Xcode Cloud workflow. Any new local-only file the build depends on needs the same treatment, or CI archive breaks with "Cannot find X in scope" while local builds pass.

## Supabase Migrations
After ANY DDL applied to the live project (`apply_migration`/`execute_sql`):
1. Commit the SQL as a numbered migration file in the same commit/PR as the app code that uses it — prod DB ahead of unmerged code is a known standing risk; don't widen it.
2. Verify the app's RPC call matches the function signature exactly (parameter names AND optionality) — omitting a defaulted param causes "Could not find the function ... in the schema cache" at runtime.
3. Storage uploads with `upsert: true` need an UPDATE policy on the bucket, not just INSERT.
4. Re-run `get_advisors` (security + performance). Explicit grants survive default-privilege revokes — re-check `anon` execute grants after hardening.

## Development Workflow (decisions D-005 and D-014, 2026-10-20)
- Work goes on a scoped feature branch. **Never push to `main` and never merge without explicit owner authorisation.** Pushing intermediate commits to the feature branch is fine.
- Two tiers; the owner decides which applies. **PR with independent review (default)** for ML models, datasets/labels/splits, training pipelines, evaluation methodology, architecture, the shared processing pipeline and significant production behaviour: open the PR with the template filled in (`gh pr create … --body-file`, not `--fill`), Codex reviews it, blocking findings are fixed or explicitly accepted by the owner, the owner merges. **Streamlined** only when the owner explicitly authorises it for that change (minor UI, cosmetic, doc corrections, low-risk fixes).
- Full cycle, tiers, evidence requirements and review hand-off: `docs/workflow/WORKING_AGREEMENT.md`, `docs/workflow/CHATGPT_REVIEW.md`, `.github/PULL_REQUEST_TEMPLATE.md`. Codex's own instructions: `AGENTS.md`.
- Decisions live in `docs/decisions/DECISION_LOG.md`; experiments, datasets and model versions are linked through `docs/ml-roadmap/EXPERIMENT_REGISTRY.md`. Documentation index: `docs/README.md`. Update these as part of the change they describe, in the same PR.

## Product Invariants (each cost a real correction round-trip — don't re-learn them)
- Processing produces **metadata only**; never create a copy of the original video. Processed output lives with the original.
- Pipeline: multi-frame heatmap ball detector → tracker → physics/court-geometry gates → rally decision → segment builder. The deterministic FSM (`RallyDecider`) is the **benchmark and fallback**; a **learned temporal rally classifier over detector/tracker features is an approved production candidate** (decision D-001, 2026-10-20; supersedes the former "no ML rally classification" rule). Production adoption requires independent validation evidence on unseen recordings. Still out of scope: end-to-end video→rally models, player tracking/pose. Camera is assumed at the endline. Keep physics validation conservative; when touching tracking, sanity-check up/down trajectory direction (historical inversion bug).
- RallyLab and the iOS app are ONE shared pipeline — a tuning/config change in one must be applied to the other.
- Lifetime stats (e.g. "time cut") are cumulative and must survive rally/file deletion — never derive them from file existence.
- Displayed detection confidence = the raw model confidence (YOLO score or heatmap peak), never a derived/binary value. Calibrated or gating scores need distinct names. Debug overlays must reflect actual algorithm state and be toggleable.
- **Reserved or excluded data (D-002).** An exclusion is only real if every consumer honours it. Before a PR that adds or changes one, grep for every place that runs a model or the pipeline on a session (`sampler.sessions`, `RallyCutScore.process`, `PipelineCompare.run`, `VideoProcessor`, `HeatmapLab`, `PreTracker`, `ModelLibrary.evaluate`, the RallyLab Pipeline/Compare/Models tabs) and list them in the PR with how each one refuses.
- **Ledgers fail closed.** A record of use (exposure log, split manifest) is written at the moment of use, by the shared function, not by the CLI or GUI wrapper. A missing ledger means empty; an unreadable or unwritable one aborts the operation. Nothing that renames or moves an identity may drop a row. Never write `0` or empty for a value that could not be read.
- **Guards live in the shared function.** When a CLI command and a GUI tab call the same operation, the refusal and the logging go in the operation itself, so a new caller cannot bypass them.
- The user verifies features on a **physical iPhone**, not the simulator — don't build simulator UI-automation flows for manual verification; add temporary tagged debug logging instead and strip it before commit (see the **device-logs** skill for triaging pasted console output).

## Sub-Agent Usage
- Use **code-analyzer** agent for searching code, analyzing bugs, tracing logic
- Use **file-analyzer** agent for reading and summarizing large files
- Use **test-runner** agent to run and analyze tests
