# Coding Conventions

**Analysis Date:** 2026-01-24

## Naming Patterns

**Files:**
- PascalCase for all Swift files: `MediaStore.swift`, `VideoProcessor.swift`
- Feature-based naming: `LibraryViewModel.swift`, `ProcessVideoView.swift`
- Test files mirror source: `MediaStoreTests.swift`, `BallisticsGateEnhancedTests.swift`
- Design system prefix: `BSCButton.swift`, `BSCVideoCard.swift` (BSC = BumpSetCut)

**Functions:**
- camelCase for all functions: `addVideo()`, `createFolder()`, `processUpload()`
- Descriptive verb-first naming: `extractFrame()`, `validateDrop()`, `computeVideoCount()`
- Async functions use plain names (no `Async` suffix): `performUpload()`, `loadDebugData()`
- Private helpers prefixed when needed: `private func setupTestData()`, `private func handleMemoryPressure()`

**Variables:**
- camelCase for all properties: `searchText`, `isLoading`, `currentPath`
- Boolean properties use `is`, `has`, `can`, `should` prefixes: `isProcessed`, `hasMetadata`, `canGoBack`, `shouldSample()`
- Computed properties preferred over stored state for reactive values
- Constants use camelCase: `maxDepth`, `defaultTimeout`

**Types:**
- PascalCase for classes, structs, enums: `MediaStore`, `VideoMetadata`, `LibraryType`
- Protocol names use descriptive nouns: `Transferable`, `DropDelegate`
- Nested types use descriptive names: `ProcessorConfig`, `ExtractionConfig`, `PerformanceTelemetry`
- Enum cases use camelCase: `.saved`, `.processed`, `.primary`, `.secondary`

## Code Style

**Formatting:**
- No automated formatter detected (no .swiftformat or .swiftlint.yml found)
- Manual style is consistent across codebase
- 4-space indentation (standard Swift)
- Opening braces on same line: `func example() {`
- 120-character soft line limit (observed in practice)

**Linting:**
- No linter configuration found
- Code follows Swift API Design Guidelines manually
- Consistent with Apple's Swift conventions

## Import Organization

**Order:**
1. Foundation frameworks: `import Foundation`
2. Apple frameworks: `import SwiftUI`, `import AVFoundation`, `import CoreML`
3. Third-party libraries: `import MijickPopups`, `import Combine`
4. Test imports last: `import XCTest`, `@testable import BumpSetCut`

**Path Aliases:**
- No custom path aliases used
- Direct imports only: `import SwiftUI`
- Testable imports for tests: `@testable import BumpSetCut`

**Examples:**
```swift
import SwiftUI
import Combine
import Observation
```

```swift
import Foundation
import AVFoundation
import CoreGraphics
import UIKit
import os.log
```

## Error Handling

**Patterns:**
- Custom error enums conforming to `LocalizedError`:
  ```swift
  enum UploadError: LocalizedError {
      case invalidFileType
      case fileTooLarge(size: Int64, limit: Int64)
      // ...
  }
  ```
- Try/catch for recoverable errors with logging:
  ```swift
  do {
      try fileManager.removeItem(at: fileURL)
  } catch {
      print("Failed to delete video: \(error)")
      return false
  }
  ```
- Optional returns for non-critical failures: `func getVideoURL() -> URL?`
- Result types for async operations with detailed errors
- Guard statements for early returns:
  ```swift
  guard let videoMetadata = manifest.videos[fileName] else { return false }
  ```

**Error Propagation:**
- Throws for file I/O: `func extractFrame() async throws -> UIImage`
- Returns `Bool` for operation success/failure: `func deleteVideo() -> Bool`
- Optionals for nullable results: `func getVideoMetadata() -> VideoMetadata?`

## Logging

