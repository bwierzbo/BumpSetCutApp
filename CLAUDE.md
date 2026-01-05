# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**BumpSetCut** is a SwiftUI iOS app for automatic volleyball rally detection and video processing. It uses CoreML and computer vision to identify and extract active volleyball rallies from recorded videos.

## Development Commands

```bash
# Build
xcodebuild -project BumpSetCut.xcodeproj -scheme BumpSetCut build

# Build for simulator
xcodebuild -project BumpSetCut.xcodeproj -scheme BumpSetCut \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

No test framework currently - testing is done manually with sample videos.

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
│   ├── RallyPlayback/      # TikTok-style rally viewer with swipe navigation
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
- **File**: `bestv2.mlpackage` in `Resources/ML/`
- **Type**: YOLO volleyball detection model
- App functions without model but AI features are disabled

## Sub-Agent Usage
- Use **code-analyzer** agent for searching code, analyzing bugs, tracing logic
- Use **file-analyzer** agent for reading and summarizing large files
- Use **test-runner** agent to run and analyze tests
