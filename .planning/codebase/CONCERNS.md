# Codebase Concerns

**Analysis Date:** 2026-01-24

## Tech Debt

**Enhanced Physics Validation Disabled:**
- Issue: `enableEnhancedPhysics` is disabled by default due to overly strict validation blocking valid rallies
- Files: `BumpSetCut/Models/Detections.swift:87`, `BumpSetCut/Features/Processing/Logic/BallisticsGate.swift:43`
- Impact: Advanced physics-based trajectory validation is not active, reducing accuracy of rally detection. Test expects it enabled by default but production has it disabled
- Fix approach: Review physics constraints (R² thresholds, acceleration patterns) to find balance between accuracy and recall. Consider making thresholds configurable per video quality/type

**Videos Cannot Be Reprocessed:**
- Issue: `canBeProcessed` computed property blocks videos from being processed again once they have processed versions
- Files: `BumpSetCut/Core/Storage/MediaStore.swift:167-169`
- Impact: Users cannot reprocess videos with different settings or after bugs are fixed. No way to regenerate rallies without deleting existing processed versions first
- Fix approach: Add "reprocess" feature that either (1) archives old processed versions or (2) allows multiple processing sessions with timestamps

**Analytics TODOs Not Implemented:**
- Issue: Multiple TODOs for sending analytics events that are never implemented
- Files: `BumpSetCut/App/AppSettings.swift:102`, `BumpSetCut/App/AppSettings.swift:115`
- Impact: No visibility into feature usage patterns or crash analytics
- Fix approach: Either implement analytics service integration or remove TODOs if analytics are not planned

**Large File Complexity:**
- Issue: MediaStore exceeds 1400 lines with mixed responsibilities (CRUD, folders, debug data, relationships)
- Files: `BumpSetCut/Core/Storage/MediaStore.swift` (1440 lines)
- Impact: Difficult to modify, test, and reason about. High risk of bugs when changing video management logic
- Fix approach: Split into separate managers: VideoRepository, FolderRepository, DebugDataManager, MetadataRepository

**Heavy Use of Print Statements for Logging:**
- Issue: 767 occurrences of `print()` across 38 files instead of structured logging
- Files: Throughout codebase, particularly in `BumpSetCut/Features/Processing/VideoProcessor.swift:26+`
- Impact: No log levels, filtering, or production control. Clutters console and cannot be disabled in release builds
- Fix approach: Introduce Logger from os.log or similar structured logging framework. Replace print() with logger.debug/info/error

**No Test Framework Configuration:**
- Issue: CLAUDE.md states "No test framework currently - testing is done manually with sample videos"
- Files: Project root (no test configuration)
- Impact: Cannot verify rally detection accuracy automatically. Regressions may go undetected until users report issues
- Fix approach: Add XCTest framework with fixture videos for regression testing of processing pipeline

## Known Bugs

**File Upload Warning:**
- Symptoms: UploadManager logs "WARNING - File not found after writing!" even when upload succeeds
- Files: `BumpSetCut/Services/UploadManager.swift:231`
- Trigger: During video upload process, likely race condition in file verification
- Workaround: Log message appears but upload completes successfully - warning can be ignored

**Missing Font Crash:**
- Symptoms: `fatalError("Missing font \(weight)")` crashes app if custom font not found
- Files: `BumpSetCut/DesignSystem/Typography/Font+MFontModifier.swift:14`
- Trigger: Loading custom font with unavailable weight
- Workaround: None - app will crash. Needs fallback to system font

## Security Considerations

**Debug Data Exposure:**
- Risk: Debug data (trajectories, physics validation) stored in `.debug_data` directory with UUIDs as filenames
- Files: `BumpSetCut/Core/Storage/MediaStore.swift:1165`
- Current mitigation: Hidden directory (dot-prefix), not exported by default
- Recommendations: Add option to encrypt debug data, implement automatic cleanup after N days, ensure debug data never included in app backups

