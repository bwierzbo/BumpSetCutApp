---
name: rallyplayerviewinterfaceupgrades
status: backlog
created: 2025-09-19T15:34:47Z
progress: 0%
prd: .claude/prds/rallyplayerviewinterfaceupgrades.md
github: https://github.com/bwierzbo/BumpSetCutApp/issues/55
---

# Epic: Rally Player View Interface Upgrades

## Overview
Implement a Tinder-style card stack interface for the Rally Player View by enhancing the existing gesture system with a visible video stack. The current implementation already has peel animations and gesture handling - we'll add the visual stack underneath to show upcoming videos.

## Architecture Decisions

### Leverage Existing Implementation
- **Current Assets**: RallyPlayerView already has peel animations, gesture handling, and icon feedback
- **Minimal Changes**: Add stack visualization without rewriting core functionality
- **Reuse Components**: Extend RallyVideoPlayerView for multi-layer rendering

### Technical Approach
- **ZStack Layers**: Use SwiftUI ZStack to layer 2-3 video previews underneath
- **Smart Preloading**: Keep only current + next video player active, show thumbnails for stack depth
- **Animation Coordination**: Sync existing peel animations with stack reveal

### Design Patterns
- **Existing Observable Pattern**: Continue using @StateObject for navigation state
- **Current Gesture System**: Enhance rather than replace the tinderStyleGesture
- **Memory Optimization**: Use thumbnail previews instead of full videos for stack

## Technical Approach

### Frontend Components
**Enhanced Stack View**
- Modify RallyPlayerView to show 2-3 stacked cards using ZStack
- Add offset and scale transforms for stacked appearance
- Use existing peelOffset for top card animation

**Visual Improvements**
- Add shadow layers between stacked videos
- Implement depth scaling (each card slightly smaller)
- Show stack depletion as user progresses

**Gesture Enhancements**
- Add peek functionality for partial swipes (already partially implemented)
- Smooth elastic resistance at action boundaries
- Enhanced visual feedback during drag

### State Management
- Extend RallyNavigationState with stack position tracking
- Add preloading state for next video
- Maintain thumbnail cache for stack preview

### Performance Optimizations
- Use AVPlayerLayer for current and next only
- Display static thumbnails for cards 2-3 in stack
- Lazy loading with 1-video lookahead

## Implementation Strategy

### Development Approach
1. **Incremental Enhancement**: Build on existing code rather than rewrite
2. **Visual-First**: Focus on stack visualization over new functionality
3. **Performance-Conscious**: Maintain 60 FPS with smart resource management

### Testing Approach
- Manual testing with various rally counts (1, 2, 5, 10+ rallies)
- Performance profiling for memory and CPU usage
- Gesture accuracy validation
- Orientation change testing

## Task Breakdown Preview

High-level task categories that will be created:
- [ ] **Stack Visualization**: Add ZStack layers with offset/scale for card stack appearance
- [ ] **Thumbnail System**: Generate and cache thumbnails for stack preview
- [ ] **Stack Animation**: Coordinate peel animation with stack reveal effect
- [ ] **Depth Indicators**: Add shadows and visual cues for stack depth
- [ ] **Preloading Logic**: Implement smart 1-video lookahead with thumbnail fallback
- [ ] **Polish Gestures**: Fine-tune resistance, thresholds, and elastic effects
- [ ] **Progress Indicator**: Add subtle UI showing position in rally stack
- [ ] **Performance Optimization**: Profile and optimize for 60 FPS

## Dependencies

### Internal Dependencies
- **Existing Components**: RallyPlayerView, RallyNavigationState, RallyVideoPlayerView
- **Current Systems**: Gesture handling, peel animations, icon feedback
- **Media Pipeline**: Thumbnail generation from FrameExtractor

### External Dependencies
- **SwiftUI**: ZStack, animation modifiers
- **AVFoundation**: Video playback and thumbnail extraction
- **CoreGraphics**: Transform calculations

### Prerequisites
- Current rally navigation must be working
- Video URLs must be accessible
- Existing gesture system functional

## Success Criteria (Technical)

### Performance Benchmarks
- Maintain 60 FPS during all animations
- Memory usage < 150MB with 10+ rallies
- Gesture response < 16ms
- No video playback stuttering

### Quality Gates
- All existing features continue working
- No regression in current gesture accuracy
- Smooth transitions between all rally videos
- Clean orientation change handling

### Acceptance Criteria
- Stack of 2-3 videos visible underneath current
- Smooth peel animation revealing next video
- Visual feedback for all swipe directions
- Progress indication through stack
- Peek functionality for preview

## Estimated Effort

### Overall Timeline
- **Total Duration**: 2 weeks
- **Development**: 8 days
- **Testing & Polish**: 2 days

### Resource Requirements
- 1 iOS developer
- Access to test devices
- Sample rally videos for testing

### Critical Path Items
1. Stack visualization (enables all other visual features)
2. Thumbnail generation (required for performance)
3. Animation coordination (core user experience)

## Tasks Created
- [ ] 001.md - Stack Visualization Foundation (parallel: false)
- [ ] 002.md - Thumbnail Generation System (parallel: true)
- [ ] 003.md - Stack Animation Coordination (parallel: false, depends on 001)
- [ ] 004.md - Depth Indicators and Shadows (parallel: false, depends on 001)
- [ ] 005.md - Smart Video Preloading (parallel: false, depends on 002)
- [ ] 006.md - Gesture Polish and Fine-tuning (parallel: false, depends on 003)
- [ ] 007.md - Progress Indicator UI (parallel: true, depends on 001)
- [ ] 008.md - Performance Optimization and Testing (parallel: false, depends on all)

Total tasks: 8
Parallel tasks: 2
Sequential tasks: 6
Estimated total effort: 62 hours