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
- If a test fails after your changes, use the **preexisting** skill before debugging — ~91 tests fail on a clean tree.

### Testing
Two XCTest targets exist: **BumpSetCutTests** (unit) and **BumpSetCutUITests** (UI).
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
- **Default ball model**: `ball_v2_small.mlpackage` in `Resources/ML/` (yolo26 raw export; fallbacks: bestv3, bestv2). Net model: `net.mlpackage`. Both apps share `YOLODetector()`.
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

## Product Invariants (each cost a real correction round-trip — don't re-learn them)
- Processing produces **metadata only**; never create a copy of the original video. Processed output lives with the original.
- Pipeline philosophy: deterministic rules + FSM + court geometry + ball continuity. NO ML rally classification, NO weighted scoring as the primary mechanism, NO player tracking/pose. Camera is assumed at the endline. Keep physics validation conservative; when touching tracking, sanity-check up/down trajectory direction (historical inversion bug).
- RallyLab and the iOS app are ONE shared pipeline — a tuning/config change in one must be applied to the other.
- Lifetime stats (e.g. "time cut") are cumulative and must survive rally/file deletion — never derive them from file existence.
- Displayed detection confidence = raw YOLO model confidence, never a derived/binary value. Debug overlays must reflect actual algorithm state and be toggleable.
- The user verifies features on a **physical iPhone**, not the simulator — don't build simulator UI-automation flows for manual verification; add temporary tagged debug logging instead and strip it before commit (see the **device-logs** skill for triaging pasted console output).

## Sub-Agent Usage
- Use **code-analyzer** agent for searching code, analyzing bugs, tracing logic
- Use **file-analyzer** agent for reading and summarizing large files
- Use **test-runner** agent to run and analyze tests
