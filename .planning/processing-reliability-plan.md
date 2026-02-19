# Processing Pipeline: Reliability & Observability Plan

## 1. Architecture Map

```
┌─────────────────────────────────────────────────────────────────────┐
│  ProcessVideoViewModel (@MainActor, @Observable)                     │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────────┐ │
│  │ Pre-checks   │→ │ Task launch  │→ │ Post-processing save flow  │ │
│  │ • Subscription│  │ currentTask  │  │ • Hard link original       │ │
│  │ • Network    │  │ (cancellable)│  │ • Folder picker            │ │
│  │ • Storage    │  │              │  │ • addProcessedVideo()      │ │
│  └──────────────┘  └──────┬───────┘  │ • Show rally viewer        │ │
│                           │          └────────────────────────────┘ │
└───────────────────────────┼────────────────────────────────────────┘
                            │ await
┌───────────────────────────▼────────────────────────────────────────┐
│  VideoProcessor (@Observable, NO actor isolation)                    │
│                                                                      │
│  processVideoMetadata(url, videoId) → async throws                  │
│  ┌────────────┐  ┌──────────┐  ┌────────────────────────────────┐  │
│  │ Sport      │→ │ AVAsset  │→ │ Frame Loop (cooperative pool)  │  │
│  │ Detector   │  │ Reader   │  │ ┌─────────────────────────────┐│  │
│  │ (15 frames)│  │ setup    │  │ │ YOLODetector.detect()       ││  │
│  └────────────┘  └──────────┘  │ │ KalmanBallTracker.update()  ││  │
│                                │ │ BallisticsGate.validate()    ││  │
│  BackgroundProcessingGuard     │ │ RallyDecider.update()        ││  │
│  (UIBackgroundTask, ~30s)      │ │ SegmentBuilder.observe()     ││  │
│                                │ └─────────────────────────────┘│  │
│                                └────────────────────────────────┘  │
│  Post-loop:                                                         │
│  SegmentBuilder.finalize() → [CMTimeRange]                          │
│  Build ProcessingMetadata → MetadataStore.saveMetadata() (atomic)   │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────────────┐  ┌────────────────────────────────────────┐
│  MetadataStore       │  │  MediaStore (@MainActor, @Observable)   │
│  (@MainActor)        │  │  • Manifest JSON (NON-ATOMIC writes)   │
│  • Atomic writes     │  │  • markVideoAsProcessed()              │
│  • Backup on save    │  │  • addProcessedVideo()                 │
│  • Rally segments    │  │  • Single source of truth for library  │
│  • Trim adjustments  │  │                                        │
└──────────────────────┘  └────────────────────────────────────────┘
```

### Key Files

| File | Lines | Role |
|------|-------|------|
| `Features/Processing/VideoProcessor.swift` | 911 | Core orchestrator: 3 processing paths, frame loop |
| `Features/Processing/ProcessVideoViewModel.swift` | 430 | UI state machine, task lifecycle, save flow |
| `Features/Processing/Logic/RallyDecider.swift` | 143 | Rally start/end hysteresis state machine |
| `Features/Processing/Logic/SegmentBuilder.swift` | 94 | Time range building with pre/post-roll |
| `Features/Processing/Logic/BallisticsGate.swift` | 230 | Physics validation (legacy + enhanced) |
| `Features/Processing/Logic/SportDetector.swift` | 254 | Beach vs indoor auto-detection |
| `Features/Processing/Tracking/KalmanBallTracker.swift` | 373 | Kalman filter multi-object tracker |
| `Features/Processing/BackgroundProcessingGuard.swift` | 38 | UIBackgroundTask wrapper |
| `Features/Export/VideoExporter.swift` | 389 | AVAssetExportSession wrapper |
| `Core/Storage/MediaStore.swift` | 1547 | Manifest-based video library |
| `Core/Storage/MetadataStore.swift` | 457 | Processing metadata persistence |
| `Models/Detections.swift` | 323 | ProcessorConfig, ProcessingError |

---

## 2. State Machine Spec

### Current State (implicit, distributed)

State is scattered across multiple properties with no transition validation:
- `VideoProcessor.isProcessing` (Bool)
- `VideoProcessor.progress` (Double)
- `VideoProcessor.processedURL` / `processedMetadata` (optionals)
- `ProcessVideoViewModel.noRalliesDetected` (Bool)
- `ProcessVideoViewModel.pendingSaveURL` (optional)
- `ProcessVideoViewModel.currentTask` (optional Task)

The `ProcessingState` computed enum derives state from these but has no guards against invalid combinations.

### Proposed State Machine