**No Input Validation on Video Files:**
- Risk: Malicious video files could exploit AVFoundation vulnerabilities
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift`, upload paths
- Current mitigation: AVFoundation's built-in validation
- Recommendations: Add file size limits before processing, validate video codec/format before loading into AVAsset, implement processing timeout to prevent DoS

**Temporary File Cleanup:**
- Risk: Temporary video files created during upload may not be cleaned up on failure
- Files: `BumpSetCut/Services/UploadCoordinator.swift:27-30`, `BumpSetCut/Services/UploadCoordinator.swift:331-335`
- Current mitigation: Files stored in `FileManager.default.temporaryDirectory` which iOS cleans eventually
- Recommendations: Implement explicit cleanup in error handlers and `deinit`, track temp files for manual cleanup on app restart

## Performance Bottlenecks

**Synchronous Asset Loading:**
- Problem: Video asset metadata loaded with `try await asset.load()` blocks processing start
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift:54-59`, `BumpSetCut/Features/Processing/VideoProcessor.swift:184-194`
- Cause: AVFoundation async/await pattern requires sequential loading of tracks, duration, frame rate
- Improvement path: Load multiple properties concurrently with `async let`, cache asset properties for reprocessing

**Frame-by-Frame Processing Without Batching:**
- Problem: VideoProcessor processes every frame individually without batching or sampling
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift:79-116`
- Cause: CoreML inference on every frame at full video FPS (30-60fps)
- Improvement path: Implement adaptive frame sampling (skip frames during low-motion periods), batch inference requests, consider lower resolution detection

**Sample Buffer Memory Accumulation:**
- Problem: CMSampleBuffers invalidated but VideoProcessor still processes large videos frame-by-frame in memory
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift:116` (has `CMSampleBufferInvalidate` but still iterative)
- Cause: AVAssetReader keeps reading entire video into memory even with invalidation
- Improvement path: Process video in chunks/segments, release reader between segments, implement memory pressure monitoring

**Kalman Tracker Not Pruning Old Tracks:**
- Problem: KalmanBallTracker accumulates tracks without cleanup, memory grows during long video processing
- Files: `BumpSetCut/Features/Processing/Tracking/KalmanBallTracker.swift`
- Cause: No maximum track count or age-based pruning
- Improvement path: Remove tracks that haven't been updated in N frames, limit maximum active tracks, implement track confidence scoring

## Fragile Areas

**Video Processing Relationship Management:**
- Files: `BumpSetCut/Core/Storage/MediaStore.swift:790-816` (cleanupProcessedVideoRelationships)
- Why fragile: Manual bidirectional relationship maintenance between original and processed videos. Must update both `originalVideoId` and `processedVideoIds` array synchronously
- Safe modification: Always use cleanupProcessedVideoRelationships when deleting videos, never modify relationship fields directly, add validation in manifest save
- Test coverage: Has tests in `BumpSetCutTests/Data/Storage/VideoProcessingTrackingTests.swift` but complex state machine needs more edge case coverage

**Physics Gate Configuration:**
- Files: `BumpSetCut/Models/Detections.swift:32-150` (ProcessorConfig with 50+ parameters)
- Why fragile: 50+ interrelated configuration parameters for physics validation. Changing one threshold affects validation in unpredictable ways
- Safe modification: Only change one parameter at a time, test with diverse video samples, use ParameterOptimizer for systematic tuning
- Test coverage: Tests exist but don't validate parameter interactions

**AVPlayer Lifecycle in Rally Playback:**
- Files: `BumpSetCut/Features/RallyPlayback/Components/RallyVideoPlayer.swift:84-99`, `BumpSetCut/Features/RallyPlayback/VideoPlayerView.swift:47-48`
- Why fragile: AVPlayer instances must be cleaned up in `onDisappear` to prevent memory leaks, but SwiftUI view lifecycle is unpredictable
- Safe modification: Always pair player creation in `onAppear` with cleanup in `onDisappear`, use RallyPlayerCache for shared instances, test with rapid navigation
- Test coverage: Minimal - lifecycle testing difficult with SwiftUI

**Manifest Save and Notification Timing:**
- Files: `BumpSetCut/Core/Storage/MediaStore.swift` (posts `.libraryContentChanged` after saves)
- Why fragile: UI depends on notification to refresh, but notification fires before file writes are guaranteed to complete
- Safe modification: Ensure all file operations complete before posting notification, consider debouncing rapid manifest saves
- Test coverage: No explicit tests for notification timing or race conditions

