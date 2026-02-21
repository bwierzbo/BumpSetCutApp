# Testing Patterns

**Analysis Date:** 2026-01-24

## Test Framework

**Runner:**
- XCTest (Apple's native testing framework)
- Config: Xcode project settings (no separate config file)

**Assertion Library:**
- XCTest assertions: `XCTAssertTrue`, `XCTAssertEqual`, `XCTAssertNotNil`

**Run Commands:**
```bash
# Run all tests (via xcodebuild)
xcodebuild -project BumpSetCut.xcodeproj -scheme BumpSetCut test

# Run with simulator
xcodebuild -project BumpSetCut.xcodeproj -scheme BumpSetCut \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

**Note:** CLAUDE.md states "No test framework currently - testing is done manually with sample videos" but the codebase contains extensive XCTest test suite (21 test files found).

## Test File Organization

**Location:**
- Separate `BumpSetCutTests/` directory at project root
- Mirror source structure in test directory:
  ```
  BumpSetCutTests/
  ├── Data/
  │   ├── Models/
  │   │   ├── ProcessorConfigTests.swift
  │   │   └── ProcessingMetadataTests.swift
  │   └── Storage/
  │       ├── MediaStoreSearchTests.swift
  │       ├── MetadataStoreTests.swift
  │       └── VideoProcessingTrackingTests.swift
  ├── Domain/
  │   ├── Classification/
  │   │   └── MovementClassifierTests.swift
  │   ├── Logic/
  │   │   └── BallisticsGateEnhancedTests.swift
  │   └── Physics/
  │       └── ParabolicValidatorTests.swift
  ├── Infrastructure/
  │   └── Media/
  │       └── FrameExtractorTests.swift
  ├── Integration/
  │   ├── DebugPerformanceTests.swift
  │   ├── DeviceCompatibilityTests.swift
  │   ├── LibraryIntegrationTests.swift
  │   ├── PeekEdgeCaseTests.swift
  │   ├── PeekGestureIntegrationTests.swift
  │   └── PeekPerformanceTests.swift
  └── Presentation/
      ├── Components/
      │   └── MetadataOverlayViewTests.swift
      ├── Search/
      │   └── SearchViewModelTests.swift
      └── Views/
          ├── RallyPlayerViewTests.swift
          └── RallyPlayerGestureTests.swift
  ```

**Naming:**
- Pattern: `{SourceFile}Tests.swift` (e.g., `MediaStore.swift` → `MediaStoreSearchTests.swift`)
- Test classes: `final class {SourceName}Tests: XCTestCase`
- Integration tests grouped in `Integration/` directory

**Structure:**
```
BumpSetCutTests/
├── Data/           # Data layer: Models, Storage
├── Domain/         # Business logic: Classification, Physics, Logic
├── Infrastructure/ # Low-level services: Media extraction
├── Integration/    # End-to-end integration tests
└── Presentation/   # UI: ViewModels, Views, Components
```

## Test Structure

**Suite Organization:**
```swift
import XCTest
import Combine
@testable import BumpSetCut

@MainActor
final class SearchViewModelTests: XCTestCase {
    // MARK: - Test Properties
    var mediaStore: MediaStore!
    var searchViewModel: SearchViewModel!
    var cancellables: Set<AnyCancellable>!

    // MARK: - Setup and Teardown
    override func setUp() async throws {
        try await super.setUp()
        mediaStore = MediaStore()
        searchViewModel = SearchViewModel(mediaStore: mediaStore)
        cancellables = Set<AnyCancellable>()

        await setupTestData()
    }

    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        searchViewModel = nil
        mediaStore = nil
        try await super.tearDown()
    }

    // MARK: - Test Data Setup
    private func setupTestData() async { ... }

    // MARK: - Basic Search Tests
    func testSearchInitialState() { ... }

    func testEmptySearchReturnsNoResults() async { ... }

    // MARK: - Filter Tests
    func testFileTypeFilter() async { ... }
}
```

**Patterns:**
- MARK comments organize test sections by functionality
- Setup creates fresh instances for each test
- Teardown cleans up all resources (prevents leaks)
- Helper methods extracted to `// MARK: - Test Data Setup` section
- Async tests use `async throws` for setup/teardown
- `@MainActor` when testing UI-bound code

**Test Naming:**
- Format: `test{Feature}{Scenario}()`
- Examples: `testSearchInitialState()`, `testEmptySearchReturnsNoResults()`
- Descriptive names: `testEnhancedValidation_RejectsCarriedBall()`
- Performance tests: `testPerformance_EnhancedValidation()`

## Mocking

**Framework:** No external mocking framework (manual mocking)

