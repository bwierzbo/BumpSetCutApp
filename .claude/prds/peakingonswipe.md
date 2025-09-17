---
name: peakingonswipe
description: Preview next/previous rally clips during swipe gestures for smoother navigation
status: backlog
created: 2025-09-17T00:25:47Z
---

# PRD: Peeking on Swipe

## Executive Summary

Enhance the TikTok-style rally player with visual peeking functionality that shows static frames of adjacent rally clips during swipe gestures. This creates a seamless, Tinder-like navigation experience where users see the next video appearing as they swipe, eliminating the jarring transition from current video to black screen to next video.

## Problem Statement

**Current Issue**: Users experience a disjointed navigation flow when swiping between rally clips. The current implementation shows the current video, then nothing (black screen) during the swipe gesture, then suddenly displays the next video after the swipe completes and the video loads.

**User Impact**: This creates an abrupt, non-intuitive experience that breaks the smooth, engaging flow expected in modern swipe-based interfaces like TikTok and Tinder.

**Why Now**: With the TikTok-style rally player now implemented, this enhancement represents the missing piece for creating a truly polished, professional swipe navigation experience that matches user expectations from leading social media apps.

## User Stories

### Primary Persona: Volleyball Player/Coach Using Rally Review

**User Story 1: Smooth Rally Navigation**
- **As a** volleyball player reviewing rally clips
- **I want** to see the next rally appearing as I swipe
- **So that** I have a smooth, predictable navigation experience without jarring transitions

**Acceptance Criteria:**
- When I start swiping, the next rally's first frame becomes visible
- The transition is smooth and follows my finger movement
- The experience is consistent across both portrait (vertical) and landscape (horizontal) orientations

**User Story 2: Visual Preview During Decision**
- **As a** coach browsing through rally clips
- **I want** to see a preview of the next rally while swiping
- **So that** I can decide whether to continue to that rally or return to the current one

**Acceptance Criteria:**
- Static frame preview shows enough detail to identify the rally content
- Preview appears at an appropriate threshold (not too sensitive, not too late)
- I can return to the current rally by releasing the swipe

**User Story 3: Consistent Gesture Experience**
- **As a** user familiar with modern mobile apps
- **I want** the swipe behavior to match expectations from apps like Tinder
- **So that** the interface feels intuitive and professional

**Acceptance Criteria:**
- Peeking works with existing Tinder-style rotation animations
- No performance degradation or stuttering during peek transitions
- Visual consistency with the current rally player design

## Requirements

### Functional Requirements

**FR1: Visual Peeking**
- Display static frame (first frame) of next/previous rally clip during swipe gesture
- Preview frame appears proportionally to swipe progress
- Support both forward and backward peeking (next/previous rallies)

**FR2: Gesture Integration**
- Integrate with existing Tinder-style swipe gestures and rotation animations
- Maintain current swipe threshold requirements for completing navigation
- Support both vertical (portrait) and horizontal (landscape) swipe directions

**FR3: Performance Management**
- Extract first frame on-demand during swipe gesture
- No preloading of video previews to maintain current memory optimization
- Smooth 60fps animation during peek transitions

**FR4: Visual Consistency**
- Preview frames sized and positioned to match current video dimensions
- Consistent visual styling with existing rally player interface
- Proper handling of different video aspect ratios

### Non-Functional Requirements

**NFR1: Performance**
- First frame extraction must complete within 100ms to avoid lag
- Memory usage increase should not exceed 10MB for frame caching
- No impact on existing sliding window memory limits

**NFR2: Responsiveness**
- Peek animation should maintain 60fps during gesture
- No noticeable delay between swipe start and peek appearance
- Smooth transition back to original state on gesture cancellation

**NFR3: Compatibility**
- Compatible with existing Swift 6 concurrency patterns
- Works with current AVPlayer management and cleanup system
- Maintains compatibility with current video processing pipeline

## Success Criteria

### Primary Metrics
- **User Engagement**: 20% increase in rally navigation frequency (swipes per session)
- **User Satisfaction**: Improved app store ratings mentioning navigation smoothness
- **Technical Performance**: No increase in memory warnings or crashes during navigation

### Secondary Metrics
- **Animation Smoothness**: Consistent 60fps during peek animations (measured via Instruments)
- **Memory Efficiency**: Frame extraction memory usage stays under 10MB peak
- **Error Rate**: Zero crashes related to peek functionality in production

