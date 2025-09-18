---
name: rallyswipingfixes
status: backlog
created: 2025-09-18T00:19:30Z
progress: 0%
prd: .claude/prds/rallyswipingfixes.md
github: https://github.com/bwierzbo/BumpSetCutApp/issues/46
---

# Epic: Rally Swiping Fixes

## Overview

Complete refactoring of rally player gesture and video management systems to eliminate initialization delays, system errors, and gesture inconsistencies. Focus on consolidating existing components rather than rewriting, leveraging 60% of current infrastructure while fixing core gesture coordination, state management, and video processing issues.

## Architecture Decisions

### Core Technical Strategy
- **Consolidation over Rewrite**: Refactor existing TikTokRallyPlayerView and SwipeableRallyPlayerView instead of building from scratch
- **Shared State Management**: Create unified RallyNavigationState to eliminate state duplication across components
- **Gesture Coordination**: Build centralized gesture handler to resolve conflicts and standardize behavior
- **Performance Optimization**: Fix FigPlayerInterstitial errors through proper AVPlayer resource management

### Technology Choices
- **SwiftUI with @Observable**: Leverage existing pattern for reactive state management
- **Native iOS Gestures**: Use DragGesture with improved coordination and debouncing
- **AVFoundation Optimization**: Implement proper player lifecycle and resource cleanup
- **Canvas-based Animations**: Enhance existing MetadataOverlayView for smoother performance

### Design Patterns
- **State Machine**: Rally navigation with clear states (loading, ready, transitioning, error)
- **Coordinator Pattern**: Centralized gesture handling with delegation to specific actions
- **Observer Pattern**: Maintain existing @Published pattern for reactive updates
- **Factory Pattern**: Keep existing RallyPlayerFactory for component selection

## Technical Approach

### Frontend Components

#### State Management Refactor
- **RallyNavigationState**: Unified @Observable class managing rally index, actions, and transitions
- **GestureCoordinator**: Centralized gesture handling with consistent thresholds and conflict resolution
- **VideoPlayerManager**: Enhanced lifecycle management with proper resource cleanup
- **ActionStack**: Undo/redo functionality with persistent state across app launches

#### UI Component Consolidation
- **Enhanced TikTokRallyPlayerView**: Fix initialization lag and gesture conflicts while maintaining feature parity
- **Optimized SwipeableRallyPlayerView**: Improve orientation handling and eliminate performance issues
- **Unified Animation System**: Reduce animation states from 10+ to 4 core states (idle, dragging, transitioning, bouncing)
- **Improved MetadataOverlayView**: Fix Canvas rendering performance and Canvas context issues

#### User Interaction Patterns
- **Immediate Gesture Recognition**: Zero initialization delay through proper view lifecycle management
- **Native iOS Feel**: Spring animations matching system behavior for orientation and navigation
- **Clear Visual Feedback**: Enhanced undo button with slide-back animations
- **Consistent Thresholds**: Standardized gesture distances (100px) across all components

### Backend Services

#### Video Processing Optimization
- **Player Resource Management**: Implement proper AVPlayer cleanup to eliminate FigPlayerInterstitial errors
- **Progressive Loading**: Preload rally metadata and thumbnails during app initialization
- **Memory Management**: Fix video buffer handling to prevent XPC connection failures
- **Cache Optimization**: Enhance RallyPlayerCache with improved preloading and cleanup

#### Data Layer Enhancements
- **Rally Action Persistence**: Extend VideoMetadata to track user actions (likes/deletes) persistently
- **Undo Stack Storage**: Implement reversible action history with cross-session persistence
- **Performance Monitoring**: Add gesture response time and animation fps tracking
- **Error Recovery**: Graceful handling of video processing failures without blocking UI

### Infrastructure

#### Performance Optimizations
- **Gesture Debouncing**: Prevent gesture spam and animation conflicts
- **Resource Preloading**: Smart rally video preparation during idle time
- **Memory Pressure Handling**: Automatic cleanup of distant rally resources
- **Canvas Optimization**: Efficient trajectory rendering with reduced draw calls

#### Error Handling
- **FigPlayerInterstitial Resolution**: Proper AVPlayer setup and teardown sequences
- **Graceful Degradation**: Rally player functions even with video processing failures
- **Resource Recovery**: Automatic retry logic for failed video operations
- **User-Friendly Messaging**: Clear feedback for processing delays or failures

## Implementation Strategy

### Development Approach
- **Incremental Refactoring**: Fix one component at a time while maintaining backwards compatibility
- **Performance First**: Address FigPlayerInterstitial errors and initialization lag before feature additions
- **Test-Driven**: Comprehensive testing with existing rally libraries to prevent regressions
- **Feature Flags**: Gradual rollout capabilities for risk mitigation

### Risk Mitigation
- **Fallback Compatibility**: Existing rally player remains functional during refactoring
- **Performance Benchmarking**: Continuous monitoring ensures no regression in responsiveness
- **Resource Management**: Careful AVPlayer lifecycle management to prevent memory leaks
- **State Validation**: Comprehensive testing of gesture states and transitions

