# Codebase Structure

**Analysis Date:** 2026-01-24

## Directory Layout

```
BumpSetCut/
├── BumpSetCut/              # Main app target
│   ├── App/                 # App entry point and settings
│   ├── Core/                # Shared infrastructure
│   │   ├── ML/              # CoreML detection
│   │   ├── Media/           # AVFoundation utilities
│   │   ├── Storage/         # File-based storage
│   │   └── Utilities/       # Helpers (CMTime, QuadraticFit)
│   ├── Features/            # Feature modules
│   │   ├── Library/         # Video library with folders
│   │   ├── Processing/      # Video processing pipeline
│   │   ├── RallyPlayback/   # Rally viewer
│   │   ├── Export/          # Video export utilities
│   │   ├── Settings/        # App settings
│   │   ├── Home/            # Home dashboard
│   │   ├── Record/          # Video recording (legacy?)
│   │   └── Onboarding/      # First launch tutorial
│   ├── DesignSystem/        # UI components and tokens
│   │   ├── Components/      # Reusable UI elements
│   │   ├── Typography/      # Font modifiers
│   │   └── Tokens/          # Design constants
│   ├── Services/            # Cross-cutting services
│   ├── Models/              # Data models
│   ├── Extensions/          # Swift extensions
│   ├── Resources/           # Assets and ML models
│   │   └── ML/              # CoreML model packages
│   └── Assets/              # Images and colors
└── BumpSetCutTests/         # Test target
    ├── Domain/              # Business logic tests
    ├── Data/                # Storage tests
    ├── Presentation/        # ViewModel tests
    ├── Infrastructure/      # Core utilities tests
    └── Integration/         # Integration tests
```

## Directory Purposes

**App/:**
- Purpose: Application entry point and global settings
- Contains: `BumpSetCutApp.swift` (main app), `AppSettings.swift`, `AppDelegate`
- Key files: `BumpSetCut/App/BumpSetCutApp.swift`, `BumpSetCut/App/AppSettings.swift`

**Core/:**
- Purpose: Shared infrastructure used across features
- Contains: ML detection (`YOLODetector.swift`, `MLService.swift`), media utilities (`FrameExtractor.swift`), storage (`MediaStore.swift`, `MetadataStore.swift`, `FolderManager.swift`), utilities
- Key files: `BumpSetCut/Core/Storage/MediaStore.swift`, `BumpSetCut/Core/ML/YOLODetector.swift`, `BumpSetCut/Core/Media/FrameExtractor.swift`

**Features/:**
- Purpose: Self-contained feature modules
- Contains: Feature-specific views, view models, components, and logic
- Key files: `BumpSetCut/Features/Library/LibraryViewModel.swift`, `BumpSetCut/Features/Processing/VideoProcessor.swift`, `BumpSetCut/Features/RallyPlayback/RallyPlayerViewModel.swift`

**Features/Processing/:**
- Purpose: Video processing pipeline
- Contains: Logic (`RallyDecider.swift`, `BallisticsGate.swift`, `SegmentBuilder.swift`), tracking (`KalmanBallTracker.swift`), physics (`ParabolicValidator.swift`), classification (`MovementClassifier.swift`), debug (`TrajectoryDebugger.swift`)
- Key files: `BumpSetCut/Features/Processing/VideoProcessor.swift`, `BumpSetCut/Features/Processing/Logic/RallyDecider.swift`

**Features/Library/:**
- Purpose: Video library and folder management
- Contains: `LibraryViewModel.swift`, upload UI, search functionality, folder/video components
- Key files: `BumpSetCut/Features/Library/LibraryViewModel.swift`, `BumpSetCut/Features/Library/Upload/UploadProgressPopup.swift`

**Features/RallyPlayback/:**
- Purpose: TikTok-style rally viewer
- Contains: Player view model, player components, export functionality, caching services
- Key files: `BumpSetCut/Features/RallyPlayback/RallyPlayerViewModel.swift`, `BumpSetCut/Features/RallyPlayback/Services/RallyPlayerCache.swift`

**DesignSystem/:**
- Purpose: Reusable UI components and design tokens
- Contains: Components (buttons, cards, navigation, feedback), typography modifiers, tokens (spacing, animation)
- Key files: `BumpSetCut/DesignSystem/Components/Cards/BSCFolderCard.swift`, `BumpSetCut/DesignSystem/Tokens/SpacingTokens.swift`

**Services/:**
- Purpose: Cross-cutting application services
- Contains: Upload coordination, metrics collection
- Key files: `BumpSetCut/Services/UploadCoordinator.swift`, `BumpSetCut/Services/UploadManager.swift`, `BumpSetCut/Services/MetricsCollector.swift`

**Models/:**
- Purpose: Core data models
- Contains: `Detections.swift`, `ProcessingMetadata.swift`, `FolderOperation.swift`
- Key files: `BumpSetCut/Models/ProcessingMetadata.swift`, `BumpSetCut/Models/Detections.swift`

**Resources/ML/:**
- Purpose: CoreML model packages
- Contains: `bestv2.mlpackage` (YOLO volleyball detection model)
- Key files: `BumpSetCut/Resources/ML/bestv2.mlpackage/`

**BumpSetCutTests/:**
- Purpose: Test target with organized test structure
- Contains: Domain tests (business logic), data tests (storage), presentation tests (view models), infrastructure tests (utilities), integration tests
- Key files: `BumpSetCutTests/Data/Storage/MediaStoreSearchTests.swift`, `BumpSetCutTests/Domain/Logic/BallisticsGateEnhancedTests.swift`

