---
created: 2025-09-01T15:19:09Z
last_updated: 2025-09-01T15:19:09Z
version: 1.0
author: Claude Code PM System
---

# Project Style Guide

## Swift Code Style

### Naming Conventions

**Classes and Structs**: PascalCase
```swift
class VideoProcessor { }
struct DetectionResult { }
protocol ProcessingStrategy { }
```

**Properties and Functions**: camelCase  
```swift
var isProcessing: Bool
func processVideo() async throws
private let detectionThreshold: Float
```

**Constants**: camelCase with descriptive names
```swift
private let maxTrackingDistance: CGFloat = 100.0
private let defaultConfidenceThreshold: Float = 0.5
```

**Enums**: PascalCase with camelCase cases
```swift
enum RallyState {
    case inactive, building, active, decaying
}

enum ProcessingError: Error {
    case modelLoadFailed(String)
    case invalidVideoFormat
}
```

### File Organization Patterns

**File Naming**: Match primary class/struct name exactly
- `VideoProcessor.swift` contains `class VideoProcessor`
- `DetectionResult.swift` contains `struct DetectionResult`  
- Extensions: `AVURLAsset++.swift` for extensions to existing types

**Directory Structure**: Logical grouping by functionality
```
BumpSetCut/
├── App/                    # Application lifecycle and configuration
├── UI/                     # User interface components and views
│   ├── Components/         # Reusable UI elements
│   └── View/              # Main application screens
├── Media/                  # Core video processing pipeline
│   ├── Processor/         # Main processing orchestration
│   ├── Logic/             # Algorithmic components
│   ├── Tracking/          # Object tracking implementations
│   └── Export/            # Video output generation
├── Models/                # Data structures and file management
├── Extensions/            # Utility extensions to existing types
└── Archive/               # Deprecated code (temporary storage)
```

**Import Organization**: Standard library first, then third-party, then internal
```swift
import SwiftUI
import AVFoundation
import CoreML

import MijickCamera
import MijickPopups

import MediaProcessor
```

### Code Organization Within Files

**Class Structure**:
```swift
class VideoProcessor: ObservableObject {
    // MARK: - Public Properties
    @Published var isProcessing: Bool = false
    
    // MARK: - Private Properties  
    private let config: ProcessorConfig
    private let detector: YOLODetector
    
    // MARK: - Initialization
    init(config: ProcessorConfig) {
        self.config = config
        self.detector = YOLODetector(config: config.detectionConfig)
    }
    
    // MARK: - Public Methods
    func processVideo(_ url: URL) async throws {
        // Implementation
    }
    
    // MARK: - Private Methods
    private func setupProcessingPipeline() {
        // Implementation  
    }
}
```

**Extension Organization**: Group related functionality
```swift
// MARK: - ProcessingDelegate
extension VideoProcessor: ProcessingDelegate {
    func didCompleteProcessing(_ result: ProcessingResult) {
        // Implementation
    }
}

// MARK: - Configuration
extension VideoProcessor {
    func updateConfiguration(_ newConfig: ProcessorConfig) {
        // Implementation
    }
}
```

## SwiftUI Style Patterns

### View Structure
```swift
struct ProcessVideoView: View {
    // MARK: - Properties
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0.0
    
    // MARK: - Body
    var body: some View {
        NavigationStack {
            VStack {
                // Content
            }
            .navigationTitle("Process Video")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Private Views
private extension ProcessVideoView {
    var progressIndicator: some View {
        ProgressView(value: progress)
            .progressViewStyle(.linear)
    }
}
```

### State Management Patterns
```swift
// Use @Observable for shared state
@Observable
class MediaStore {
    var videos: [StoredVideo] = []
    var isLoading: Bool = false
}

// Inject dependencies through environment
struct ContentView: View {
    @Environment(MediaStore.self) private var mediaStore
    
    var body: some View {
        // Use injected dependencies
    }
}
```

## Architecture Patterns

### Dependency Injection
```swift
// Protocol-based dependencies
protocol VideoDetector {
    func detectObjects(in frame: CVPixelBuffer) async throws -> [Detection]
}

// Concrete implementation
class YOLODetector: VideoDetector {
    private let model: MLModel
    
    init(model: MLModel) {
        self.model = model
    }
}

// Dependency injection in initializer
class VideoProcessor {
    private let detector: VideoDetector
    
    init(detector: VideoDetector) {
        self.detector = detector
    }
}
```

