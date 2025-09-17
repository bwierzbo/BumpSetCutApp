---
created: 2025-09-15T17:59:47Z
last_updated: 2025-09-16T05:23:42Z
version: 1.2
author: Claude Code PM System
---

# Project Structure

## Root Directory Organization

```
BumpSetCut/
├── .claude/                    # Claude Code PM configuration and epics
├── .git/                       # Git version control
├── BumpSetCut/                # Main iOS app source code (Clean Architecture)
├── BumpSetCut.xcodeproj/      # Xcode project configuration
├── BumpSetCutTests/           # Test suite with comprehensive coverage
├── build/                     # Build artifacts
├── CLAUDE.md                  # Development guidelines and patterns
├── INTEGRATION_TEST_REPORT.md # Testing documentation
├── SWIPEABLE_RALLY_INTEGRATION.md # Rally player integration documentation
└── MetadataVideoProcessing_PRD.md # Recent PRD documentation
```

## Clean Layer Architecture (`BumpSetCut/`)

### Presentation Layer - User Interface
```
BumpSetCut/Presentation/
├── Views/                            # Main application screens
│   ├── ContentView.swift             # Root navigation with camera integration
│   ├── LibraryView.swift             # Video library with folder management
│   ├── ProcessVideoView.swift        # Video processing interface
│   ├── VideoPlayerView.swift         # Video playback component
│   ├── RallyPlayerView.swift         # Legacy rally-by-rally navigation
│   ├── TikTokRallyPlayerView.swift   # TikTok-style rally player with swipe navigation
│   ├── SwipeableRallyPlayerView.swift # Alternative swipeable rally player
│   ├── SettingsView.swift            # App settings and configuration
│   └── RallyPlayerFactory.swift     # Factory for creating appropriate rally player
├── Components/                       # Reusable UI components
│   ├── Folder/                       # Folder organization components
│   ├── Search/                       # Search and filtering components
│   ├── Shared/                       # Common UI elements
│   ├── Upload/                       # Upload and drag-drop components
│   ├── Video/                        # Video management components
│   ├── Stored Video/
│   │   └── StoredVideo.swift         # Video thumbnail/preview component
│   └── MetadataOverlayView.swift     # Metadata visualization overlay
└── Examples/                         # UI pattern examples and samples
```

### Domain Layer - Business Logic
```
BumpSetCut/Domain/
├── Services/                         # Core application services
│   ├── VideoProcessor.swift         # Main processing orchestrator (@Observable)
│   ├── VideoExporter.swift          # Production video creation
│   ├── UploadCoordinator.swift      # File upload management
│   ├── UploadManager.swift          # Upload process handling
│   └── MetricsCollector.swift       # Performance and analytics
├── Logic/                           # Core algorithmic components
│   ├── BallisticsGate.swift         # Physics-based trajectory validation
│   ├── RallyDecider.swift           # Hysteresis-based rally state machine
│   └── SegmentBuilder.swift         # Time-based video segmentation
├── Classification/                   # Movement and behavior analysis
│   ├── MovementClassifier.swift     # Ball state classification
│   └── MovementType.swift           # Movement type definitions
├── Physics/                         # Physics modeling and validation
│   └── ParabolicValidator.swift     # Trajectory physics validation
├── Quality/                         # Quality assessment systems
│   └── TrajectoryQualityScore.swift # Trajectory scoring algorithms
├── Optimization/                    # Parameter tuning systems
│   └── ParameterOptimizer.swift     # Automated parameter optimization
└── Debug/                           # Development and debugging tools
    ├── DebugDataModels.swift        # Debug data structures
    └── TrajectoryDebugger.swift     # Trajectory debugging utilities
```

### Data Layer - Models and Storage
```
BumpSetCut/Data/
├── Models/                          # Core data structures
│   ├── Detections.swift             # Computer vision detection results
│   ├── ProcessingMetadata.swift     # Video processing metadata
│   ├── FolderOperation.swift        # Folder management operations
│   └── ProcessorConfig.swift        # Processing configuration
├── Storage/                         # Data persistence and management
│   ├── MediaStore.swift             # File storage and organization
│   ├── FolderManager.swift          # Folder operations and hierarchy
│   └── VideoProcessingTracking.swift # Processing state tracking
└── Extensions/                      # Data-specific extensions
    └── Task++.swift                 # Async/await utilities
```

### Infrastructure Layer - External Integrations
```
BumpSetCut/Infrastructure/
├── App/                             # Application configuration
│   ├── BumpSetCutApp.swift          # Main app entry point
│   └── AppSettings.swift            # App-wide configuration and feature toggles
├── ML/                              # Machine learning services
│   ├── YOLODetector.swift           # CoreML volleyball detection
│   └── MLService.swift              # ML model management
├── Camera/                          # Camera system integration
│   └── CameraService.swift          # MijickCamera abstraction
├── Math/                            # Mathematical utilities
│   └── QuadraticFit.swift           # Curve fitting algorithms
└── System/                          # System-level utilities
    ├── CMTime+Helpers.swift         # Time manipulation utilities
    └── AVURLAsset++.swift           # Video asset extensions
```