```
                    ┌─────────┐
                    │  IDLE   │ ← initial state
                    └────┬────┘
                         │ startProcessing()
                         ▼
                  ┌──────────────┐
                  │  VALIDATING  │ subscription, network, storage checks
                  └──────┬───────┘
                    fail │        │ pass
                    ┌────▼──┐     │
                    │ ERROR │     │
                    └───────┘     ▼
                         ┌────────────────┐
                         │  PROCESSING    │ frame loop running
                         │  progress: 0→1 │
                         └───┬────┬───┬───┘
                    cancel   │    │   │ error
                    ┌────────┘    │   └────────┐
                    ▼             │             ▼
              ┌───────────┐      │       ┌──────────┐
              │ CANCELLED │      │       │  FAILED  │
              └───────────┘      │       │ (+ why)  │
                                 │       └──────────┘
                          no rallies │  rallies found
                          ┌──────────┘    │
                          ▼               ▼
                   ┌─────────────┐  ┌──────────────┐
                   │ NO_RALLIES  │  │ PENDING_SAVE │ folder picker
                   │ (+ diagnostics) └──────┬───────┘
                   └─────────────┘          │ confirmSave()
                                            ▼
                                     ┌─────────────┐
                                     │  COMPLETE   │
                                     └─────────────┘
```

