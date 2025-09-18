---
name: rallyswipingfixes
description: Complete rewrite and optimization of rally swiping components for fluid gestures, reliable initialization, and native iOS experience
status: backlog
created: 2025-09-18T00:07:52Z
---

# PRD: Rally Swiping Fixes

## Executive Summary

The current rally player swiping functionality suffers from initialization delays, gesture unresponsiveness, performance issues, and inconsistent behavior across orientations. This PRD outlines a complete rewrite of the rally swiping components to deliver a native iOS experience with fluid animations, reliable gesture recognition, and optimized video processing.

## Problem Statement

### Current Issues
1. **Initialization Lag**: Swiping doesn't register for several seconds after app launch, causing user frustration
2. **System Errors**: Flood of FigPlayerInterstitial errors (-15671) and image processing failures during startup
3. **Orientation Transitions**: Jerky, unsmooth transitions between vertical and horizontal viewing modes
4. **Code Complexity**: Multiple AI-driven fixes have created messy, hard-to-maintain code
5. **Performance Degradation**: Video analysis services causing XPC connection failures and cancellation errors
6. **Gesture Inconsistency**: Unreliable swipe recognition and conflicting gesture behaviors

### Impact
- Poor user experience during critical first-use moments
- Reduced app reliability and perceived quality
- Maintenance burden from complex, patched code
- Inconsistent behavior that doesn't match iOS native apps

## User Stories

### Primary Persona: Volleyball Player/Coach
**Goal**: Quickly review and organize rally videos with intuitive gestures

#### Core User Journey
1. **Launch & Load**: Opens rally player and immediately sees responsive, fluid interface
2. **Quick Review**: Swipes through rally videos with zero lag or visual artifacts
3. **Action Taking**: Uses natural gestures to like/delete videos without confusion
4. **Orientation Change**: Seamlessly rotates device without interrupting video flow
5. **Mistake Recovery**: Easily undoes accidental actions with clear visual feedback

#### Acceptance Criteria
- Gestures respond within 100ms of touch input
- Zero initialization lag - swiping works immediately
- Smooth 60fps animations for all gesture interactions
- Native iOS-level orientation transition smoothness
- Clear visual feedback for all actions taken

### Secondary Persona: Technical User
**Goal**: Reliable app performance without console spam or errors

#### Acceptance Criteria
- No FigPlayerInterstitial errors during normal operation
- Proper resource cleanup preventing XPC connection failures
- Optimized video processing preventing analysis service overload
- Clean console output during rally player usage

## Requirements

### Functional Requirements

#### FR1: Gesture System Rewrite
- **Left Swipe**: Delete rally video with peel-off animation
- **Right Swipe**: Like/favorite rally video for export
- **Up Swipe**: Navigate to next rally without action
- **Tap**: Pause/play video toggle
- **Undo Button**: Reverse last like/delete action with slide-back animation

#### FR2: Initialization Optimization
- Rally videos load and become interactive within 500ms
- Gesture recognition active immediately upon view appearance
- Pre-load essential video metadata to prevent startup delays
- Implement progressive loading for better perceived performance

#### FR3: Orientation Handling
- Seamless vertical ↔ horizontal transitions matching native iOS apps
- Maintain video playback state during orientation changes
- Adaptive UI layout that works fluidly in both orientations
- 60fps transition animations with proper physics

#### FR4: Animation System
- Sticky-note peel animation for swipe actions
- Smooth elastic bounce for gesture boundaries
- Native iOS spring animations for all transitions
- Reveal-underneath effect when removing videos

#### FR5: State Persistence
- Rally videos generated once and persisted across app launches
- User actions (likes/deletes) saved immediately
- Undo stack maintains state between sessions
- Optimized storage preventing duplicate video generation

### Non-Functional Requirements

#### NFR1: Performance
- **Response Time**: <100ms gesture recognition
- **Frame Rate**: 60fps animations throughout
- **Memory**: Efficient video buffer management
- **CPU**: Optimized image processing pipeline

#### NFR2: Reliability
- Zero FigPlayerInterstitial errors during normal operation
- Proper AVPlayer resource management
- Graceful handling of video processing failures
- Robust error recovery without user impact

#### NFR3: Code Quality
- Clean, maintainable SwiftUI architecture
- Separation of concerns between gesture, animation, and video systems
- Comprehensive error handling and logging
- Testable component design

#### NFR4: Compatibility
- iOS 16+ native behavior consistency
- Works across all supported device sizes
- Maintains existing rally player feature parity
- Backwards compatible with existing rally data

## Success Criteria