## Task Breakdown Preview

High-level task categories that will be created:

- [ ] **Gesture System Consolidation**: Create unified gesture coordinator and resolve conflicts between horizontal/vertical swipes
- [ ] **State Management Unification**: Build RallyNavigationState to eliminate duplicate state across components
- [ ] **Video Resource Optimization**: Fix FigPlayerInterstitial errors and implement proper AVPlayer lifecycle management
- [ ] **Animation System Simplification**: Reduce animation complexity while maintaining smooth transitions and native feel
- [ ] **Orientation Handling Enhancement**: Implement seamless portrait/landscape transitions matching native iOS behavior
- [ ] **Performance Monitoring Integration**: Add gesture response tracking and animation performance validation
- [ ] **Action Persistence & Undo**: Build reversible action system with cross-session state persistence
- [ ] **Component Integration Testing**: Validate refactored components work with existing rally processing pipeline

## Dependencies

### External Dependencies
- **iOS 16+ SwiftUI**: Required for advanced gesture and animation APIs
- **AVFoundation**: Critical for video playback optimization and resource management
- **System Orientation**: Native iOS rotation notifications and geometry changes

### Internal Dependencies
- **Video Processing Pipeline**: Must remain stable (YOLODetector → KalmanBallTracker → RallyDecider)
- **MediaStore Data Model**: VideoMetadata format compatibility for existing rally libraries
- **MetadataOverlayView**: Canvas-based trajectory rendering system integration
- **AppSettings**: Feature toggle system for gradual rollout capabilities

### Risk Mitigation
- **Backwards Compatibility**: All existing rally data and processing workflows remain functional
- **Progressive Enhancement**: New gesture system works alongside existing implementation
- **Resource Validation**: Comprehensive testing with real rally libraries before deployment

## Success Criteria (Technical)

### Performance Benchmarks
- **Gesture Response Time**: <50ms (down from current inconsistent 100-300ms)
- **Initialization Time**: Rally interaction ready in <500ms (vs current 3-5 second delay)
- **Animation Frame Rate**: Sustained 60fps during all transitions and gestures
- **Memory Usage**: <50MB rally video buffer overhead (down from current unbounded growth)
- **Error Elimination**: Zero FigPlayerInterstitial errors during normal rally navigation

### Quality Gates
- **Zero Regression**: All existing rally player functionality preserved
- **Resource Cleanup**: No memory leaks or AVPlayer resource accumulation
- **Gesture Accuracy**: 99%+ gesture recognition rate with clear directional intent
- **State Consistency**: Rally navigation state always matches visual presentation
- **Cross-Component Compatibility**: Seamless switching between rally player types

### Acceptance Criteria
- **Native iOS Feel**: Orientation transitions indistinguishable from system apps
- **Immediate Responsiveness**: Gestures work instantly upon rally player appearance
- **Visual Polish**: Smooth animations with proper physics and spring curves
- **Error Recovery**: Graceful handling of video processing failures without blocking UI
- **Persistent State**: User actions and undo history survive app restarts

## Estimated Effort

### Overall Timeline: 3-4 weeks

**Week 1: Foundation & Error Resolution**
- Fix FigPlayerInterstitial errors and resource management
- Create RallyNavigationState and basic gesture coordination
- Eliminate initialization delays

**Week 2: Gesture & Animation Consolidation**
- Implement unified gesture system with conflict resolution
- Simplify animation states and improve performance
- Add undo functionality with persistent state

**Week 3: Orientation & Polish**
- Native iOS orientation handling implementation
- Performance optimization and memory management
- Comprehensive testing with existing rally libraries

**Week 4: Integration & Validation**
- Component integration testing and final optimizations
- Performance benchmarking and quality assurance
- Documentation and knowledge transfer

### Resource Requirements
- **Primary Developer**: 1 full-time iOS developer with SwiftUI expertise
- **Testing Resources**: Access to rally video libraries for comprehensive validation
- **Performance Tools**: Xcode Instruments for memory and performance profiling

### Critical Path Items
1. **AVPlayer Resource Management**: Must resolve FigPlayerInterstitial errors first
2. **State Management Unification**: Required before gesture system improvements
3. **Gesture Coordination**: Foundation for all other interaction improvements
4. **Performance Validation**: Continuous monitoring prevents regression introduction

## Tasks Created
- [ ] #47 - Video Resource Optimization (parallel: false)
- [ ] #48 - State Management Unification (parallel: false)
- [ ] #49 - Gesture System Consolidation (parallel: true)
- [ ] #50 - Animation System Simplification (parallel: true)
- [ ] #51 - Performance Monitoring Integration (parallel: true)
- [ ] #52 - Orientation Handling Enhancement (parallel: true)
- [ ] #53 - Component Integration Testing (parallel: false)
- [ ] #54 - Action Persistence & Undo (parallel: true)

Total tasks: 8
Parallel tasks: 5
Sequential tasks: 3
Estimated total effort: 96-112 hours
