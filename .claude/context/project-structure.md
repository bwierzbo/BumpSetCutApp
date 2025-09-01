---
created: 2025-09-01T15:19:09Z
last_updated: 2025-09-01T15:19:09Z
version: 1.0
author: Claude Code PM System
---

# Project Structure

## Root Directory Organization

```
BumpSetCut/
├── .claude/                    # Claude Code PM configuration
├── .git/                       # Git version control
├── BumpSetCut/                # Main iOS app source code
├── BumpSetCut.xcodeproj/      # Xcode project configuration
├── ccpm/                      # [DEPRECATED] Old project management files
└── CLAUDE.md                  # Development guidelines
```

## iOS App Structure (`BumpSetCut/`)

### Core Application Components

```
BumpSetCut/
├── App/
│   └── BumpSetCutApp.swift           # Main app entry point, orientation handling
├── UI/                               # User interface components
│   ├── Components/                   # Reusable UI elements
│   │   ├── Action Button/
│   │   │   └── ActionButton.swift    # Custom button component
│   │   └── Stored Video/
│   │       └── StoredVideo.swift     # Video thumbnail/preview component
│   └── View/                         # Main application screens
│       ├── ContentView.swift         # Root navigation view
│       ├── LibraryView.swift         # Video library interface
│       ├── ProcessVideoView.swift    # Video processing interface
│       ├── VideoPlayerView.swift     # Video playback component
│       └── Popups/
│           └── CaptureViewPopup.swift # Camera capture modal
├── Models/
│   └── MediaStore.swift              # File storage and management
└── Archive/
    └── CustomCameraScreen.swift      # Legacy camera implementation
```

### Video Processing Pipeline (`BumpSetCut/Media/`)

```
Media/
├── Processor/
│   └── VideoProcessor.swift          # Main processing orchestrator (@Observable)
├── Logic/                            # Core algorithmic components
│   ├── BallisticsGate.swift         # Physics-based trajectory validation
│   ├── RallyDecider.swift           # Hysteresis-based rally state machine
│   └── SegmentBuilder.swift         # Time-based video segmentation
├── Tracking/                         # Object tracking implementations
│   └── KalmanBallTracker.swift      # Ball trajectory tracking
├── Export/                           # Video output generation
│   ├── VideoExporter.swift          # Production video creation
│   └── DebugAnnotator.swift         # Debug visualization overlay
├── Detection/                        # Computer vision components
│   └── YOLODetector.swift           # CoreML volleyball detection
└── Utils/                           # Supporting utilities
    └── Types/
        └── Detections.swift         # Data structures for CV results
```

### Extensions and Utilities (`BumpSetCut/Extensions/`)

```
Extensions/
├── AVURLAsset++.swift               # Video asset utilities
├── Font+MFontModifier.swift         # Typography extensions
├── MFontModifier.swift              # Custom font styling
├── Task++.swift                     # Async/await utilities
└── View+MFontModifier.swift         # SwiftUI view extensions
```

## File Organization Patterns

### Naming Conventions
- **Swift Files**: PascalCase matching class/struct names
- **Directories**: Descriptive names with spaces where appropriate
- **Components**: Self-contained in dedicated folders
- **Extensions**: Original type name + `++` or `+ExtensionPurpose`

### Module Organization
- **UI Layer**: SwiftUI views and components, no business logic
- **Media Layer**: Core video processing, completely UI-independent  
- **Models Layer**: Data structures and file management
- **Extensions**: Cross-cutting utilities and convenience methods

### Dependency Flow
```
UI Layer (SwiftUI Views)
    ↓
Models Layer (MediaStore, Data Types)
    ↓
Media Layer (VideoProcessor, Detection, Tracking)
    ↓ 
Extensions (Utilities)
```

## Configuration Files

### Xcode Project
- **BumpSetCut.xcodeproj/**: Standard iOS project structure
- **Info.plist**: App metadata, permissions, capabilities
- **Workspace Data**: User-specific IDE settings

### Development Setup
- **CLAUDE.md**: Development guidelines and architecture documentation
- **.claude/**: Claude Code project management configuration
- **.git/**: Version control with GitHub remote

## Third-Party Integration Points

### Dependencies (Inferred from code)
- **MijickCamera**: Camera capture functionality
- **MijickPopups**: Modal presentation system  
- **CoreML/Vision**: Machine learning and computer vision
- **AVFoundation**: Video processing and playback

### Integration Patterns
- **Camera**: Abstracted through MijickCamera library
- **Machine Learning**: CoreML models loaded at runtime
- **File System**: Direct file operations via Documents directory
- **UI Framework**: Pure SwiftUI with @Observable state management

## Architecture Notes

### Scalability Considerations
- **Modular Pipeline**: Easy to add new processing stages
- **Configuration-Driven**: Parameters externalized for tuning
- **File-Based Storage**: No database complexity, simple backup/sync
- **State Management**: Centralized through @Observable classes

### Development Workflow
- **Single Xcode Project**: All code in unified workspace
- **Source Control**: Git with GitHub integration
- **Testing**: Manual testing with sample videos (no formal test suite)
- **Deployment**: Standard iOS app distribution