**Patterns:**
```swift
// Test doubles created inline
private func createTestVideoURL(fileName: String) -> URL {
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let testURL = documentsPath.appendingPathComponent(fileName)

    // Create empty test file if it doesn't exist
    if !FileManager.default.fileExists(atPath: testURL.path) {
        FileManager.default.createFile(atPath: testURL.path, contents: Data(), attributes: nil)
    }

    return testURL
}

// Physics test data factories
private func createParabolicPositions(
    initialVelocity: CGVector,
    gravity: Double,
    startPoint: CGPoint,
    timeStep: Double,
    steps: Int
) -> [(CGPoint, CMTime)] {
    var positions: [(CGPoint, CMTime)] = []
    for i in 0..<steps {
        let t = Double(i) * timeStep
        let x = startPoint.x + initialVelocity.dx * CGFloat(t)
        let y = startPoint.y + initialVelocity.dy * CGFloat(t) + CGFloat(0.5 * gravity * t * t)
        let time = CMTimeMakeWithSeconds(t, preferredTimescale: 600)
        positions.append((CGPoint(x: x, y: y), time))
    }
    return positions
}
```

**What to Mock:**
- File system operations: Create temporary directories and files
- Video data: Generate synthetic trajectories for physics tests
- Network operations: Not applicable (no networking in tests observed)
- Time-dependent data: Use `CMTime` for precise video timestamps

**What NOT to Mock:**
- Core business logic (`MediaStore`, `BallisticsGate`)
- Data models (`VideoMetadata`, `ProcessorConfig`)
- Value types (structs, enums)
- SwiftUI framework components

## Fixtures and Factories

**Test Data:**
```swift
// Factory pattern for complex objects
private func createTestMetadata(videoId: UUID? = nil) -> ProcessingMetadata {
    let config = ProcessorConfig()

    let rallySegment = RallySegment(
        startTime: CMTime(seconds: 10.0, preferredTimescale: 600),
        endTime: CMTime(seconds: 15.0, preferredTimescale: 600),
        confidence: 0.95,
        quality: 0.88,
        detectionCount: 150,
        averageTrajectoryLength: 25.0
    )

    let stats = ProcessingStats(
        totalFrames: 1800,
        processedFrames: 1750,
        // ... more properties
    )

    return ProcessingMetadata(/* ... */)
}

// Named test scenarios
private func createVolleyballTrajectory() -> KalmanBallTracker.TrackedBall {
    let positions = createParabolicPositions(
        initialVelocity: CGVector(dx: 0.3, dy: -0.5),
        gravity: 0.98,
        startPoint: CGPoint(x: 0.2, y: 0.8),
        timeStep: 0.033,
        steps: 12
    )
    return KalmanBallTracker.TrackedBall(positions: positions)
}

private func createCarriedBallTrajectory() -> KalmanBallTracker.TrackedBall { ... }
private func createRollingBallTrajectory() -> KalmanBallTracker.TrackedBall { ... }
```

**Location:**
- Inline in test files (no separate fixtures directory)
- Helper methods grouped in `// MARK: - Test Data Setup` or `// MARK: - Helper Methods` sections
- Reusable across tests in same file

**Patterns:**
- Default parameters for flexibility: `videoId: UUID? = nil`
- Descriptive factory names: `createHighQualityVolleyballTrajectory()`
- Parameterized factories for variations: `createTrajectoryWithFewPoints(pointCount: Int)`

## Coverage

**Requirements:** No explicit coverage targets enforced

**View Coverage:**
```bash
# Coverage not configured in visible xcodebuild commands
# Would require: xcodebuild test -enableCodeCoverage YES
```

**Current Coverage Areas:**
- ✅ Data layer: Storage (MediaStore, MetadataStore)
- ✅ Domain logic: Physics validation, Classification, Tracking
- ✅ Presentation: ViewModels (SearchViewModel)
- ✅ Integration: Multi-component workflows
- ⚠️ UI Views: Limited (MetadataOverlayView, RallyPlayerView only)
- ⚠️ Export: VideoExporter tested but DebugAnnotator minimal

## Test Types

**Unit Tests:**
- Scope: Single class/function in isolation
- Example locations:
  - `Data/Models/ProcessorConfigTests.swift` - Config validation
  - `Domain/Physics/ParabolicValidatorTests.swift` - Physics algorithms
  - `Domain/Classification/MovementClassifierTests.swift` - Classification logic
- Approach: Test individual methods with controlled inputs

**Integration Tests:**
- Scope: Multiple components working together
- Example locations:
  - `Integration/LibraryIntegrationTests.swift` - MediaStore + FolderManager + Search
  - `Integration/PeekGestureIntegrationTests.swift` - Gesture handling + UI state
  - `Integration/DebugPerformanceTests.swift` - End-to-end processing pipeline
- Approach: Test realistic workflows with real data flow

