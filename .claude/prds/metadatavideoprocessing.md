---
name: metadatavideoprocessing
description: Store AI video analysis results as metadata instead of exporting full annotated videos
status: backlog
created: 2025-09-13T14:51:24Z
---

# PRD: Metadata Video Processing

## Executive Summary

This feature introduces a metadata-based video processing workflow to replace redundant full-video exports after AI analysis. The system will save key volleyball insights (rally timestamps, ball trajectory, ML confidence) as structured metadata tied to each original video file. Annotated videos will be exportable only in debug mode for internal verification.

## Problem Statement

### What problem are we solving?

Currently, the AI processing pipeline exports new video files to reflect segmentation or tracking, which results in:
- **Storage Bloat**: Redundant files per user session consuming device storage
- **Performance Impact**: Slower user experience due to unnecessary file I/O
- **Workflow Inefficiency**: Recomputation required for simple playback use cases
- **User Confusion**: Multiple video versions making organization difficult

### Why is this important now?

With BumpSetCut's advanced detection logic and comprehensive testing complete, users are processing more videos and experiencing storage limitations. The current approach doesn't scale efficiently as video libraries grow.

## User Stories

### Primary User Personas

**Coach Sarah** - High school volleyball coach
- Processes 10-15 game videos per week
- Needs quick rally review without storage concerns
- Values consistent performance across sessions

**Player Development Analyst** - Club volleyball coordinator
- Analyzes 20+ videos for player improvement
- Requires precise rally timestamps and trajectory data
- Needs to share insights without large file transfers

### Detailed User Journeys

**Rally Review Workflow:**
1. User opens processed video in BumpSetCut
2. System loads associated metadata (rally segments, ball paths)
3. User taps "Rally Review" to enter swipe-based navigation
4. Each rally plays with dynamic overlays rendered from metadata
5. User can jump between rallies instantly without file switching

**Debug Analysis Workflow:**
1. Developer processes test video with new algorithm
2. Metadata captures detailed trajectory and confidence data
3. Developer enables debug mode and exports annotated video
4. Annotated export includes visual overlays for validation
5. Developer iterates on algorithm parameters using metadata insights

### Pain Points Being Addressed

- **Storage Management**: Eliminates need for multiple video copies
- **Performance Lag**: Instant rally switching vs. video file loading
- **Organization Chaos**: Single source of truth per original video
- **Sharing Friction**: Lightweight metadata vs. large video transfers

## Requirements

### Functional Requirements

**Core Metadata Management:**
- Store rally timestamps, ball trajectories, and ML confidence scores as structured JSON
- Link metadata to original video via UUID for integrity
- Support metadata versioning for schema evolution
- Provide metadata export/import capabilities

**Runtime Playback Features:**
- Rally-by-rally navigation using metadata timestamps
- Dynamic overlay rendering (ball paths, court highlights, confidence scores)
- Seamless seek-to-rally functionality with AVPlayer integration
- Real-time metadata updates during processing

**Debug Mode Capabilities:**
- Export fully annotated videos with burned-in overlays (debug builds only)
- Include trajectory lines, rally boundaries, and ML confidence visualization
- Generate debug exports to `/Documents/DebugExports/` directory
- Provide developer toggle in Settings → Debug Tools

### Non-Functional Requirements

**Performance Expectations:**
- Metadata loading: <100ms for typical video (9-minute duration)
- Rally switching: <200ms seek time between segments
- Overlay rendering: 60fps during playback
- Storage efficiency: <50KB metadata per video

**Scalability Needs:**
- Support video libraries up to 500 videos
- Handle rally counts up to 50 per video
- Graceful degradation for corrupted metadata files
- Efficient metadata indexing for search operations

**Security Considerations:**
- Metadata stored in app sandbox (no external access)
- UUID-based video linking prevents accidental associations
- Debug exports disabled in release builds
- No sensitive user data in metadata schema

## Success Criteria

### Measurable Outcomes

| Metric | Target | Measurement Method |
|--------|--------|--------------------|
| Storage Reduction | 60% fewer duplicate files | File system analysis |
| Performance Improvement | 3x faster rally switching | A/B testing with current workflow |
| User Retention | 15% increase in daily active usage | Analytics tracking |
| Processing Accuracy | No regression in rally detection | Automated testing suite |

### Key Performance Indicators

- **Rally Review Engagement**: Time spent in rally-by-rally mode
- **Storage Efficiency**: Average storage per processed video
- **Debug Export Usage**: Developer adoption of annotated exports
- **Metadata Integrity**: Success rate of metadata loading operations

## Constraints & Assumptions

### Technical Limitations

- iOS AVPlayer seek precision (~33ms frame accuracy)
- SwiftUI Canvas performance on older devices (iPhone 12 and earlier)
- JSON file size limits for complex trajectory data
- Core Data migration complexity for existing video libraries

### Timeline Constraints

- **Phase 1**: Basic metadata storage and rally playback (4 weeks)
- **Phase 2**: Debug export and advanced overlays (3 weeks)
- **Phase 3**: Metadata editing and optimization (2 weeks)