**Framework:** `os.log` (Apple's unified logging)

**Patterns:**
- Print statements for development debugging: `print("MediaStore: Base directory: \(path)")`
- Structured logging with emoji prefixes for visibility:
  ```swift
  print("📹 MediaStore.addVideo called:")
  print("   - URL: \(url)")
  print("✅ Video metadata added")
  print("⚠️ Folder not found")
  print("❌ Failed to get file attributes")
  ```
- Logger instances for subsystems:
  ```swift
  private let logger = Logger(subsystem: "com.bumpsetcut", category: "Upload")
  ```
- Detailed logging in critical paths (uploads, processing, storage)

**When to Log:**
- All public API boundaries in core services (`MediaStore`, `UploadManager`)
- State transitions: `print("MediaStore: Starting library migration...")`
- Error conditions with context: `print("Failed to create folder: \(error)")`
- Performance metrics: processing times, frame counts

## Comments

**When to Comment:**
- MARK comments for organization in all files:
  ```swift
  // MARK: - Video Operations
  // MARK: - Test Data Setup
  // MARK: - Computed Properties
  ```
- Complex algorithms get explanatory comments:
  ```swift
  // Calculate new path by replacing the old prefix with new prefix
  let newFolderPath = newPath + String(oldFolderPath.dropFirst(oldPath.count))
  ```
- TODO/FIXME for known issues (minimal in this codebase):
  ```swift
  // FIXME: Handle edge case for nested folders
  ```
- Deprecation notices:
  ```swift
  @available(*, deprecated, message: "Use getVideos(in:) with folder path parameter")
  ```

**JSDoc/TSDoc:**
- Not applicable (Swift doesn't use JSDoc)
- Documentation comments use triple-slash `///` (rare in this codebase):
  ```swift
  /// Computes the actual video count for a folder by counting videos in manifest
  func computeVideoCount(for folderPath: String) -> Int
  ```

## Function Design

**Size:**
- Functions kept focused and single-purpose
- Long operations broken into private helpers:
  ```swift
  private func updateChildPaths(oldPath: String, newPath: String)
  private func removeChildItems(at path: String)
  ```
- Test helper functions extracted for reusability:
  ```swift
  private func createTestVideoURL(fileName: String) -> URL
  private func createParabolicPositions(...) -> [(CGPoint, CMTime)]
  ```

**Parameters:**
- Named parameters for clarity: `addVideo(at url: URL, toFolder folderPath: String, customName: String?)`
- Default values used extensively: `toFolder folderPath: String = ""`
- Argument labels omitted when obvious: `func deleteVideo(_ fileName: String)`
- Complex configs use dedicated types: `BallisticsGate(config: ProcessorConfig)`

**Return Values:**
- Explicit return types always: `func getVideos() -> [VideoMetadata]`
- Async functions return values directly: `async -> UIImage`
- Bool for success/failure: `func renameFolder() -> Bool`
- Optionals for nullable results: `func getVideoMetadata() -> VideoMetadata?`
- Tuples for multiple related values: `-> [(CGPoint, CMTime)]`

## Module Design

**Exports:**
- All types default to internal access (no explicit `internal` keyword)
- Public APIs not explicitly marked (single module app)
- Private used extensively for implementation details:
  ```swift
  private func saveManifest()
  private var foregroundColor: Color
  ```

**Barrel Files:**
- Not used (Swift doesn't have barrel exports)
- Features self-contained in directories
- Related types grouped in same file:
  ```swift
  // In MediaStore.swift:
  enum LibraryType { ... }
  struct VideoMetadata { ... }
  struct FolderMetadata { ... }
  @MainActor class MediaStore { ... }
  ```

## SwiftUI-Specific Conventions

**View Models:**
- Use `@Observable` macro (modern SwiftUI observation):
  ```swift
  @Observable
  final class LibraryViewModel {
      var searchText: String = ""
      var isLoading: Bool = false
  }
  ```
- `@MainActor` annotation for UI-bound classes:
  ```swift
  @MainActor
  @Observable
  final class SearchViewModel { ... }
  ```
- Computed properties for derived state (not stored):
  ```swift
  var isEmpty: Bool {
      filteredFolders.isEmpty && filteredVideos.isEmpty
  }
  ```

**View Composition:**
- Extract private subviews for complex layouts:
  ```swift
  private struct OnboardingFooter: View { ... }
  ```
- Use `@ViewBuilder` for conditional views:
  ```swift
  @ViewBuilder
  private var background: some View {
      switch style {
      case .primary: LinearGradient.bscPrimaryGradient
      case .secondary: Color.bscOrange.opacity(0.12)
      }
  }
  ```

**Design Tokens:**
- Centralized in `DesignSystem/Tokens/`:
  - `ColorTokens.swift`: `.bscOrange`, `.bscBackground`
  - `SpacingTokens.swift`: `BSCSpacing.md`, `BSCRadius.lg`
  - `AnimationTokens.swift`: `.bscQuick`, `.bscSmooth`
- Accessed via static properties:
  ```swift
  .padding(BSCSpacing.lg)
  .background(Color.bscSurfaceElevated)
  .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
  ```

## Data Persistence

**Codable Patterns:**
- Use `decodeIfPresent` for backwards compatibility:
  ```swift
  isProcessed = try container.decodeIfPresent(Bool.self, forKey: .isProcessed) ?? false
  debugSessionId = try container.decodeIfPresent(UUID.self, forKey: .debugSessionId)
  ```
- Custom `init(from decoder:)` for complex decoding logic
- Custom `encode(to encoder:)` for conditional encoding
- Private `CodingKeys` enum for property mapping:
  ```swift
  private enum CodingKeys: String, CodingKey {
      case id, fileName, customName, folderPath
  }
  ```

**File Operations:**
- Never load entire videos as `Data` - use URL-based operations
- Use `FileManager` for all disk operations
- Check file existence before operations:
  ```swift
  guard fileManager.fileExists(atPath: url.path) else { return nil }
  ```

## Memory Management

**Resource Cleanup:**
- Explicit cleanup in `deinit` (when needed)
- Cancel operations in `onDisappear`:
  ```swift
  .onDisappear {
      player?.pause()
      player = nil
  }
  ```
- Use weak references in closures when capturing self:
  ```swift
  .sink { [weak self] value in
      self?.handleUpdate(value)
  }
  ```

**Concurrency:**
- Use structured concurrency (async/await)
- `Task` for fire-and-forget operations:
  ```swift
  Task {
      await performUpload()
  }
  ```
- `@MainActor` for UI updates
- Avoid `DispatchQueue` (legacy patterns in FrameExtractor only)

---

*Convention analysis: 2026-01-24*
