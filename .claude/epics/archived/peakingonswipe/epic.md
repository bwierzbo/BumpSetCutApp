---
name: peakingonswipe
status: completed
created: 2025-09-17T00:27:27Z
progress: 100%
prd: .claude/prds/peakingonswipe.md
github: https://github.com/bwierzbo/BumpSetCutApp/issues/39
---

# Epic: Peeking on Swipe

## Overview

Enhance the existing TikTok-style rally player with visual peeking functionality that displays static frame previews of adjacent rally clips during swipe gestures. This creates a seamless, Tinder-like navigation experience by leveraging existing gesture infrastructure and adding lightweight frame extraction capabilities.

## Architecture Decisions

- **Leverage Existing Infrastructure**: Build upon current `TikTokRallyPlayerView` and gesture handling rather than creating new systems
- **Minimal Frame Extraction**: Use AVFoundation's `AVAssetImageGenerator` for on-demand first frame extraction with LRU caching
- **SwiftUI Overlay Pattern**: Implement peek frames as overlay views that animate with gesture progress
- **Memory-Conscious Design**: No preloading, strict cache limits (5 frames max), immediate cleanup on navigation
- **Async-First Approach**: All frame extraction uses Swift 6 concurrency to maintain UI responsiveness

## Technical Approach

### Frontend Components

**Enhanced TikTokRallyPlayerView**
- Extend existing gesture recognizers to emit peek progress callbacks
- Add overlay container for peek frame display
- Integrate peek animations with existing Tinder-style rotations
- Maintain current video player as primary layer

**New FrameExtractor Service**
- Lightweight service using `AVAssetImageGenerator` for static frame extraction
- LRU cache implementation with automatic cleanup
- Async/await pattern for non-blocking frame extraction
- Error handling for corrupted or inaccessible videos

**Peek State Management**
- Add peek progress tracking to existing rally player state
- Coordinate peek animations with current gesture state
- Handle cleanup when navigation completes or cancels

### Backend Services

**Frame Extraction Pipeline**
- Utilize existing video metadata and rally information
- Extract first frame (time 0.1 seconds) to avoid black frames
- Cache extracted frames with automatic memory management
- Graceful fallback to placeholder frames on extraction failure

**Integration Points**
- Leverage existing `VideoPlayerManager` for rally navigation context
- Use current memory management patterns (sliding window limits)
- Integrate with existing AVPlayer cleanup and resource management

### Infrastructure

**Performance Optimizations**
- Background queue for frame extraction to maintain 60fps UI
- Immediate frame display from cache for recently viewed rallies
- Memory pressure monitoring with automatic cache eviction
- Performance telemetry to validate <100ms extraction target

**Error Handling**
- Graceful degradation when frame extraction fails
- Fallback to current behavior (no peek) on performance issues
- Resource cleanup on app backgrounding or memory warnings

## Implementation Strategy

### Phase 1: Frame Extraction Foundation (2-3 days)
- Implement `FrameExtractor` service with caching
- Add unit tests for frame extraction and cache management
- Validate performance requirements (<100ms extraction, <10MB memory)

### Phase 2: Gesture Integration (2-3 days)
- Extend existing gesture recognizers to support peek callbacks
- Add peek state management to rally player
- Implement basic peek frame display without animations

### Phase 3: Animation Polish (1-2 days)
- Integrate peek animations with existing Tinder-style rotations
- Add smooth transitions and gesture cancellation handling
- Performance optimization and edge case handling

## Task Breakdown Preview

High-level task categories that will be created:
- [ ] **Frame Extraction Service**: Create `FrameExtractor` with LRU caching and async extraction
- [ ] **Gesture Enhancement**: Extend `TikTokRallyPlayerView` gesture handling for peek callbacks
- [ ] **Peek UI Implementation**: Add overlay container and peek frame display logic
- [ ] **Animation Integration**: Coordinate peek animations with existing Tinder-style transitions
- [ ] **Performance Optimization**: Memory management, background processing, and error handling
- [ ] **Testing & Validation**: Unit tests, performance testing, and edge case validation

## Dependencies

### Internal Dependencies
- Current `TikTokRallyPlayerView` implementation and gesture system
- Existing `VideoPlayerManager` and rally metadata infrastructure
- Current memory management patterns and sliding window limits
- Swift 6 concurrency patterns and @MainActor isolation

### External Dependencies
- AVFoundation's `AVAssetImageGenerator` for frame extraction
- CoreGraphics for frame image processing and display
- SwiftUI animation system for smooth gesture-based transitions

### Technical Dependencies
- iOS 17+ compatibility with @Observable pattern
- Existing rally video file accessibility and metadata
- Current AVPlayer resource management and cleanup patterns

## Success Criteria (Technical)

### Performance Benchmarks
- Frame extraction completes within 100ms (measured via profiling)
- Peek animations maintain 60fps during gesture (verified via Instruments)
- Memory usage increase stays under 10MB peak (monitored via memory tools)
- No impact on existing video processing pipeline performance

### Quality Gates
- Zero memory leaks in frame extraction and caching system
- Graceful handling of corrupted or inaccessible video files
- Smooth gesture cancellation without visual artifacts
- Proper resource cleanup on app backgrounding or memory pressure

### Acceptance Criteria
- Peek frames appear proportionally to swipe progress
- Consistent experience across portrait and landscape orientations
- Seamless integration with existing Tinder-style rotation animations
- No performance degradation on target devices (iPhone 12+)

## Estimated Effort

### Overall Timeline: 5-8 days development + 2 days testing
- **Frame Extraction Service**: 2-3 days
- **Gesture Integration**: 2-3 days
- **Animation Polish**: 1-2 days
- **Testing & Optimization**: 2 days

### Resource Requirements
- Primary developer familiar with SwiftUI and AVFoundation
- Access to test devices for performance validation
- Sample rally videos for testing edge cases

### Critical Path Items
1. Frame extraction performance validation (must achieve <100ms target)
2. Memory management implementation (critical for preventing crashes)
3. Gesture integration without breaking existing functionality
4. Animation coordination with current Tinder-style system

## Risk Mitigation

**High Risk - Performance Impact**:
- Implement background queue processing with priority management
- Add performance monitoring and automatic fallback to current behavior
- Profile on target devices early in development cycle

**High Risk - Memory Management**:
- Implement strict LRU cache with configurable limits
- Add memory pressure monitoring with automatic cleanup
- Use weak references and proper resource disposal patterns

**Medium Risk - Animation Complexity**:
- Build incrementally starting with basic peek display
- Leverage existing animation infrastructure rather than creating new systems
- Add comprehensive gesture state testing

This epic leverages existing infrastructure to minimize complexity while delivering a polished user experience enhancement that transforms the rally player navigation from functional to professional-grade.

## Tasks Created
- [ ] #40 - Create FrameExtractor Service with LRU Caching (parallel: true)
- [ ] #41 - Enhance TikTokRallyPlayerView Gesture Handling (parallel: true)
- [ ] #42 - Implement Peek UI Overlay System (parallel: false)
- [ ] #43 - Integrate Peek Animations with Tinder-Style Transitions (parallel: false)
- [ ] #44 - Performance Optimization and Memory Management (parallel: false)
- [ ] #45 - Testing and Quality Assurance (parallel: false)

Total tasks:        6
Parallel tasks:        2
Sequential tasks: 4
Estimated total effort: 70-94 hours (5-8 days development + 2 days testing)