## Key File Locations

**Entry Points:**
- `BumpSetCut/App/BumpSetCutApp.swift`: SwiftUI app entry point
- `BumpSetCut/Features/Home/ContentView.swift`: Main home view
- `BumpSetCut/Features/Processing/VideoProcessor.swift`: Processing pipeline entry

**Configuration:**
- `BumpSetCut/App/AppSettings.swift`: User settings (thorough/quick analysis mode)
- `BumpSetCut/Models/ProcessingMetadata.swift`: ProcessorConfig embedded as ProcessingConfiguration

**Core Logic:**
- `BumpSetCut/Core/Storage/MediaStore.swift`: Video/folder storage and manifest management
- `BumpSetCut/Core/Storage/MetadataStore.swift`: Processing metadata persistence
- `BumpSetCut/Core/ML/YOLODetector.swift`: CoreML volleyball detection
- `BumpSetCut/Features/Processing/VideoProcessor.swift`: Video processing orchestration
- `BumpSetCut/Features/Processing/Logic/RallyDecider.swift`: Rally state machine with hysteresis
- `BumpSetCut/Features/Processing/Tracking/KalmanBallTracker.swift`: Ball position tracking

**Testing:**
- `BumpSetCutTests/Data/Storage/MediaStoreSearchTests.swift`: MediaStore search tests
- `BumpSetCutTests/Domain/Logic/BallisticsGateEnhancedTests.swift`: Physics validation tests
- `BumpSetCutTests/Integration/LibraryIntegrationTests.swift`: Library integration tests

## Naming Conventions

**Files:**
- PascalCase for Swift files: `MediaStore.swift`, `VideoProcessor.swift`
- Feature components include context: `BSCFolderCard.swift`, `RallyVideoPlayer.swift`
- View models end with `ViewModel`: `LibraryViewModel.swift`, `HomeViewModel.swift`
- Extensions use `++` or `+Helpers`: `AVURLAsset++.swift`, `CMTime+Helpers.swift`

**Directories:**
- PascalCase for features and modules: `RallyPlayback/`, `DesignSystem/`
- Lowercase for subdirectories grouping related files: `logic/`, `tracking/`, `physics/`

**Types:**
- Classes/Structs: PascalCase (`MediaStore`, `VideoMetadata`, `RallyDecider`)
- Properties/Variables: camelCase (`currentPath`, `isProcessing`, `uploadManager`)
- Enums: PascalCase with lowercase cases (`LibraryType.saved`, `MovementType.airborne`)

## Where to Add New Code

**New Feature:**
- Primary code: `BumpSetCut/Features/{FeatureName}/`
- Create subfolder with: `{FeatureName}View.swift`, `{FeatureName}ViewModel.swift`, `Components/` subdirectory
- Tests: `BumpSetCutTests/Presentation/Views/{FeatureName}ViewTests.swift`

**New UI Component:**
- Implementation: `BumpSetCut/DesignSystem/Components/{Category}/{ComponentName}.swift`
- Categories: Buttons, Cards, Navigation, Feedback, Inputs

**New Processing Algorithm:**
- Implementation: `BumpSetCut/Features/Processing/{Logic|Tracking|Physics|Classification}/{AlgorithmName}.swift`
- Tests: `BumpSetCutTests/Domain/{Logic|Physics|Classification}/{AlgorithmName}Tests.swift`

**New Storage Feature:**
- Implementation: `BumpSetCut/Core/Storage/{FeatureName}.swift`
- Tests: `BumpSetCutTests/Data/Storage/{FeatureName}Tests.swift`

**Utilities/Extensions:**
- Shared helpers: `BumpSetCut/Core/Utilities/{UtilityName}.swift`
- Swift extensions: `BumpSetCut/Extensions/{Type}+{Purpose}.swift`

**New Service:**
- Implementation: `BumpSetCut/Services/{ServiceName}.swift`
- Tests: `BumpSetCutTests/Domain/Services/{ServiceName}Tests.swift`

**Data Models:**
- Implementation: `BumpSetCut/Models/{ModelName}.swift`
- Tests: `BumpSetCutTests/Data/Models/{ModelName}Tests.swift`

## Special Directories

**Resources/ML/:**
- Purpose: CoreML model packages
- Generated: No (manually added ML models)
- Committed: Yes (bestv2.mlpackage is tracked)

**Assets/:**
- Purpose: Xcode asset catalogs for images and colors
- Generated: Managed by Xcode
- Committed: Yes

**BumpSetCut.xcodeproj/:**
- Purpose: Xcode project configuration
- Generated: Managed by Xcode
- Committed: Yes (project.pbxproj)

**.planning/codebase/:**
- Purpose: Codebase documentation generated by GSD mapping
- Generated: Yes (by /gsd:map-codebase)
- Committed: Should be committed for team reference

**ProcessedMetadata/ (runtime):**
- Purpose: JSON metadata files for processed videos
- Generated: Yes (by MetadataStore at runtime)
- Committed: No (runtime data in Application Support directory)
- Location: `~/Library/Application Support/BumpSetCut/ProcessedMetadata/`

**.debug_data/ (runtime):**
- Purpose: Debug trajectory data from processing
- Generated: Yes (by TrajectoryDebugger when enabled)
- Committed: No (runtime debug data)
- Location: `~/Library/Application Support/BumpSetCut/.debug_data/`

---

*Structure analysis: 2026-01-24*
