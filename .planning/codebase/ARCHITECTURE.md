# Architecture

**Analysis Date:** 2026-01-24

## Pattern Overview

**Overall:** Feature-based modular architecture with MVVM presentation layer

**Key Characteristics:**
- Feature modules are self-contained with their own views, view models, and components
- Core infrastructure provides shared services (ML, storage, media)
- Single source of truth for data (MediaStore + MetadataStore)
- Observable view models (@Observable) drive SwiftUI views
- File-based storage with JSON manifests (no Core Data or databases)

## Layers

**Presentation (Features/):**
- Purpose: User-facing screens and interactions
- Location: `BumpSetCut/Features/`
- Contains: Views (SwiftUI), ViewModels (@Observable), feature-specific components
- Depends on: Core layer, Services layer, Models layer
- Used by: App entry point (`BumpSetCutApp.swift`)

**Core Infrastructure (Core/):**
- Purpose: Shared foundational services
- Location: `BumpSetCut/Core/`
- Contains: ML detection (`YOLODetector`, `MLService`), media utilities (`FrameExtractor`), storage (`MediaStore`, `MetadataStore`, `FolderManager`), utilities (`QuadraticFit`, `CMTime+Helpers`)
- Depends on: Models layer, system frameworks (CoreML, AVFoundation)
- Used by: Features, Services

**Services (Services/):**
- Purpose: Cross-cutting application services
- Location: `BumpSetCut/Services/`
- Contains: Upload coordination (`UploadCoordinator`, `UploadManager`), analytics (`MetricsCollector`)
- Depends on: Core layer
- Used by: Features (primarily Library and Home)

**Models (Models/):**
- Purpose: Data structures and domain entities
- Location: `BumpSetCut/Models/`
- Contains: `VideoMetadata`, `FolderMetadata`, `ProcessingMetadata`, `Detections`, `ProcessorConfig`
- Depends on: System frameworks only
- Used by: All layers

**Design System (DesignSystem/):**
- Purpose: Reusable UI components and design tokens
- Location: `BumpSetCut/DesignSystem/`
- Contains: Components (buttons, cards, feedback), typography, tokens (spacing, animation)
- Depends on: SwiftUI only
- Used by: Features

## Data Flow

**Video Upload Flow:**

1. User selects videos via PhotosPicker
2. `UploadCoordinator` orchestrates transfer using `VideoTransferable` (file-based, no memory loading)
3. `UploadManager` tracks individual upload items with status states
4. User provides naming and folder selection via popup dialogs
5. Videos copied to persistent storage directory
6. `MediaStore.addVideo()` creates metadata entry and updates manifest
7. `.libraryContentChanged` notification triggers UI refresh

**State Management:**
- View models use `@Observable` (Observation framework)
- `MediaStore` is single source of truth for video/folder metadata
- Manifest saved to JSON after every change
- NotificationCenter broadcasts library changes (`.libraryContentChanged`)

**Video Processing Flow:**

1. User triggers processing from HomeView or RallyPlaybackView
2. `VideoProcessor` reads video frames via AVAssetReader
3. `YOLODetector` detects volleyball in each frame using CoreML
4. `KalmanBallTracker` tracks ball positions across frames
5. `BallisticsGate` validates physics (parabolic motion via `QuadraticFit`)
6. `RallyDecider` (state machine) determines rally start/end with hysteresis
7. `SegmentBuilder` collects rally segments and merges nearby ones
8. `ProcessingMetadata` generated with rally segments, stats, quality metrics
9. `MetadataStore.saveMetadata()` writes JSON to `ProcessedMetadata/` directory
10. `MediaStore` updated with metadata tracking flags

**Rally Playback Flow:**

1. User navigates to Library → select processed video
2. `RallyPlayerViewModel` loads `ProcessingMetadata` from disk
3. For each rally segment, creates looping AVPlayer with trimmed time range
4. TikTok-style vertical swipe navigation between rallies
5. Export uses `VideoExporter` to create standalone rally clips

## Key Abstractions

**MediaStore:**
- Purpose: File-based video and folder management
- Examples: `BumpSetCut/Core/Storage/MediaStore.swift`
- Pattern: Service object with JSON manifest persistence, library-aware operations (`.saved` vs `.processed`)

**VideoMetadata:**
- Purpose: Represents a video file with processing state
- Examples: `BumpSetCut/Core/Storage/MediaStore.swift`
- Pattern: Struct with custom Codable implementation for backwards compatibility, computed properties for state (`canBeProcessed`, `isOriginalVideo`)

**ProcessingMetadata:**
- Purpose: Rally detection results and analytics
- Examples: `BumpSetCut/Models/ProcessingMetadata.swift`
- Pattern: Codable struct hierarchy with optional enhanced data, factory methods for creation

**Observable ViewModels:**
- Purpose: SwiftUI view state and business logic
- Examples: `BumpSetCut/Features/Library/LibraryViewModel.swift`, `BumpSetCut/Features/Home/HomeViewModel.swift`
- Pattern: `@Observable` classes with dependency injection of stores/services, computed properties for derived state

**Processing Pipeline Stages:**
- Purpose: Composable video analysis components
- Examples: `BumpSetCut/Features/Processing/Logic/RallyDecider.swift`, `BumpSetCut/Features/Processing/Logic/BallisticsGate.swift`, `BumpSetCut/Features/Processing/Tracking/KalmanBallTracker.swift`
- Pattern: Stateful classes with `reset()` methods, frame-by-frame `update()` processing, physics-based validation

## Entry Points

**BumpSetCutApp:**
- Location: `BumpSetCut/App/BumpSetCutApp.swift`
- Triggers: App launch
- Responsibilities: SwiftUI app entry, audio session setup, register popups, inject AppSettings

**HomeView:**
- Location: `BumpSetCut/Features/Home/ContentView.swift` (likely, based on `HomeViewModel`)
- Triggers: Initial view after app launch
- Responsibilities: Display stats, navigation to Library/Processing

**VideoProcessor:**
- Location: `BumpSetCut/Features/Processing/VideoProcessor.swift`
- Triggers: User initiates processing from UI
- Responsibilities: Orchestrate detection → tracking → physics → segmentation pipeline, generate metadata

**UploadCoordinator:**
- Location: `BumpSetCut/Services/UploadCoordinator.swift`
- Triggers: PhotosPicker selection or drag-and-drop
- Responsibilities: Coordinate multi-step upload (naming, folder selection, file transfer)

## Error Handling

**Strategy:** Throws-based with optional error logging

**Patterns:**
- Async functions use `throws` for I/O operations (video loading, file copying)
- View models catch and log errors, update state for UI display
- `ProcessingError.exportFailed` for processing failures
- Resource cleanup in `defer` blocks and manual `CMSampleBufferInvalidate()`
- Storage operations return Bool success flags, log warnings on failure

## Cross-Cutting Concerns

**Logging:** Print statements with emoji prefixes, os.Logger in UploadCoordinator
**Validation:** Physics validation via `BallisticsGate` and `ParabolicValidator`, frame-level detection confidence checks
**Authentication:** Not applicable (local-only app)

---

*Architecture analysis: 2026-01-24*