**E2E Tests:**
- Framework: Not used (no UI testing framework detected)
- Would require: XCTest UI Testing
- Current approach: Manual testing with sample videos (per CLAUDE.md)

## Common Patterns

**Async Testing:**
```swift
func testBasicVideoSearch() async {
    let expectation = XCTestExpectation(description: "Search completes")

    searchViewModel.$searchResults
        .dropFirst() // Skip initial empty state
        .sink { results in
            if !results.isEmpty {
                expectation.fulfill()
            }
        }
        .store(in: &cancellables)

    searchViewModel.searchText = "volleyball"

    await fulfillment(of: [expectation], timeout: 2.0)

    XCTAssertFalse(searchViewModel.searchResults.isEmpty)
}
```

**Combine Testing:**
```swift
// Use XCTestExpectation with Combine publishers
var cancellables: Set<AnyCancellable>!

override func setUp() async throws {
    cancellables = Set<AnyCancellable>()
}

override func tearDown() async throws {
    cancellables.forEach { $0.cancel() }
    cancellables = nil
}

func testPublisher() async {
    let expectation = XCTestExpectation(description: "Publisher emits")

    viewModel.$property
        .dropFirst()
        .sink { value in
            expectation.fulfill()
        }
        .store(in: &cancellables)

    viewModel.performAction()
    await fulfillment(of: [expectation], timeout: 1.0)
}
```

**Error Testing:**
```swift
func testInvalidInput_ThrowsError() {
    XCTAssertThrowsError(try validator.validate(invalidData)) { error in
        XCTAssertTrue(error is ValidationError)
    }
}

func testFailureCondition() {
    let result = processor.process(malformedData)
    XCTAssertFalse(result, "Should fail on malformed data")
}
```

**Comparison Testing:**
```swift
func testComparison_ValidTrajectoryAcceptedByBoth() {
    let track = createHighQualityVolleyballTrajectory()

    let legacyResult = legacyGate.isValidProjectile(track)
    let enhancedResult = enhancedGate.isValidProjectile(track)

    XCTAssertTrue(legacyResult, "Legacy validation should accept")
    XCTAssertTrue(enhancedResult, "Enhanced validation should accept")
}

func testComparison_EnhancedMoreStrictOnCarriedMovement() {
    let track = createSubtleCarriedBallTrajectory()

    let legacyResult = legacyGate.isValidProjectile(track)
    let enhancedResult = enhancedGate.isValidProjectile(track)

    if legacyResult {
        XCTAssertFalse(enhancedResult, "Enhanced should be stricter")
    }
}
```

**Performance Testing:**
```swift
func testPerformance_EnhancedValidation() {
    let track = createComplexTrajectory()

    measure {
        for _ in 0..<100 {
            _ = enhancedGate.isValidProjectile(track)
        }
    }
}

func testPerformance_LegacyVsEnhanced() {
    let track = createStandardTrajectory()

    let legacyTime = measureTime {
        for _ in 0..<100 {
            _ = legacyGate.isValidProjectile(track)
        }
    }

    let enhancedTime = measureTime {
        for _ in 0..<100 {
            _ = enhancedGate.isValidProjectile(track)
        }
    }

    XCTAssertLessThan(enhancedTime, legacyTime * 5.0,
                     "Enhanced should not be >5x slower")
}

private func measureTime(_ block: () -> Void) -> TimeInterval {
    let startTime = CFAbsoluteTimeGetCurrent()
    block()
    return CFAbsoluteTimeGetCurrent() - startTime
}
```

**Temporary Resources:**
```swift
override func setUpWithError() throws {
    try super.setUpWithError()

    // Create temporary directory
    tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MetadataStoreTests_\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory,
        withIntermediateDirectories: true
    )
}

override func tearDownWithError() throws {
    // Clean up temp directory
    if let tempDirectory = tempDirectory {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    tempDirectory = nil
    try super.tearDownWithError()
}
```

## Test Organization Best Practices

**File Structure:**
- One test class per source file
- Group related tests in MARK sections
- Order: Setup → Test Data → Tests (by feature area) → Helpers

**Assertion Patterns:**
- Use descriptive messages: `XCTAssertTrue(isValid, "Valid volleyball trajectory should pass")`
- Test one concept per test method
- Arrange-Act-Assert pattern (implicit, not commented)

**Async/Await:**
- Use `async` tests for asynchronous operations
- `await fulfillment(of:timeout:)` for expectations
- `async throws` for setup/teardown when needed
- `@MainActor` on test class when testing UI code

**Resource Management:**
- Always clean up in `tearDown()`
- Cancel Combine subscriptions explicitly
- Remove temporary files and directories
- Set properties to `nil` in tearDown

---

*Testing analysis: 2026-01-24*