## Scaling Limits

**Video Library Size:**
- Current capacity: File-based manifest loaded entirely into memory on app launch
- Limit: Will degrade with 1000+ videos as manifest JSON grows to megabytes
- Scaling path: Implement pagination/lazy loading of manifest, migrate to SQLite for large libraries, add virtual scrolling in UI

**Concurrent Processing:**
- Current capacity: Single video processed at a time
- Limit: Cannot process multiple videos in parallel, no queue management
- Scaling path: Implement processing queue with concurrent workers, add priority system, track processing jobs in manifest

**Debug Data Storage:**
- Current capacity: Unlimited debug data accumulation in `.debug_data` directory
- Limit: Debug files can grow unbounded, consuming device storage
- Scaling path: Implement max age for debug data (30 days), add storage quota, automatic cleanup on low disk space

## Dependencies at Risk

**AVFoundation Version Compatibility:**
- Risk: Code uses `if #available(iOS 18.0, *)` branching for export APIs
- Files: `BumpSetCut/Features/Export/VideoExporter.swift:58-76`
- Impact: Different code paths for iOS 18+ vs legacy, potential behavior divergence
- Migration plan: Maintain minimum iOS version requirement, test on all supported iOS versions, consider deprecating pre-iOS 18 when possible

**CoreML Model Dependency:**
- Risk: App requires `bestv2.mlpackage` but CLAUDE.md says "App functions without model but AI features are disabled"
- Files: `Resources/ML/bestv2.mlpackage` (referenced but not analyzed)
- Impact: Without model, rally detection completely non-functional
- Migration plan: Bundle model with app always, or implement graceful degradation with user warning, consider on-demand model download

## Missing Critical Features

**Error Recovery in Video Processing:**
- Problem: Video processing errors throw and abort, no retry or partial recovery
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift:119-126`
- Blocks: Cannot process videos that fail partway through, user must restart from beginning

**Storage Space Validation:**
- Problem: No pre-flight check if device has enough space for processing output
- Files: Upload paths have `StorageChecker` utility but processing doesn't use it
- Blocks: Processing can fail mid-operation due to disk full, leaving corrupt state

**Processing Cancellation Cleanup:**
- Problem: Task cancellation check exists but doesn't clean up partial processing artifacts
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift:83` (has `Task.checkCancellation()`)
- Blocks: Cancelled processing leaves temp files and invalid metadata

**Batch Operations:**
- Problem: No way to delete, move, or process multiple videos at once
- Files: UI has individual video operations only
- Blocks: Users managing large libraries must operate on videos one at a time

## Test Coverage Gaps

**Processing Pipeline Integration:**
- What's not tested: End-to-end rally detection from raw video to exported segments
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift`, full pipeline
- Risk: Config changes or iOS updates could break rally detection silently
- Priority: High - core feature of app

**Concurrent Upload Handling:**
- What's not tested: Multiple simultaneous uploads with different destinations
- Files: `BumpSetCut/Services/UploadCoordinator.swift:414+` (processItemsDirectly)
- Risk: Race conditions in manifest updates, file naming collisions
- Priority: Medium - common user scenario

**Folder Migration Edge Cases:**
- What's not tested: Migration with orphaned videos, circular references, duplicate folder names
- Files: `BumpSetCut/Core/Storage/Migrations/FolderMigration.swift`
- Risk: Users upgrading from old versions may lose videos or folder structure
- Priority: High - data loss potential

**Memory Pressure During Long Video Processing:**
- What's not tested: Processing behavior when device is under memory pressure
- Files: `BumpSetCut/Features/Processing/VideoProcessor.swift` (entire processing loop)
- Risk: App crashes or gets terminated by iOS watchdog on older devices
- Priority: High - affects production usage

**Backwards Compatibility of Codable Models:**
- What's not tested: Loading old manifest/metadata JSON with missing fields
- Files: `BumpSetCut/Models/VideoMetadata.swift`, `BumpSetCut/Models/ProcessingMetadata.swift:58-75`
- Risk: App updates that add new fields could crash when loading old data
- Priority: Medium - uses `decodeIfPresent` but not systematically tested

---

*Concerns audit: 2026-01-24*
