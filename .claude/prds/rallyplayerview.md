---
name: rallyplayerview
description: Enhanced video player with rally-by-rally navigation and real-time metadata overlays for volleyball analysis
status: backlog
created: 2025-09-15T17:49:39Z
---

# PRD: RallyPlayerView

## Executive Summary

RallyPlayerView is a specialized video player component for BumpSetCut that transforms the volleyball video analysis experience. Instead of exporting large annotated video files, it provides real-time metadata overlays on original videos, enabling rally-by-rally navigation with 60% storage reduction while maintaining full analytical capabilities.

**Value Proposition:** Deliver professional-grade volleyball analysis tools with instant rally access, real-time trajectory visualization, and zero storage overhead.

## Problem Statement

### Current Pain Points
1. **Storage Inefficiency**: Traditional annotated video exports create 2-3x file size increase, consuming device storage unnecessarily
2. **Poor Navigation**: Linear video playback forces users to scrub through dead time to find specific rallies
3. **Static Analysis**: Pre-rendered annotations cannot be toggled or customized during playback
4. **Performance Issues**: Large video files cause slow loading and poor seek performance
5. **Limited Interactivity**: No real-time confidence indicators or trajectory details during playback

### Why Now?
- BumpSetCut's ML processing pipeline now generates rich metadata (trajectories, confidence scores, rally boundaries)
- SwiftUI Canvas enables high-performance real-time rendering (60fps)
- Users increasingly need quick access to specific rallies for coaching and analysis
- Storage limitations on mobile devices require more efficient solutions

## User Stories

### Primary Personas

**Coach Sarah** - High school volleyball coach
- Needs quick access to specific rallies during team meetings
- Wants to show/hide different overlay elements based on discussion focus
- Values fast, responsive navigation during live presentations

**Player Mike** - Competitive volleyball player
- Reviews his own gameplay to identify improvement areas
- Needs detailed trajectory analysis with confidence indicators
- Wants seamless rally-to-rally comparison

**Analyst Emma** - Performance analyst
- Requires precise frame-by-frame analysis capabilities
- Needs overlay customization for different analysis types
- Values data accuracy and performance metrics

### Detailed User Journeys

#### Rally Navigation Flow
1. User opens processed video in BumpSetCut
2. System automatically loads to RallyPlayerView (if metadata exists)
3. Video starts at first rally with overlay elements visible
4. User swipes left/right or taps navigation controls to move between rallies
5. System seeks to rally start with <200ms response time
6. User can toggle overlay elements on/off during playback

#### Analysis Flow
1. User selects specific rally for detailed analysis
2. System displays trajectory paths with confidence-based coloring
3. User scrubs through rally to see frame-by-frame ball movement
4. Confidence indicators update in real-time with video position
5. User can compare multiple rallies using gesture navigation

### Pain Points Being Addressed
- **"I can't find the rally I want quickly"** → Rally-by-rally navigation
- **"The video files are too large"** → Metadata-based overlays (60% reduction)
- **"I can't see trajectory details clearly"** → High-contrast, customizable overlays
- **"Seeking is too slow"** → Optimized seek performance (<200ms)
- **"I need more control over what I see"** → Toggle controls for all overlay elements

## Requirements

### Functional Requirements

#### Core Video Playback
- **FR-1**: Display original video with AVPlayer integration
- **FR-2**: Support standard playback controls (play/pause/seek)
- **FR-3**: Maintain audio synchronization during rally transitions
- **FR-4**: Handle video loading states and errors gracefully

#### Rally Navigation
- **FR-5**: Provide rally-by-rally navigation with visual indicators
- **FR-6**: Support gesture controls (swipe left/right for rally navigation)
- **FR-7**: Show current rally position (e.g., "Rally 2 of 5")
- **FR-8**: Enable direct rally selection via tap controls
- **FR-9**: Auto-seek to rally start positions with <200ms latency

#### Metadata Overlays
- **FR-10**: Render ball trajectories in real-time using SwiftUI Canvas
- **FR-11**: Display confidence indicators with color-coded visualization
- **FR-12**: Show rally boundary markers (start/end times)
- **FR-13**: Support trajectory history (2-second trailing path)
- **FR-14**: Provide toggle controls for each overlay type

#### User Interface
- **FR-15**: Responsive design for different screen orientations
- **FR-16**: Intuitive overlay control panel
- **FR-17**: Visual feedback for rally transitions
- **FR-18**: Error states for missing metadata
- **FR-19**: Loading states during video preparation

#### Data Integration
- **FR-20**: Load metadata from MetadataStore service
- **FR-21**: Support backwards compatibility with non-processed videos
- **FR-22**: Handle metadata versioning gracefully
- **FR-23**: Validate metadata integrity before rendering

### Non-Functional Requirements

#### Performance
- **NFR-1**: Maintain 60fps rendering for overlay elements
- **NFR-2**: Rally seek operations complete within 200ms
- **NFR-3**: Memory usage remains under 150MB during playback
- **NFR-4**: Support videos up to 4K resolution without performance degradation

#### User Experience
- **NFR-5**: Overlay rendering accuracy within 5px of actual ball position
- **NFR-6**: Gesture recognition response time under 50ms
- **NFR-7**: UI remains responsive during intensive overlay calculations
- **NFR-8**: Smooth animations for rally transitions (0.2s duration)

