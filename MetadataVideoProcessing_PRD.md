# MetadataVideoProcessing PRD

# 1. Summary

This feature introduces a metadata-based video processing workflow to replace redundant full-video exports after AI analysis. The system will save key volleyball insights (e.g., rally timestamps, ball trajectory, ML confidence) as structured metadata tied to each original video file. Annotated videos will be exportable only in debug mode for internal verification.

---

## 2. Core Problem

Currently, the AI processing pipeline exports new video files to reflect segmentation or tracking, which results in:
- Redundant files per user session
- Increased storage usage
- Slower user experience
- Unnecessary recomputation for simple playback use cases

This feature solves that by decoupling analysis from video exports. AI results will persist as metadata, enabling lightweight rally review, player tracking, and analysis.

---

## 3. Goals & Success Criteria

| Goal | Success Criteria |
|------|------------------|
| Save AI results as metadata | Users can play back segmented rallies without needing new video files |
| Enable rally-by-rally playback | Swipe-based review view renders each rally dynamically |
| Annotated video export (debug only) | Devs can generate videos with overlaid ball paths, rally boxes, etc. |
| Maintain performance | No regression in app responsiveness or file IO |
| Clear separation between metadata and raw media | Original videos remain unmodified |

---

## 4. Scope

### ✅ In Scope
- Rally timestamps, ball trajectories, ML scores stored as `.json` or Core Data
- Runtime overlay drawing using this metadata
- Optional export of annotated video (debug mode only)
- Metadata editor for tweaking rally boundaries (TBD)

### ❌ Out of Scope
- Editing video content directly
- Multi-user sync or iCloud sharing (future)
- Full export UI for end-users (initial release targets internal tooling)

---

## 5. Metadata Schema (v1)

```json
{
  "video_id": "A9D2FF8C-9B4F-4B3B-AF76-1234567890AB",
  "original_filename": "2024-09-12_1232.mov",
  "duration": 163.3,
  "rallies": [
    {
      "start_time": 4.1,
      "end_time": 12.3,
      "ball_path": [
        {"frame": 102, "x": 188, "y": 402},
        {"frame": 103, "x": 190, "y": 398}
      ],
      "confidence": 0.94
    }
  ],
  "processing_version": "v1.1.2",
  "processed_at": "2025-09-13T10:44:22Z"
}
```

## 6. User Experience

| Interaction                | Behavior                                                                 |
|----------------------------|--------------------------------------------------------------------------|
| **Open video**             | Loads associated metadata if present                                     |
| **Tap "Rally Review"**     | Opens swipe-based rally-by-rally review view                             |
| **Tap "Debug Export"**     | (Dev only) Exports annotated video with ball trajectory + overlays       |
| **Rally overlay view**     | Uses metadata to draw ball paths, court highlights, rally timestamps     |
| **Edit rally** *(Future)*  | Allows user to fine-tune rally timestamps (start/end) via UI             |

---

## 7. Technical Architecture

### 📦 Storage
- Metadata stored as `.json` file in the app's sandbox directory alongside original video
  - e.g. `/ApplicationSupport/ProcessedMetadata/{video_id}.json`
- Alternative: Core Data model with a `VideoMetadata` entity for richer querying (TBD)

### ⚙️ Processing Flow
- `VideoProcessor.swift` generates metadata upon successful AI analysis:
  - Rally segmentation timestamps
  - Ball trajectories (frame → (x, y))
  - Confidence scores
- Metadata is attached to the `VideoEntry` object in app memory for UI binding

### 📺 Playback
- `RallyPlayerView` reads from metadata's `rallies[]` array
- Uses `AVPlayer.seek(to:)` for playback from `start_time → end_time`
- Ball paths and overlays rendered with:
  - `SwiftUI.Canvas` for performance + declarative layout
  - Or `CALayer` for precise frame-level control

---

## 8. Debug Mode: Annotated Export

### 🎯 Purpose
To aid internal QA and model debugging, we enable exporting a fully annotated video (burned-in overlays) only when the app is in **debug mode**.

### 🔧 Functionality
- Use `AVAssetReader` and `AVAssetWriter` to read each frame, draw overlays, and write to a new `.mov`
- Overlays include:
  - Ball trajectory lines/circles per frame
  - Rally start/end highlights (boxes, timestamps)
  - Model confidence scores (text overlay)
- Exported file path:
  `/Documents/DebugExports/{video_id}_annotated.mov`

### ⚠️ Notes
- Disabled in Release builds
- Uses same metadata schema as runtime overlay playback
- Option available via dev toggle in `Settings → Debug Tools → Export Annotated Video`

---

## 9. Risks & Mitigations

| Risk                                                  | Mitigation                                                                 |
|--------------------------------------------------------|----------------------------------------------------------------------------|
| **Large metadata files** (e.g. ball path per frame)    | Limit saved points to keyframes or downsample path density                 |
| **Metadata desync from video edits**                   | Use `UUID` to link metadata to specific unmodified video asset             |
| **User confusion about invisible processing state**    | Add "AI Processed" badge on video card if metadata is available            |
| **Too much dev time spent on export UI**               | Gate debug exports behind a developer-only toggle; don't polish for prod   |
| **Breaking changes to metadata schema**                | Add `processing_version` to schema and write forward-compatible loaders    |