### Primary Metrics
- **Gesture Response Time**: <100ms (Target: <50ms)
- **Animation Smoothness**: 60fps sustained (0 dropped frames)
- **Initialization Time**: Rally interaction ready in <500ms
- **Error Rate**: Zero FigPlayerInterstitial errors in normal usage
- **Orientation Transition**: <300ms smooth rotation

### Secondary Metrics
- **Memory Usage**: <50MB video buffer overhead
- **CPU Usage**: <30% during heavy gesture usage
- **User Action Success Rate**: 99%+ gesture recognition accuracy
- **Undo Usage**: Measure recovery action frequency

### Qualitative Goals
- Native iOS app feel and responsiveness
- Intuitive gesture discovery and usage
- Smooth, polished visual experience
- Professional video review workflow

## Technical Architecture

### Component Rewrite Strategy

#### Phase 1: Core Gesture System
- New `RallyGestureHandler` with immediate recognition
- Unified gesture coordination preventing conflicts
- Optimized touch processing pipeline

#### Phase 2: Animation Framework
- Custom `StickyNoteAnimation` component
- Native spring animation integration
- Reveal-underneath transition system

#### Phase 3: Video Management
- Optimized `RallyVideoManager` with smart preloading
- Efficient buffer management preventing errors
- Progressive loading architecture

#### Phase 4: Orientation System
- Native iOS orientation handling integration
- Smooth layout transition system
- Maintained playback state management

### Performance Optimizations
- Lazy loading of non-visible rally videos
- Smart caching preventing duplicate processing
- Efficient memory management with automatic cleanup
- Background processing optimization

## Constraints & Assumptions

### Technical Constraints
- Must maintain compatibility with existing rally data format
- SwiftUI framework limitations for complex animations
- iOS AVPlayer resource management requirements
- CoreML processing pipeline dependencies

### Resource Constraints
- Single developer implementation
- Must not break existing rally player functionality during development
- Existing video processing pipeline must remain functional

### Platform Constraints
- iOS 16+ target (taking advantage of latest SwiftUI features)
- iPhone and iPad form factor support
- Portrait and landscape orientation requirements

## Out of Scope

### Explicitly Excluded
- Rally detection algorithm changes
- Video export functionality modifications
- New gesture types beyond the core four (left/right/up/tap)
- Rally player UI redesign beyond gesture improvements
- Audio processing or playback modifications
- Social sharing or collaboration features

### Future Considerations
- Advanced gesture customization
- Additional animation styles
- Accessibility gesture alternatives
- Apple Watch integration

## Dependencies

### Internal Dependencies
- VideoProcessor pipeline must remain stable
- MediaStore rally data format compatibility
- Existing rally generation logic
- Debug video processing workflow

### External Dependencies
- iOS 16+ SwiftUI animation APIs
- AVFoundation video playback framework
- CoreML vision processing (for rally detection)
- System orientation change notifications

### Risk Mitigation
- Comprehensive testing with existing rally libraries
- Gradual rollout with feature flags
- Fallback to current implementation if issues arise
- Performance monitoring during development

## Implementation Plan

### Milestone 1: Foundation (Week 1)
- New RallyGestureHandler implementation
- Basic swipe gesture recognition without animations
- Eliminate FigPlayerInterstitial errors

### Milestone 2: Animations (Week 2)
- Sticky-note peel animation system
- Undo button with slide-back animation
- Smooth gesture boundary handling

### Milestone 3: Orientation (Week 3)
- Native iOS orientation transition implementation
- Seamless vertical/horizontal experience
- Video state preservation during rotation

### Milestone 4: Polish (Week 4)
- Performance optimization and testing
- Error handling and edge case coverage
- Documentation and code cleanup

### Validation Criteria
Each milestone requires:
- Zero regression in existing functionality
- Performance metrics meeting NFR requirements
- User testing validation of gesture feel
- Clean console output with no errors

## Risk Assessment

### High Risk
- **Complex Animation Implementation**: SwiftUI animation limitations may require custom solutions
- **Video Processing Integration**: Changes may affect rally generation pipeline
- **Performance Regression**: New implementation must not slow down existing features

### Medium Risk
- **Orientation Handling**: iOS system integration complexity
- **Memory Management**: Video buffer optimization challenges
- **Backwards Compatibility**: Existing rally data format preservation

### Low Risk
- **Gesture Recognition**: Well-established iOS patterns
- **UI Layout**: Existing component architecture is solid
- **State Management**: Current @Observable pattern works well

### Mitigation Strategies
- Feature flags for gradual rollout
- Comprehensive automated testing
- Performance benchmarking at each milestone
- User acceptance testing with real rally data