#### Reliability
- **NFR-9**: Handle metadata corruption gracefully without crashes
- **NFR-10**: Recover from video loading failures with user feedback
- **NFR-11**: Maintain overlay synchronization throughout video duration
- **NFR-12**: Support offline playback when metadata is locally cached

#### Scalability
- **NFR-13**: Support metadata files up to 100MB (complex trajectories)
- **NFR-14**: Handle videos with up to 20 rallies efficiently
- **NFR-15**: Coordinate system transformation scales to any video resolution

## Success Criteria

### User Adoption Metrics
- **90%** of users with processed videos use RallyPlayerView instead of standard player
- **80%** reduction in user-reported "can't find rally" support requests
- **95%** user satisfaction score for rally navigation speed

### Performance Metrics
- Rally seek operations complete in **<200ms** (95th percentile)
- Overlay rendering maintains **60fps** during playback (99% uptime)
- Memory usage stays below **150MB** during typical use
- App crash rate related to video playback **<0.1%**

### Storage & Efficiency
- **60%** reduction in storage usage vs traditional annotated videos
- **100%** of processed videos support metadata overlays
- **<5s** time-to-first-rally for videos under 10 minutes

### User Experience
- Gesture recognition accuracy **>95%** for rally navigation
- Overlay element toggle response time **<100ms**
- Rally transition smoothness rated **>4.5/5** by users

## Constraints & Assumptions

### Technical Constraints
- **iOS Platform**: SwiftUI and AVFoundation limitations
- **Device Performance**: Must work on iPhone 12 and newer for optimal experience
- **Video Formats**: Limited to formats supported by AVPlayer (MP4, MOV)
- **Metadata Size**: JSON metadata files should remain under 100MB

### Timeline Constraints
- **MVP Target**: 4 weeks for core functionality
- **Full Feature Set**: 8 weeks including all overlay options
- **Testing Phase**: 2 weeks for performance optimization and bug fixes

### Resource Limitations
- **Single Developer**: UI and integration work
- **Testing Devices**: Limited to iPhone/iPad simulator and 2 physical devices
- **Video Assets**: Test with existing volleyball footage only

### Assumptions
- Users have processed videos with valid metadata available
- MetadataStore service provides reliable metadata access
- Video files are stored locally on device (not streaming)
- Users understand basic video player interactions

## Out of Scope

### Explicitly NOT Building
- **Video Editing**: No trimming, cutting, or modification capabilities
- **Export Features**: No re-export or sharing of rally segments
- **Multi-Video Analysis**: No side-by-side comparison of different videos
- **Live Streaming**: No real-time video analysis during recording
- **Social Features**: No sharing, commenting, or collaborative analysis
- **Advanced Analytics**: No statistical analysis or trend reporting
- **Custom Metadata**: No user-generated annotations or markers
- **Video Filters**: No color correction, speed adjustment, or visual filters

### Future Considerations
- Slow-motion rally playback
- Frame-by-frame analysis tools
- Rally bookmarking and notes
- Gesture customization
- Advanced trajectory analytics

## Dependencies

### Internal Dependencies
- **MetadataStore Service**: Reliable metadata loading and caching
- **ProcessingMetadata Models**: Consistent data structure for trajectories and rally segments
- **VideoProcessor**: Continued generation of high-quality metadata
- **UI Framework**: SwiftUI Canvas performance and stability

### External Dependencies
- **AVFoundation**: Video playback, seeking, and time observation
- **CoreGraphics**: Coordinate transformations and overlay rendering
- **SwiftUI**: Canvas rendering and gesture recognition
- **iOS Platform**: Core Media framework for time-based operations

### Data Dependencies
- **Video Files**: Original video files must be accessible locally
- **Metadata Files**: JSON metadata must be valid and version-compatible
- **Storage Access**: Read access to app's document directory structure

### Performance Dependencies
- **Device Hardware**: GPU performance for 60fps overlay rendering
- **iOS Version**: iOS 16+ for optimal SwiftUI Canvas performance
- **Available Memory**: Sufficient RAM for video + metadata + overlay rendering

## Technical Architecture

### Component Structure
```
RallyPlayerView
├── VideoPlayerLayer (AVPlayer integration)
├── MetadataOverlayView (Canvas-based rendering)
├── RallyNavigationControls (UI controls)
├── OverlayTogglePanel (Settings panel)
└── ErrorHandlingWrapper (Graceful degradation)
```

### Data Flow
1. Load video metadata from MetadataStore
2. Initialize AVPlayer with original video URL
3. Set up time observer for overlay synchronization
4. Filter relevant trajectories based on current playback time
5. Transform coordinates and render overlays on Canvas
6. Handle rally navigation through seek operations

### Performance Optimizations
- Lazy loading of trajectory data outside current time window
- Coordinate transformation caching
- Memory-efficient overlay rendering
- Optimized seek operations using CMTime precision

---

**Ready for Implementation**: This PRD provides comprehensive requirements for building a professional-grade rally player that transforms how users analyze volleyball videos, delivering immediate value through efficient navigation and rich visual feedback.