### User Experience Validation
- **A/B Testing**: Compare navigation behavior with/without peeking feature
- **User Feedback**: Collect feedback on navigation smoothness and intuitiveness
- **Performance Testing**: Validate smooth operation across iPhone models (iPhone 12+)

## Technical Design

### Architecture Integration

**Component Interaction:**
- Extend existing `TikTokRallyPlayerView` gesture handling
- Add frame extraction service to `VideoExporter` or create new `FrameExtractor`
- Integrate with current `VideoPlayerManager` for rally metadata access

**Data Flow:**
1. User initiates swipe gesture
2. Gesture recognizer triggers peek threshold
3. Frame extractor gets first frame of target rally
4. UI updates to show peek preview alongside current video
5. Gesture completion triggers normal navigation flow

### Implementation Approach

**Phase 1: Frame Extraction Service**
- Create `FrameExtractor` utility for on-demand first frame extraction
- Implement async frame extraction with proper error handling
- Add caching for recently extracted frames (LRU cache, max 5 frames)

**Phase 2: Gesture Enhancement**
- Modify existing swipe gesture recognizers to support peek callbacks
- Add peek state management to track current peek progress
- Implement smooth animation between current video and peek frame

**Phase 3: UI Integration**
- Extend rally player layout to support overlaid peek frames
- Add proper z-index management for current video vs peek preview
- Ensure proper cleanup of peek resources on navigation completion

## Constraints & Assumptions

### Technical Constraints
- Must work within current memory management limits (sliding window)
- Cannot preload video previews due to memory constraints
- Must maintain existing AVPlayer cleanup patterns
- Should not impact current processing pipeline performance

### Design Constraints
- Must preserve existing Tinder-style rotation animations
- Preview frames must match current video player aspect ratio
- Cannot add haptic feedback (explicitly requested)
- Must work in both portrait and landscape orientations

### Timeline Constraints
- Implementation should build on existing rally player foundation
- Must not break current video processing or export functionality
- Should integrate cleanly with current Swift 6 concurrency patterns

### Resource Assumptions
- Users have sufficient device performance for smooth frame extraction (iPhone 12+)
- Rally clips are accessible for frame extraction without significant delay
- Current video metadata provides reliable access to adjacent rally information

## Out of Scope

### Explicitly Not Building
- **Video Preview Playback**: Only static frames, no video preview during peek
- **Haptic Feedback**: No tactile feedback during peeking gestures
- **Preloading System**: No background loading of preview frames
- **Metadata Preview**: No rally information overlay during peek
- **Custom Gesture Types**: Only standard swipe gestures, no new gesture patterns

### Future Considerations
- Advanced preview animations (fade, blur effects)
- Rally metadata overlay during peek
- Performance optimizations for older devices
- Customizable peek sensitivity settings

## Dependencies

### Internal Dependencies
- Current `TikTokRallyPlayerView` implementation
- Existing `VideoPlayerManager` and rally metadata system
- Current gesture handling and animation framework
- Memory management patterns (sliding window limits)

### External Dependencies
- AVFoundation for frame extraction
- CoreGraphics for frame manipulation and display
- SwiftUI animation system for smooth transitions
- Current MijickPopups framework (if needed for UI layering)

### Technical Dependencies
- iOS 17+ for @Observable pattern compatibility
- Swift 6 concurrency patterns
- Current CoreML and video processing pipeline (should not conflict)

## Risk Assessment

### High Risk
- **Performance Impact**: Frame extraction could cause UI stuttering
  - *Mitigation*: Async extraction with background queues, performance testing
- **Memory Leaks**: Improper frame cleanup could cause memory issues
  - *Mitigation*: Strict resource management, automated testing

### Medium Risk
- **Complex Animation Logic**: Coordinating peek with existing animations
  - *Mitigation*: Incremental implementation, thorough testing
- **Device Compatibility**: Older devices may struggle with frame extraction
  - *Mitigation*: Performance profiling, fallback graceful degradation

### Low Risk
- **User Experience**: Users may not notice or appreciate the enhancement
  - *Mitigation*: A/B testing, user feedback collection

## Success Definition

This feature will be considered successful when:

1. **Technical Success**: Frame extraction completes within 100ms with no memory leaks
2. **User Experience Success**: Smooth 60fps animations with no jarring transitions
3. **Adoption Success**: Increased user engagement with rally navigation features
4. **Quality Success**: No increase in crash rates or memory warnings
5. **Integration Success**: Seamless operation with existing rally player functionality

The peeking on swipe feature represents a critical enhancement to user experience, transforming the rally player from functional to truly polished and engaging.