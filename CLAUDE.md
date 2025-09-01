# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Think carefully and implement the most concise solution that changes as little code as possible.

## USE SUB-AGENTS FOR CONTEXT OPTIMIZATION

### 1. Always use the file-analyzer sub-agent when asked to read files.
The file-analyzer agent is an expert in extracting and summarizing critical information from files, particularly log files and verbose outputs. It provides concise, actionable summaries that preserve essential information while dramatically reducing context usage.

### 2. Always use the code-analyzer sub-agent when asked to search code, analyze code, research bugs, or trace logic flow.
The code-analyzer agent is an expert in code analysis, logic tracing, and vulnerability detection. It provides concise, actionable summaries that preserve essential information while dramatically reducing context usage.

### 3. Always use the test-runner sub-agent to run tests and analyze the test results.
Using the test-runner agent ensures:
- Full test output is captured for debugging
- Main conversation stays clean and focused
- Context usage is optimized
- All issues are properly surfaced
- No approval dialogs interrupt the workflow

## Project Overview

**BumpSetCut** is a SwiftUI iOS app for automatic volleyball rally detection and video processing. It uses computer vision and machine learning to identify and extract active volleyball rallies from recorded videos.

## Development Commands

### Building and Testing
- **Build**: Use Xcode (`⌘+B`) or `xcodebuild -project BumpSetCut.xcodeproj -scheme BumpSetCut build`
- **Run**: Use Xcode (`⌘+R`) or iOS Simulator
- **Tests**: Currently no dedicated test framework - testing is done manually with sample videos

### Project Structure
```
BumpSetCut/
├── App/                    # App entry point and configuration
├── UI/                     # SwiftUI views and components
│   ├── Components/         # Reusable UI components
│   └── View/              # Main screens and views
├── Media/                  # Core video processing pipeline
│   ├── Processor/         # Main VideoProcessor class
│   ├── Logic/             # Rally detection logic
│   ├── Tracking/          # Ball tracking algorithms
│   └── Export/            # Video export functionality
├── Models/                # Data models and storage
└── Archive/               # Deprecated/unused code
```

## Architecture Overview

### Video Processing Pipeline (Core Architecture)
Multi-stage processing chain:
1. **Detection**: `YOLODetector` → CoreML volleyball detection with static object suppression  
2. **Tracking**: `KalmanBallTracker` → Constant-velocity tracking with association gating
3. **Physics Gating**: `BallisticsGate` → Projectile trajectory validation using quadratic fitting
4. **Rally Logic**: `RallyDecider` → Hysteresis-based state machine for rally detection
5. **Segmentation**: `SegmentBuilder` → Time range extraction with padding
6. **Export**: `VideoExporter`/`DebugAnnotator` → Final video generation

### Processing Modes
- **Production**: Trimmed video with only rally segments
- **Debug**: Full-length annotated video showing detection overlays (processes every 3rd frame for performance)

### Key Components
- **VideoProcessor**: Main processing orchestrator with `@Observable` pattern
- **MediaStore**: File-based storage manager for Documents directory
- **ProcessorConfig**: Centralized configuration with physics parameters
- **Third-party**: MijickCamera (capture), MijickPopups (modals), CoreML/Vision (ML)

### UI Architecture
- SwiftUI with `@Observable` pattern (VideoProcessor, MediaStore)
- NavigationStack-based navigation with modal presentations
- Component composition through private extensions
- Consistent system colors and SF Symbols

## Development Guidelines

### Error Handling
- **Fail fast** for critical configuration (missing text model)
- **Log and continue** for optional features (extraction model)
- **Graceful degradation** when external services unavailable
- **User-friendly messages** through resilience layer

### Testing
- Always use the test-runner agent to execute tests
- Do not use mock services for anything ever
- Do not move on to the next test until the current test is complete
- If the test fails, consider checking if the test is structured correctly before deciding we need to refactor the codebase
- Tests to be verbose so we can use them for debugging

### Code Style and Architecture
- **NO PARTIAL IMPLEMENTATION**
- **NO CODE DUPLICATION**: Check existing codebase to reuse functions and constants. Read files before writing new functions.
- **NO DEAD CODE**: Either use or delete from codebase completely
- **IMPLEMENT TEST FOR EVERY FUNCTION**
- **NO INCONSISTENT NAMING**: Read existing codebase naming patterns
- **NO OVER-ENGINEERING**: Don't add unnecessary abstractions when simple functions work
- **NO MIXED CONCERNS**: Proper separation between UI, processing, and storage layers
- **NO RESOURCE LEAKS**: Clean up video processing resources, file handles, and observers

### Key Architecture Notes
- Processing pipeline is modular and extensible
- Configuration system allows easy parameter tuning
- File-based storage without database overhead
- Video processing is CPU/GPU intensive but well-optimized
- Camera integration abstracted through MijickCamera library
- Uses async/await throughout for responsive UI

### Resource Management Considerations
- VideoProcessor creates heavy ML objects - ensure proper cleanup
- Processing can be memory intensive with large videos
- Debug mode annotation requires significant GPU resources
- Consider cancellation handling in long-running processing tasks