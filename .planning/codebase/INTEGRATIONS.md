# External Integrations

**Analysis Date:** 2026-01-24

## APIs & External Services

**None:**
- No external API integrations detected
- App operates entirely offline with local storage

## Data Storage

**Databases:**
- Local filesystem only (no database server)
  - Connection: File-based JSON manifests
  - Client: Native FileManager API
  - Location: Application Support directory at `~/Library/Application Support/BumpSetCut/`

**File Storage:**
- Local filesystem only
  - Videos stored in `BumpSetCut/SavedGames/` and `BumpSetCut/ProcessedGames/`
  - Metadata stored as JSON manifests (`folder_manifest.json`, `library_manifest.json`)
  - Debug data stored in `.debug_data/` directory with UUID-based naming
  - Implemented via `MediaStore` class in `BumpSetCut/Core/Storage/MediaStore.swift`

**Caching:**
- In-memory caches for video playback and thumbnails
  - RallyPlayerCache: AVPlayer instance pooling (`BumpSetCut/Features/RallyPlayback/Services/RallyPlayerCache.swift`)
  - RallyThumbnailCache: UIImage thumbnail caching (`BumpSetCut/Features/RallyPlayback/Services/RallyThumbnailCache.swift`)

## Authentication & Identity

**Auth Provider:**
- None (standalone local app)
  - Implementation: No authentication system

## Monitoring & Observability

**Error Tracking:**
- None (local logging only)

**Logs:**
- iOS Unified Logging System (os.log)
  - Logger instances in various subsystems (e.g., `Logger(subsystem: "BumpSetCut", category: "FolderManager")`)
  - Print statements for debug output during video processing

## CI/CD & Deployment

**Hosting:**
- iOS App (likely TestFlight/App Store distribution, not web-hosted)

**CI Pipeline:**
- None detected (manual Xcode builds)

## Environment Configuration

**Required env vars:**
- None

**Secrets location:**
- No secrets required
- CoreML model bundled in app resources
- Development Team ID hardcoded in project file (2J4SZTDKKP)

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

## Platform Integrations

**iOS System Integrations:**

**PhotosPicker (PhotosUI):**
- Purpose: Import videos from user's photo library
- Usage: `PhotosPicker` component with `VideoTransferable` for memory-efficient imports
- Files: `BumpSetCut/Services/UploadCoordinator.swift`, `BumpSetCut/Features/Library/Upload/DropZoneView.swift`

**Photos Framework:**
- Purpose: Export processed videos to user's photo library
- Usage: `PHPhotoLibrary.shared().performChanges` for saving videos
- Files: `BumpSetCut/Features/Export/VideoExporter.swift`

**AVAudioSession:**
- Purpose: Configure audio playback for videos
- Configuration: `.playback` category with `.moviePlayback` mode
- Files: `BumpSetCut/App/BumpSetCutApp.swift`

**Notification Center:**
- Purpose: Internal app-wide event coordination
- Events: `.libraryContentChanged`, upload notifications
- Files: `BumpSetCut/Core/Storage/MediaStore.swift`, `BumpSetCut/Extensions/NotificationName+Upload.swift`

**CoreML Model:**
- Model: `bestv2.mlpackage` (YOLO volleyball detection)
- Location: `BumpSetCut/Resources/ML/bestv2.mlpackage`
- Compute: ANE/GPU acceleration via `MLModelConfiguration.computeUnits = .all`
- Integration: `BumpSetCut/Core/ML/YOLODetector.swift`, `BumpSetCut/Core/ML/MLService.swift`
- Note: App functions without model but AI features disabled

---

*Integration audit: 2026-01-24*