### Resource Limitations

- Single iOS developer for implementation
- Limited QA time for comprehensive device testing
- No backend infrastructure for metadata sync

### Key Assumptions

- Users prefer instant rally switching over file-based workflow
- Metadata corruption will be rare with UUID linking
- Debug exports will primarily serve internal development needs
- Storage efficiency gains will improve user satisfaction

## Out of Scope

### Explicitly NOT Building

- **Multi-device sync**: iCloud or server-based metadata synchronization
- **Video editing capabilities**: Trimming, merging, or modifying original videos
- **Advanced metadata analytics**: Aggregate statistics or trend analysis
- **Third-party integrations**: Export to coaching software or social platforms
- **Real-time collaboration**: Shared metadata editing or commenting features

### Future Considerations

- Cloud-based metadata backup and restore
- Advanced search using metadata attributes
- Automated highlight reel generation from metadata
- Integration with external volleyball analytics platforms

## Dependencies

### External Dependencies

- **AVFoundation**: Video playback and seek functionality
- **CoreGraphics**: Overlay rendering and trajectory visualization
- **SwiftUI Canvas**: Performance-optimized drawing operations
- **Foundation**: JSON encoding/decoding and file management

### Internal Team Dependencies

- **Domain Layer**: Enhanced VideoProcessor metadata generation
- **Data Layer**: MediaStore integration for metadata persistence
- **Infrastructure Layer**: File system utilities and UUID management
- **Testing Team**: Comprehensive metadata validation and performance testing

### Technical Prerequisites

- Completion of detection logic upgrades (✅ Complete)
- Stable video processing pipeline (✅ Complete)
- Comprehensive test coverage framework (✅ Complete)
- Debug visualization system (✅ Complete)

## Technical Architecture

### Metadata Schema (v1.0)

```json
{
  "video_id": "A9D2FF8C-9B4F-4B3B-AF76-1234567890AB",
  "original_filename": "2024-09-12_volleyball_game.mov",
  "duration": 163.3,
  "processing_version": "v1.2.0",
  "processed_at": "2025-09-13T10:44:22Z",
  "rallies": [
    {
      "id": "rally_001",
      "start_time": 4.1,
      "end_time": 12.3,
      "confidence": 0.94,
      "ball_trajectory": [
        {"frame": 102, "timestamp": 4.12, "x": 188, "y": 402, "confidence": 0.89},
        {"frame": 103, "timestamp": 4.15, "x": 190, "y": 398, "confidence": 0.91}
      ],
      "rally_quality": "high",
      "projectile_phases": [
        {"start_time": 6.2, "end_time": 8.1, "trajectory_type": "serve"},
        {"start_time": 9.3, "end_time": 11.8, "trajectory_type": "spike"}
      ]
    }
  ],
  "court_detection": {
    "court_bounds": {"x": 50, "y": 120, "width": 820, "height": 640},
    "net_position": {"x": 435, "y": 380},
    "detection_confidence": 0.87
  },
  "processing_stats": {
    "total_frames": 9798,
    "processed_frames": 3266,
    "detection_rate": 0.33,
    "average_confidence": 0.82
  }
}
```

### Storage Implementation

**File System Approach:**
- Location: `/ApplicationSupport/ProcessedMetadata/{video_id}.json`
- Atomic writes to prevent corruption during processing
- Automatic backup creation before metadata updates
- Efficient file watching for metadata changes

### Runtime Integration

**VideoProcessor Enhancement:**
```swift
class VideoProcessor: ObservableObject {
    func processVideo(_ video: VideoMetadata) async throws -> ProcessingMetadata {
        // Enhanced processing pipeline
        let rallies = await detectRallies(in: video)
        let trajectories = await trackBallMovement(in: video)
        let metadata = ProcessingMetadata(
            videoId: video.id,
            rallies: rallies,
            trajectories: trajectories
        )
        try await metadataStore.save(metadata)
        return metadata
    }
}
```

**Rally Player View:**
```swift
struct RallyPlayerView: View {
    @StateObject private var player: AVPlayer
    @State private var metadata: ProcessingMetadata

    var body: some View {
        VideoPlayerView(player: player)
            .overlay(BallTrajectoryOverlay(metadata: metadata))
            .gesture(swipeGesture)
    }

    private func jumpToRally(_ index: Int) {
        let rally = metadata.rallies[index]
        player.seek(to: CMTime(seconds: rally.startTime, preferredTimescale: 600))
    }
}
```

### Debug Export Pipeline

**Annotated Video Generation:**
```swift
#if DEBUG
class DebugVideoExporter {
    func exportAnnotatedVideo(_ metadata: ProcessingMetadata) async throws -> URL {
        let asset = AVAsset(url: metadata.originalVideoURL)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: debugOutputURL, fileType: .mov)

        // Process each frame with overlays
        while let sampleBuffer = reader.read() {
            let annotatedFrame = addOverlays(to: sampleBuffer, using: metadata)
            writer.append(annotatedFrame)
        }

        return debugOutputURL
    }
}
#endif
```