### Resources and Assets
```
BumpSetCut/Resources/
└── ML/                              # CoreML model files
    ├── best.mlpackage               # Original YOLO volleyball model
    └── bestv2.mlpackage             # Enhanced volleyball detection model
```

## Test Suite Structure (`BumpSetCutTests/`)

```
BumpSetCutTests/
├── Data/                            # Data layer testing
│   ├── Models/
│   │   └── ProcessorConfigTests.swift
│   └── Storage/
│       └── VideoProcessingTrackingTests.swift
├── Domain/                          # Business logic testing
│   ├── Classification/
│   │   └── MovementClassifierTests.swift
│   ├── Debug/
│   │   └── TrajectoryDebuggerTests.swift
│   ├── Logic/
│   │   └── BallisticsGateEnhancedTests.swift
│   └── Physics/
│       └── ParabolicValidatorTests.swift
└── Integration/                     # End-to-end testing
    └── DebugPerformanceTests.swift
```

## File Organization Patterns

### Naming Conventions
- **Swift Files**: PascalCase matching class/struct names (`VideoProcessor.swift`)
- **Directories**: Descriptive names organized by purpose (`Classification/`, `Physics/`)
- **Components**: Self-contained in dedicated folders with clear responsibility
- **Extensions**: Original type name + `++` for core extensions (`Task++.swift`)
- **Test Files**: Original name + `Tests` suffix (`MovementClassifierTests.swift`)

### Clean Architecture Dependency Flow
```
Presentation Layer (SwiftUI Views, Components)
    ↓ (Dependencies flow downward only)
Domain Layer (Services, Logic, Classification, Physics)
    ↓
Data Layer (Models, Storage) ← Infrastructure Layer (ML, Camera, System)
```

### Layer Responsibility Guidelines
- **Presentation**: SwiftUI views, UI components, navigation, user interaction
- **Domain**: Business logic, video processing, rally detection, physics validation
- **Data**: Models, storage management, file operations, configuration
- **Infrastructure**: External integrations (CoreML, camera, system frameworks)

## Configuration and Development Files

### Xcode Project Configuration
- **BumpSetCut.xcodeproj/**: iOS project with 4-layer architecture target structure
- **Info.plist**: App metadata, camera permissions, file handling capabilities
- **Workspace Data**: User-specific IDE settings and build configurations

### Development Guidelines and Documentation
- **CLAUDE.md**: Comprehensive development guidelines and architectural patterns
- **.claude/**: Claude Code project management with epic tracking and PRDs
- **INTEGRATION_TEST_REPORT.md**: Testing documentation and validation reports
- **MetadataVideoProcessing_PRD.md**: Product requirements for metadata features

### Version Control and Build
- **.git/**: Git repository with GitHub remote (https://github.com/bwierzbo/BumpSetCutApp.git)
- **build/**: Xcode build artifacts and derived data

## Third-Party Dependencies and Integration

### Core Dependencies
- **MijickCamera**: Modern SwiftUI camera capture framework
- **CoreML/Vision**: Apple's machine learning and computer vision frameworks
- **AVFoundation**: Video processing, playback, and media asset management
- **SwiftUI**: Declarative UI framework with @Observable state management

### Integration Architecture
- **Camera System**: Abstracted through CameraService wrapper over MijickCamera
- **Machine Learning**: CoreML models dynamically loaded with fallback handling
- **File Management**: Direct filesystem operations in app Documents directory
- **State Management**: Reactive @Observable pattern throughout UI hierarchy

## Architectural Characteristics

### Scalability and Maintainability
- **Clean Layer Separation**: Enforced dependency direction prevents circular dependencies
- **Modular Processing Pipeline**: Easy addition of new detection/tracking algorithms
- **Configuration-Driven Logic**: Parameters externalized for runtime tuning
- **Test Coverage**: Comprehensive unit and integration testing for critical components

### Performance and Resource Management
- **File-Based Storage**: No database overhead, simple backup and synchronization
- **Memory Management**: Proper cleanup of video processing resources and ML models
- **Async Processing**: Non-blocking video processing with progress tracking
- **Responsive UI**: @Observable state updates maintain UI responsiveness during processing

### Development and Deployment
- **Single Xcode Workspace**: Unified development environment
- **Source Control**: Git workflow with feature branch development
- **Testing Strategy**: Manual testing with real video samples plus automated unit tests
- **iOS Distribution**: Standard App Store deployment process