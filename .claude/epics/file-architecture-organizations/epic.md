---
name: file-architecture-organizations
status: backlog
created: 2025-09-01T15:42:11Z
progress: 0%
prd: .claude/prds/file-architecture-organizations.md
github: https://github.com/bwierzbo/BumpSetCutApp/issues/3
---

# Epic: File Architecture Organization

## Overview

Reorganize BumpSetCut's file structure using a simple layer-based approach to improve code navigation and maintainability. This is a straightforward file reorganization that establishes clearer module boundaries while maintaining all existing functionality and performance.

## Architecture Decisions

### Core Architecture Pattern
- **Layer-Based Directories**: Four main directories for logical separation
- **Minimal Code Changes**: Keep existing classes and logic intact
- **Clear File Placement**: Obvious location for any piece of functionality

### Technology Choices
- **No New Dependencies**: Use existing Swift/SwiftUI patterns
- **Existing Stack**: Maintain all current integrations (CoreML, AVFoundation, MijickCamera)
- **File Movement Only**: Focus on organization, not rewriting code

### Design Patterns
- **Keep Current Patterns**: Maintain existing @Observable, dependency patterns
- **Logical Grouping**: Group related files together for easier navigation

## Technical Approach

### New Directory Structure
```
BumpSetCut/
├── Presentation/          # UI layer - SwiftUI views and components
│   ├── Views/            # Main screens (ContentView, ProcessVideoView, etc.)
│   ├── Components/       # Reusable UI (ActionButton, StoredVideo)
│   └── Popups/          # Modal presentations
├── Domain/               # Business logic - core app functionality  
│   ├── Services/         # Main services (VideoProcessor)
│   ├── Logic/           # Algorithms (RallyDecider, BallisticsGate)
│   └── Tracking/        # Object tracking (KalmanBallTracker)
├── Data/                 # Models and storage
│   ├── Models/          # Data structures (MediaStore, DetectionResult)
│   └── Storage/         # File management and persistence
└── Infrastructure/       # Framework integrations and external dependencies
    ├── ML/              # CoreML, Vision integrations
    ├── Camera/          # MijickCamera integration
    └── System/          # AVFoundation, file system access
```

### File Movement Plan

#### What Goes Where
- **Current `UI/` → `Presentation/`**: Direct move, same structure
- **Current `Media/Processor/` → `Domain/Services/`**: VideoProcessor and main orchestration
- **Current `Media/Logic/` → `Domain/Logic/`**: RallyDecider, BallisticsGate, SegmentBuilder
- **Current `Media/Tracking/` → `Domain/Tracking/`**: KalmanBallTracker and tracking logic
- **Current `Models/` → `Data/Models/`**: MediaStore, configuration classes
- **Framework integrations → `Infrastructure/`**: CoreML, AVFoundation wrappers
- **Current `Extensions/` → Keep as-is**: Cross-cutting utilities remain at top level

## Implementation Strategy

### Simple 3-Phase Approach
1. **Create New Directory Structure**: Set up empty directories and move files
2. **Fix Import Statements**: Update all import paths to new locations
3. **Test & Validate**: Ensure app builds and functions identically

### Risk Mitigation
- **Git Branch**: Work on feature branch for easy rollback
- **Incremental Commits**: Commit after each directory move
- **Build Validation**: Ensure app builds after each major move

### Testing Approach
- **Build Testing**: App compiles successfully after reorganization
- **Smoke Testing**: Core functionality (video processing, camera) still works
- **No Logic Changes**: Since we're only moving files, existing behavior is preserved

## Task Breakdown Preview

Simple task categories for implementation:

- [ ] **Directory Setup**: Create new layer-based directory structure
- [ ] **Move Presentation Files**: Relocate UI components and views to Presentation layer
- [ ] **Move Domain Files**: Relocate processing logic to Domain layer
- [ ] **Move Data Files**: Relocate models and storage to Data layer  
- [ ] **Create Infrastructure Layer**: Move framework integrations to Infrastructure layer
- [ ] **Fix Import Statements**: Update all file imports to new paths
- [ ] **Build & Test**: Validate app builds and functions correctly

## Dependencies

### External Dependencies
- **Xcode**: Current development environment (no version upgrade required)

### Internal Dependencies
- **Working Codebase**: All current features functioning properly before reorganization

### Prerequisite Work
- **Git Backup**: Create backup branch before starting reorganization

## Success Criteria (Technical)

### Primary Success Metrics
- **App Builds Successfully**: No compilation errors after reorganization
- **Functionality Preserved**: All existing features work identically
- **Code Navigation**: Easier to locate files based on layer-based organization
- **Import Statements**: All imports updated correctly to new file paths

### Quality Gates
- **Build Success**: App compiles and runs on device/simulator
- **Smoke Testing**: Camera, processing, and library functionality work
- **File Organization**: 100% of files moved to appropriate layer directories

## Estimated Effort

### Overall Timeline
**3-5 days total** for file reorganization and testing

### Resource Requirements
- **1 iOS Developer**: Part-time effort, can be done alongside other work
- **No External Dependencies**: Simple file moves and import updates

### Task Timeline
- **Day 1**: Create directory structure and move files
- **Day 2-3**: Update all import statements
- **Day 4-5**: Build testing and validation

### Risk Buffers
- **Minimal Risk**: File movement only, no logic changes
- **Easy Rollback**: Git branch allows immediate rollback if needed
- **Incremental Validation**: Test build after each major file group move

This simplified approach focuses on practical file organization improvements without over-engineering, providing immediate developer experience benefits while maintaining all existing functionality.

## Tasks Created
- [ ] #10 - Build Testing and Validation (parallel: false)
- [ ] #4 - Create Layer-Based Directory Structure (parallel: false)
- [ ] #5 - Move Presentation Layer Files (parallel: true)
- [ ] #6 - Move Domain Layer Files (parallel: true)
- [ ] #7 - Move Data Layer Files (parallel: true)
- [ ] #8 - Create Infrastructure Layer (parallel: true)
- [ ] #9 - Fix All Import Statements (parallel: false)

Total tasks:        7
Parallel tasks:        4
Sequential tasks: 3