### Error Handling Patterns
```swift
// Custom error types with context
enum ProcessingError: LocalizedError {
    case modelLoadFailed(String)
    case invalidVideoFormat(URL)
    case processingCancelled
    
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let reason):
            return "Failed to load ML model: \(reason)"
        case .invalidVideoFormat(let url):
            return "Unsupported video format: \(url.lastPathComponent)"
        case .processingCancelled:
            return "Video processing was cancelled"
        }
    }
}

// Graceful error handling with user feedback
func processVideo() async {
    do {
        try await performProcessing()
    } catch ProcessingError.modelLoadFailed(let reason) {
        showError("Unable to load AI model. Please restart the app.")
        logger.error("Model load failed: \(reason)")
    } catch {
        showError("An unexpected error occurred. Please try again.")
        logger.error("Processing failed: \(error)")
    }
}
```

### Configuration Management
```swift
// Centralized configuration with sensible defaults
struct ProcessorConfig {
    let detectionThreshold: Float
    let trackingParameters: TrackingConfig
    let physicsConstants: PhysicsConfig
    
    static let `default` = ProcessorConfig(
        detectionThreshold: 0.5,
        trackingParameters: .default,
        physicsConstants: .volleyball
    )
}

// Environment-based configuration injection
struct ProcessVideoView: View {
    @Environment(\.processorConfig) private var config
    
    var body: some View {
        // Use injected configuration
    }
}
```

## Documentation Standards

### Function Documentation
```swift
/// Processes a video to extract volleyball rally segments.
/// 
/// This method analyzes the input video frame-by-frame to identify
/// volleyball rallies using computer vision and physics-based validation.
/// 
/// - Parameter videoURL: URL of the video file to process
/// - Parameter mode: Processing mode (production or debug)
/// - Returns: Array of rally segments with timestamps
/// - Throws: `ProcessingError` if video cannot be processed
func processVideo(
    at videoURL: URL, 
    mode: ProcessingMode = .production
) async throws -> [RallySegment]
```

### Complex Algorithm Documentation  
```swift
/// Validates ball trajectory using physics-based constraints.
///
/// Uses projectile motion equations to verify that detected ball
/// positions follow realistic parabolic trajectories under gravity.
/// Trajectories that violate physics laws are rejected as false positives.
///
/// Algorithm:
/// 1. Fit quadratic curve to last N ball positions
/// 2. Compare fitted curve to expected projectile motion
/// 3. Calculate deviation from physics model
/// 4. Accept/reject based on deviation threshold
private func validateTrajectoryPhysics(_ positions: [BallPosition]) -> Bool
```

## Performance Guidelines

### Memory Management
```swift
// Use weak references to prevent retain cycles
class VideoProcessor {
    weak var delegate: ProcessingDelegate?
    
    // Cleanup resources in deinit
    deinit {
        cleanupResources()
    }
}

// Explicit resource cleanup
defer {
    // Always cleanup, even on error
    detector.cleanup()
    tracker.cleanup()
}
```

### Async/Await Patterns
```swift
// Check for cancellation in long-running loops
func processVideoFrames(_ frames: [CMSampleBuffer]) async throws {
    for frame in frames {
        try Task.checkCancellation()
        
        let detection = try await detector.detect(frame)
        await updateProgress()
    }
}

// Use MainActor for UI updates
@MainActor
func updateProgress(_ value: Double) {
    self.progress = value
}
```

### Performance Optimizations
```swift
// Lazy initialization for expensive resources
lazy var heavyMLModel: MLModel = {
    return loadExpensiveModel()
}()

// Efficient frame processing with skipping
func processFramesEfficiently() {
    let frameStep = debugMode ? 3 : 1  // Skip frames in debug mode
    
    for i in stride(from: 0, to: frames.count, by: frameStep) {
        processFrame(frames[i])
    }
}
```

## Testing Patterns (Future Implementation)

### Unit Test Structure
```swift
final class VideoProcessorTests: XCTestCase {
    private var processor: VideoProcessor!
    private var mockDetector: MockVideoDetector!
    
    override func setUp() {
        super.setUp()
        mockDetector = MockVideoDetector()
        processor = VideoProcessor(detector: mockDetector)
    }
    
    func testRallyDetectionAccuracy() throws {
        // Given: Test video with known rally segments
        let testVideo = Bundle.test.url(forResource: "sample_rally", withExtension: "mp4")!
        
        // When: Processing the video
        let segments = try await processor.processVideo(at: testVideo)
        
        // Then: Expected rally segments are found
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments[0].contains(timestamp: 15.0))
    }
}
```

This style guide ensures consistency across the codebase while maintaining readability, performance, and architectural clarity for the volleyball analysis application.