---
name: metadatavideoprocessing
status: backlog
created: 2025-09-13T15:12:01Z
progress: 0%
prd: .claude/prds/metadatavideoprocessing.md
github: [Will be updated when synced to GitHub]
---

# Epic: Metadata Video Processing

## Overview

Transform BumpSetCut from generating redundant annotated videos to storing rich volleyball analysis metadata, enabling lightweight rally playback with runtime overlays. This leverages existing VideoProcessor and DebugAnnotator infrastructure while adding metadata persistence and rally-based navigation.

## Architecture Decisions

- **Metadata Storage**: JSON files in app sandbox (`/ApplicationSupport/ProcessedMetadata/`) for simplicity and performance
- **Schema Versioning**: Include `processing_version` field for backward compatibility
- **Video Linking**: UUID-based association to prevent metadata desync from video edits
- **Overlay Rendering**: Extend existing DebugAnnotator with SwiftUI Canvas for runtime visualization
- **Debug Exports**: Leverage existing debug pipeline, gate behind `#if DEBUG` compilation

## Technical Approach

### Frontend Components
- **Extend VideoMetadata Model**: Add `hasMetadata` computed property and metadata file path
- **RallyPlayerView**: New SwiftUI view for rally-by-rally navigation with gesture support
- **MetadataOverlayView**: SwiftUI Canvas component for real-time trajectory visualization
- **Enhance ProcessVideoView**: Remove "Export Video" toggle, add debug export option for development builds

### Backend Services
- **ProcessingMetadata Model**: Codable struct matching JSON schema with rally timestamps and trajectory data
- **MetadataStore Service**: File I/O operations with atomic writes and backup creation
- **Extend VideoProcessor**: Generate metadata instead of creating new video files for production mode
- **Debug Export Service**: Enhanced DebugAnnotator for annotated video generation (debug builds only)

### Infrastructure
- **File System Integration**: Extend existing MediaStore file management patterns
- **Error Handling**: Graceful degradation for missing/corrupted metadata files
- **Performance Optimization**: Lazy loading of metadata and efficient overlay rendering

## Implementation Strategy

### Phase 1: Core Metadata Infrastructure (Week 1-2)
- Create ProcessingMetadata model and MetadataStore service
- Modify VideoProcessor to generate metadata instead of video exports
- Implement basic metadata persistence with JSON encoding

### Phase 2: Rally Playback Interface (Week 2-3)
- Build RallyPlayerView with AVPlayer seek integration
- Create MetadataOverlayView using SwiftUI Canvas
- Add rally navigation with swipe gestures

### Phase 3: Debug Export & Polish (Week 3-4)
- Implement debug-only annotated video export
- Performance optimization and error handling
- Integration testing and UI polish

### Risk Mitigation
- **Metadata Corruption**: Atomic writes with backup creation
- **Performance Issues**: Lazy loading and efficient Canvas rendering
- **Backward Compatibility**: Schema versioning and graceful fallbacks

### Testing Approach
- Unit tests for ProcessingMetadata encoding/decoding
- Integration tests for metadata-video linking integrity
- Performance tests for rally switching and overlay rendering
- Manual testing of debug export functionality

## Task Breakdown Preview

High-level task categories that will be created:
- [ ] **Data Models**: ProcessingMetadata model and JSON schema implementation
- [ ] **Storage Layer**: MetadataStore service with file I/O operations
- [ ] **VideoProcessor Integration**: Modify processing pipeline to generate metadata
- [ ] **Rally Player Interface**: RallyPlayerView with navigation and overlays
- [ ] **Debug Export System**: Enhanced annotated video generation for debug builds
- [ ] **Performance Optimization**: Lazy loading and Canvas rendering optimization
- [ ] **Testing & Integration**: Comprehensive test coverage and integration validation

## Dependencies

### External Dependencies
- **AVFoundation**: Existing video playback and seek functionality
- **SwiftUI Canvas**: Overlay rendering (requires iOS 15+)
- **Foundation**: JSON encoding/decoding and file management

### Internal Dependencies
- **Existing VideoProcessor**: Rally detection and ball tracking algorithms ✅
- **Current DebugAnnotator**: Overlay visualization system ✅
- **MediaStore Infrastructure**: File management patterns ✅
- **VideoMetadata Model**: Current data model structure ✅

### Prerequisites
- Enhanced detection logic (✅ Complete)
- Comprehensive test framework (✅ Complete)
- Debug visualization system (✅ Complete)

## Success Criteria (Technical)

### Performance Benchmarks
- Metadata loading: <100ms for typical 9-minute video
- Rally switching: <200ms seek time between segments
- Overlay rendering: Maintain 60fps during playback
- Storage efficiency: <50KB metadata per processed video

### Quality Gates
- Zero regression in rally detection accuracy
- Backward compatibility with existing video libraries
- Graceful handling of corrupted metadata files
- Debug exports functionally equivalent to current debug videos

### Acceptance Criteria
- Users can navigate rallies without generating duplicate video files
- Runtime overlays accurately reflect ball trajectory and rally boundaries
- Debug exports provide comprehensive visualization for algorithm validation
- Storage usage reduced by 60% compared to current video export approach

## Estimated Effort

### Overall Timeline: 4 weeks
- **Week 1**: Data models and storage infrastructure
- **Week 2**: VideoProcessor integration and metadata generation
- **Week 3**: Rally player interface and overlay visualization
- **Week 4**: Debug export system and performance optimization

### Resource Requirements
- **Primary Developer**: 1 iOS developer (full-time)
- **Testing Support**: QA validation for performance and compatibility
- **Code Review**: Senior developer for architecture validation

### Critical Path Items
1. ProcessingMetadata model design and schema validation
2. VideoProcessor modification without breaking existing functionality
3. AVPlayer seek performance optimization for rally switching
4. SwiftUI Canvas overlay rendering performance tuning

## Implementation Notes

### Leveraging Existing Infrastructure
- **VideoProcessor**: Modify existing pipeline to output metadata instead of video files
- **DebugAnnotator**: Reuse overlay logic for both runtime display and debug export
- **MediaStore**: Extend current file management patterns for metadata persistence
- **Test Framework**: Use existing comprehensive test coverage patterns

### Simplified Approach
- **Single Storage Format**: JSON files (no Core Data complexity initially)
- **Minimal UI Changes**: Extend existing views rather than complete redesigns
- **Phased Rollout**: Incremental implementation maintaining backward compatibility
- **Debug-Only Exports**: Avoid complexity of production export UI

## Tasks Created
- [ ] 001.md - Create ProcessingMetadata Model and JSON Schema (parallel: true)
- [ ] 002.md - Implement MetadataStore Service (parallel: false)
- [ ] 003.md - Extend VideoMetadata Model with Metadata Support (parallel: false)
- [ ] 004.md - Modify VideoProcessor to Generate Metadata (parallel: false)
- [ ] 005.md - Create RallyPlayerView with Navigation (parallel: true)
- [ ] 006.md - Implement MetadataOverlayView with SwiftUI Canvas (parallel: true)
- [ ] 007.md - Implement Debug Export Service (parallel: true)

Total tasks: 7
Parallel tasks: 4
Sequential tasks: 3
Estimated total effort: 78 hours (approximately 4 weeks)