Each state transition should:
1. Log a structured event with timestamp and context
2. Be the ONLY way state changes (no scattered property mutations)
3. Be validated (e.g., can't go from IDLE to COMPLETE)

---

## 3. Findings Summary (Cross-Engineer)

### CRITICAL Issues
| # | Issue | Source | Severity |
|---|-------|--------|----------|
| C1 | MediaStore `saveManifest()` is non-atomic — crash mid-write = total library loss | reliability | CRITICAL |
| C2 | `ProcessingError.exportFailed` overloaded for 6+ failure causes — "no rallies" shown for real errors | reliability, QA, observability | HIGH |
| C3 | Zero structured logging — all `print()`, no os_log/Logger, no event trail | observability | HIGH |
| C4 | VideoProcessor `@Observable` but no actor isolation — data race risk on cooperative pool | performance | HIGH |
| C5 | AVAssetReader never explicitly cancelled on Task cancellation — resource leak | video, performance | HIGH |
| C6 | BackgroundProcessingGuard only warns on expiry — doesn't cancel or save state | reliability, performance, QA | MEDIUM |
| C7 | No test coverage for VideoProcessor, ProcessVideoViewModel, VideoExporter | QA | HIGH |
| C8 | `isComplete` checks `processedURL` which is never set in metadata path — likely dead/broken | QA | MEDIUM |
| C9 | Trim adjustments can create negative-duration CMTimeRanges — no start < end validation | video | MEDIUM |
| C10 | Hardcoded placeholder values in QualityBreakdown (velocityConsistency: 0.8, verticalMotion: 0.7) | observability | LOW |

---

## 4. PR Breakdown

### PR1: Atomic Manifest Writes + Processing Error Taxonomy

**Goal:** Fix the two most dangerous bugs — non-atomic manifest writes and overloaded error enum.

**Files:**
- `Core/Storage/MediaStore.swift` — make `saveManifest()` atomic (write to temp, rename)
- `Models/Detections.swift` — split `ProcessingError.exportFailed` into specific cases: `.noRalliesDetected`, `.noVideoTrack`, `.assetReaderFailed(Error?)`, `.exportSessionFailed(String)`, `.compositionFailed`
- `Features/Processing/VideoProcessor.swift` — throw correct error types
- `Features/Export/VideoExporter.swift` — throw correct error types
- `Features/Processing/ProcessVideoViewModel.swift` — catch specific errors, show appropriate UI per error type

**Acceptance Criteria:**
- [ ] `MediaStore.saveManifest()` uses atomic write (write to `.tmp`, `FileManager.replaceItemAt` or rename)
- [ ] `ProcessingError` has distinct cases for each failure mode
- [ ] "No rallies detected" UI only appears for `.noRalliesDetected`
- [ ] Other errors show their actual error message
- [ ] Existing tests pass
- [ ] Build succeeds

---

### PR2: Structured Processing Event Log

**Goal:** Replace scattered `print()` with a lightweight structured event system. After this PR, every processing run produces a JSON event trail answering "what happened, when, and why?"

**Files:**
- NEW: `Features/Processing/ProcessingEventLog.swift` — simple append-only event logger (struct-based, Codable events, writes to temp file or memory)
- `Features/Processing/VideoProcessor.swift` — emit events: `processingStarted`, `sportDetected`, `frameLoopProgress` (every N seconds), `rallyStateChanged`, `segmentFinalized`, `processingCompleted`, `processingFailed`
- `Features/Processing/Logic/RallyDecider.swift` — emit `rallyStarted` / `rallyEnded` events with evidence (ballRate, projDuration)
- `Features/Processing/ProcessVideoViewModel.swift` — emit `saveStarted`, `saveCompleted`, `saveFailed`
- `Models/ProcessingMetadata.swift` — add optional `eventLog: [ProcessingEvent]` field (backwards-compatible with `decodeIfPresent`)

**Acceptance Criteria:**
- [ ] Each processing run produces a chronological event array
- [ ] Events are Codable and include timestamp + structured payload
- [ ] Event log is persisted in ProcessingMetadata (queryable after the fact)
- [ ] Rally state transitions include evidence data (why did the rally start/end?)
- [ ] No performance regression — events are lightweight structs, no string formatting in hot loop
- [ ] Existing tests pass
- [ ] Build succeeds

---

### PR3: Processing State Machine + AVAssetReader Lifecycle

**Goal:** Replace implicit distributed state with a driven state machine. Fix resource lifecycle.

**Files:**
- `Features/Processing/ProcessVideoViewModel.swift` — replace scattered Bool/Optional state with a single `ProcessingState` enum that is SET (not computed). Add transition methods with guards. Remove `isComplete` (broken for metadata path).
- `Features/Processing/VideoProcessor.swift` — add `defer { reader.cancelReading() }` after `reader.startReading()` in all 3 processing paths. Fix `isProcessing` cleanup on all error paths.
- `Features/Processing/BackgroundProcessingGuard.swift` — on expiry, cancel the processing Task (accept a cancellation closure in `begin()`). Log expiry as a structured event.

**Acceptance Criteria:**
- [ ] `ProcessingState` is a stored enum with explicit transition methods
- [ ] Invalid transitions are guarded (e.g., can't go from `.idle` to `.complete`)
- [ ] AVAssetReader is always cancelled via `defer` block on every exit path
- [ ] BackgroundProcessingGuard cancels the processing Task on expiry
- [ ] `isProcessing` is correctly reset on ALL error paths
- [ ] No state desynchronization possible (single source of truth)
- [ ] Existing tests pass
- [ ] Build succeeds

---

### PR4: Export Safety + Trim Validation

**Goal:** Prevent invalid time ranges from reaching AVAssetExportSession.

**Files:**
- `Features/RallyPlayback/Services/RallyTrimManager.swift` — add `guard effectiveStart < effectiveEnd` in computed properties
- `Features/RallyPlayback/Export/RallyExportProgress.swift` — validate time range before export, skip invalid segments
- `Features/Export/VideoExporter.swift` — add serial export guard (prevent concurrent exports), clean up partial files on all failure paths
- `Features/Processing/Logic/SegmentBuilder.swift` — no changes needed (already clamps correctly)

**Acceptance Criteria:**
- [ ] `effectiveStartTime` is always < `effectiveEndTime` (returns nil or skips if not)
- [ ] Export skips segments with invalid time ranges instead of crashing
- [ ] Concurrent exports are prevented (serial guard or actor)
- [ ] Partial output files are cleaned up on export failure (all paths)
- [ ] Existing tests pass
- [ ] Build succeeds

---

### PR5: Performance Fixes (Object Reuse + SportDetector Cleanup)

**Goal:** Eliminate per-frame allocations and fix SportDetector resource leak.

**Files:**
- `Features/Processing/VideoProcessor.swift` — create `MovementClassifier` and `TrajectoryQualityScore` once before the frame loop, reuse across frames
- `Features/Processing/Logic/SportDetector.swift` — add `CMSampleBufferInvalidate()` for each frame, add logging for detection failures (instead of silent `.beach` fallback)
- `Features/Processing/Logic/BallisticsGate.swift` — accept pre-created classifier/scorer instead of allocating per call

**Acceptance Criteria:**
- [ ] `MovementClassifier` and `TrajectoryQualityScore` are allocated once per processing run
- [ ] SportDetector releases sample buffers via `CMSampleBufferInvalidate()`
- [ ] SportDetector logs why it fell back to beach (no track, zero duration, etc.)
- [ ] No change in processing output (same rally detection results)
- [ ] Existing tests pass (BallisticsGate tests may need updated initialization)
- [ ] Build succeeds

---

### PR6: Processing Pipeline Unit Tests

**Goal:** Add test coverage for the untested critical paths.

**Files:**
- NEW: `BumpSetCutTests/Processing/ProcessVideoViewModelTests.swift` — test state machine transitions, error classification, cancel handling
- NEW: `BumpSetCutTests/Processing/ProcessingEventLogTests.swift` — test event emission and serialization
- Existing: update any tests broken by PRs 1-5

**Acceptance Criteria:**
- [ ] ProcessVideoViewModel state transitions tested (all 7 states)
- [ ] Error classification tested (each ProcessingError maps to correct UI)
- [ ] Cancel handling tested (state resets correctly)
- [ ] ProcessingEventLog serialization round-trips correctly
- [ ] All existing tests still pass
- [ ] Build succeeds

---

## 5. PR Dependency Order

```
PR1 (atomic writes + error taxonomy)
  └─→ PR2 (structured event log) — uses new error types
       └─→ PR3 (state machine + reader lifecycle) — emits events
            └─→ PR6 (tests) — tests final state machine + events

PR4 (export safety) — independent, can parallel with PR2/PR3
PR5 (performance) — independent, can parallel with PR2/PR3
```

Recommended merge order: PR1 → PR4 → PR5 → PR2 → PR3 → PR6

---

## 6. What This Plan Does NOT Cover (Out of Scope)

- Checkpointing / resume for interrupted processing (too large, separate epic)
- Retry logic for transient failures (premature without event data)
- VideoProcessor actor isolation refactor (breaking change, needs separate design)
- MetricsCollector revival (dead code — decide later if structured events replace it)
- End-to-end integration tests requiring real video files
- `peakMemoryUsageMB` / `cpuUsagePercent` actual measurement (nice-to-have, not critical)
