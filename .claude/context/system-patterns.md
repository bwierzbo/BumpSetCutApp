---
created: 2025-09-01T15:19:09Z
last_updated: 2025-09-01T15:19:09Z
version: 1.0
author: Claude Code PM System
---

# System Patterns

## Architectural Patterns

### Observable State Management
**Pattern:** SwiftUI @Observable pattern for reactive state management
```swift
@Observable class VideoProcessor {
    var isProcessing: Bool = false
    var progress: Double = 0.0
    // UI automatically updates when properties change
}
```

**Usage:**
- `VideoProcessor`: Main processing state and progress tracking
- `MediaStore`: File management and video library state
- **Benefits**: Automatic UI updates, clean separation of state and view logic

### Pipeline Architecture
**Pattern:** Multi-stage processing pipeline with clear data flow
```
Input → Detection → Tracking → Physics → Logic → Export → Output
```

**Implementation:**
- Each stage is self-contained with defined inputs/outputs
- Configurable parameters through centralized config
- Easy to add/remove/modify stages
- **Benefits**: Modularity, testability, maintainability

### Dependency Injection Pattern
**Pattern:** Configuration and dependencies passed to processing components
```swift
class VideoProcessor {
    private let config: ProcessorConfig
    private let detector: YOLODetector
    private let tracker: KalmanBallTracker
    // Dependencies injected via initializer
}
```

**Benefits:**
- Testability through mock injection
- Configuration flexibility
- Loose coupling between components

## Data Flow Patterns

### Unidirectional Data Flow
**Pattern:** Data flows in one direction through the processing pipeline
```
UI Action → State Change → Processing → Result → UI Update
```

**Implementation:**
- User initiates processing via UI
- State changes trigger processing
- Results update observable state
- UI reflects new state automatically

### Event-Driven Processing
**Pattern:** Processing stages communicate via discrete events/results
```swift
struct DetectionResult {
    let boundingBox: CGRect
    let confidence: Float
    let timestamp: CMTime
}
```

**Benefits:**
- Clear interfaces between stages
- Easy to log and debug
- Temporal reasoning capabilities

## State Management Patterns

### State Machine Pattern
**Pattern:** Rally detection uses explicit state machine with hysteresis
```swift
enum RallyState {
    case inactive, building, active, decaying
}
```

**Implementation:**
- Prevents flickering between states
- Evidence-based state transitions
- Configurable thresholds for transitions
- **Benefits**: Robust decision making, predictable behavior

### Configuration Pattern
**Pattern:** Centralized configuration object for all processing parameters
```swift
struct ProcessorConfig {
    let detectionThreshold: Float
    let trackingParameters: KalmanParams
    let physicsConstants: PhysicsConfig
}
```

**Benefits:**
- Easy parameter tuning
- Consistent configuration across components
- Version control of parameter sets

## Error Handling Patterns

### Graceful Degradation
**Pattern:** System continues operating with reduced functionality on errors
```swift
// If extraction model fails, continue without it
if extractionModel == nil {
    logger.warning("Extraction model unavailable, continuing with basic processing")
    // Process without extraction features
}
```

### Fail-Fast Pattern
**Pattern:** Critical errors stop processing immediately
```swift
guard let textModel = loadTextModel() else {
    throw ProcessingError.criticalModelMissing("Text model required")
}
```

**Usage:**
- Critical components (core ML models)
- Invalid input validation
- Resource availability checks

### Error Recovery Pattern
**Pattern:** Automatic cleanup and resource recovery on failures
```swift
defer {
    // Cleanup resources even if processing fails
    cleanupProcessingResources()
}
```

## UI Patterns

### Modal Workflow Pattern
**Pattern:** Complex workflows use modal presentations
```swift
.sheet(isPresented: $showProcessing) {
    ProcessVideoView(videoURL: selectedVideo)
}
```

**Usage:**
- Video processing interface
- Camera capture workflow
- **Benefits**: Clear workflow boundaries, focused user experience

### Compositional UI Pattern
**Pattern:** UI built from small, reusable components
```swift
struct ActionButton: View {
    // Reusable button with consistent styling
}

struct StoredVideo: View {
    // Reusable video thumbnail component
}
```

**Benefits:**
- Consistent visual design
- Easy to modify and maintain
- Testable in isolation

## Processing Patterns

### Builder Pattern
**Pattern:** Complex objects built through incremental construction
```swift
class SegmentBuilder {
    func addDetection(_ detection: DetectionResult)
    func build() -> VideoSegment
}
```

**Usage:**
- Video segment construction
- Track building from detections
- **Benefits**: Step-by-step construction, validation at each step

### Observer Pattern (Custom)
**Pattern:** Processing stages observe and react to upstream results
```swift
class RallyDecider {
    func processTrackingResult(_ result: TrackingResult) {
        // React to tracking updates
        updateRallyState(based: result)
    }
}
```

### Strategy Pattern
**Pattern:** Different processing strategies for different modes
```swift
protocol ProcessingStrategy {
    func process(video: AVAsset) -> ProcessingResult
}

class ProductionStrategy: ProcessingStrategy { /* full processing */ }
class DebugStrategy: ProcessingStrategy { /* with visualization */ }
```

**Implementation:**
- Production vs Debug processing modes
- Different export formats
- **Benefits**: Mode-specific optimizations, clean separation

## Memory Management Patterns

### RAII (Resource Acquisition Is Initialization)
**Pattern:** Resources tied to object lifetime with automatic cleanup
```swift
class VideoProcessor {
    private var resources: [ProcessingResource] = []
    
    deinit {
        resources.forEach { $0.cleanup() }
    }
}
```

### Lazy Initialization
**Pattern:** Expensive resources created only when needed
```swift
lazy var heavyMLModel: MLModel = {
    return loadExpensiveModel()
}()
```

**Benefits:**
- Reduced startup time
- Memory efficiency
- Responsive app launch

## Concurrency Patterns

### Async/Await Pattern
**Pattern:** Modern Swift concurrency for video processing
```swift
@MainActor
func processVideo() async throws {
    for frame in videoFrames {
        let detection = await detector.detect(frame)
        // Process on background, update UI on main
    }
}
```

**Benefits:**
- Responsive UI during processing
- Clean error handling
- Structured concurrency

### Task Cancellation Pattern
**Pattern:** Graceful cancellation of long-running operations
```swift
func processVideo() async throws {
    for frame in videoFrames {
        try Task.checkCancellation()
        // Process frame...
    }
}
```

**Usage:**
- User cancellation of processing
- App backgrounding scenarios
- **Benefits**: Resource cleanup, responsive cancellation

## File Management Patterns

### Document-Based Storage
**Pattern:** Simple file-based storage in Documents directory
```swift
class MediaStore {
    private let documentsURL: URL
    
    func save(video: AVAsset, as filename: String) throws {
        // Direct file operations, no database
    }
}
```

**Benefits:**
- Simple backup/sync
- No database complexity
- Direct file access for video playback

**Trade-offs:**
- No complex queries
- Manual file management
- Suitable for this use case (video files)

## Integration Patterns

### Adapter Pattern
**Pattern:** Third-party libraries wrapped with consistent interfaces
```swift
// MijickCamera wrapped with app-specific interface
struct CameraCapture {
    func startRecording() { /* MijickCamera integration */ }
}
```

**Benefits:**
- Consistent API across app
- Easy to swap implementations
- Centralized third-party dependencies