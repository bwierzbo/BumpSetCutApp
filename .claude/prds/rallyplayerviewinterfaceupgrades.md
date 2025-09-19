---
name: rallyplayerviewinterfaceupgrades
description: Tinder-style card stack interface for rally video player with peel animations and stacked video preview
status: backlog
created: 2025-09-19T15:32:30Z
---

# PRD: Rally Player View Interface Upgrades

## Executive Summary

This PRD outlines the implementation of a Tinder-style card stack interface for the Rally Player View in BumpSetCut. The new interface will allow users to swipe through rally videos with a natural peel animation that reveals the next video underneath, creating an engaging and intuitive navigation experience similar to popular dating and social apps.

## Problem Statement

The current rally player interface uses traditional navigation patterns that don't provide visual continuity or preview of upcoming content. Users cannot see what's coming next, and the transitions between rallies feel disconnected. This creates a less engaging experience when reviewing multiple rally videos in sequence.

### Why This Matters Now
- Users expect modern, gesture-driven interfaces similar to popular apps
- Current transitions don't leverage the full potential of touch interactions
- Lack of visual preview reduces user confidence in navigation
- The existing implementation already has gesture support but lacks the visual polish

## User Stories

### Primary Persona: Coach Mike
**Background:** Volleyball coach reviewing game footage to analyze team performance
**Goal:** Quickly review and categorize rally segments

**User Journey:**
1. Opens a processed rally video
2. Sees current rally with a subtle preview of the next rally underneath
3. Swipes right to mark good plays (like)
4. Swipes left to mark plays needing improvement (delete)
5. Swipes up to skip to next rally without action
6. Can see the stack depleting as they progress

**Acceptance Criteria:**
- Can see edge of next video underneath current video
- Smooth peel animation follows finger movement
- Clear visual feedback for swipe direction
- Ability to cancel mid-swipe by returning to center

### Secondary Persona: Player Sarah
**Background:** Volleyball player reviewing personal performance
**Goal:** Find specific rallies quickly

**User Journey:**
1. Opens rally compilation
2. Sees current rally in full view
3. Quickly swipes through rallies to find specific moments
4. Uses partial swipes to peek at next rally
5. Returns to previous rally if needed

**Acceptance Criteria:**
- Responsive to quick swipes
- Supports both slow deliberate and fast navigation
- Visual stack indicates remaining rallies
- Smooth performance even with rapid swiping

## Requirements

### Functional Requirements

#### Core Card Stack Implementation
1. **Stacked Video Display**
   - Current video displayed as top card
   - Next video visible underneath with slight offset/shadow
   - Optional: Show edges of 2-3 videos in stack for depth

2. **Peel Animation Mechanics**
   - Video follows finger movement during drag
   - Rotation effect based on swipe direction (slight tilt)
   - Elastic resistance when approaching action thresholds
   - Smooth spring animation for completion/cancellation

3. **Gesture Recognition**
   - **Right Swipe**: Like action (heart icon feedback)
   - **Left Swipe**: Delete action (trash icon feedback)
   - **Up Swipe**: Skip to next without action
   - **Down Swipe**: Return to previous (if available)
   - **Tap**: Play/pause current video

4. **Visual Feedback**
   - Direction-specific icon overlays during swipe
   - Color coding for actions (green for like, red for delete)
   - Progress indicator showing position in stack
   - Smooth opacity transitions during peel

5. **State Management**
   - Maintain playback state during transitions
   - Preload next video for instant playback
   - Handle orientation changes gracefully
   - Preserve action history for undo capability

### Non-Functional Requirements

#### Performance
- Animations run at 60 FPS minimum
- No frame drops during video transitions
- Gesture response time < 16ms
- Memory efficient with video preloading

#### Compatibility
- iOS 17+ (uses @Observable pattern)
- iPhone and iPad support
- Portrait and landscape orientations
- Supports all video formats currently handled

#### Accessibility
- VoiceOver support for all actions
- Alternative button controls for swipe actions
- Respects reduced motion settings
- Clear visual contrast for action indicators

#### User Experience
- Gesture feel matches iOS native interactions
- Predictable physics-based animations
- Consistent with platform conventions
- Intuitive without tutorial needed

## Success Criteria

### Quantitative Metrics
- **Engagement Rate**: 30% increase in rallies reviewed per session
- **Action Rate**: 25% increase in rally categorization (like/delete)
- **Navigation Speed**: 40% faster rally-to-rally navigation
- **Gesture Success Rate**: >95% successful gesture recognition

### Qualitative Metrics
- Users report interface feels "modern" and "intuitive"
- Reduced learning curve for new users
- Positive feedback on visual continuity
- Coaches prefer new interface for quick review sessions

### Technical Metrics
- Animation performance maintains 60 FPS
- Memory usage increase <10% with preloading
- No regression in video playback quality
- Gesture recognition accuracy >98%

## Constraints & Assumptions

### Technical Constraints
- Must work within existing SwiftUI architecture
- Reuse current RallyPlayerView components where possible
- Maintain compatibility with existing gesture system
- Cannot break current export/sharing functionality

### Resource Constraints
- Implementation using existing team (no additional resources)
- Must leverage current animation frameworks
- No third-party libraries beyond current dependencies

### Assumptions
- Users familiar with swipe gestures from other apps
- Current video loading performance is acceptable
- Existing rally detection accuracy is sufficient
- Users want quick navigation over detailed analysis

## Out of Scope

The following items are explicitly NOT part of this upgrade:
- Custom gesture configuration/preferences
- Multi-video comparison views
- Advanced video editing capabilities
- Social sharing features beyond current functionality
- Cloud syncing of action states
- Machine learning for auto-categorization
- Video quality adjustments
- Custom animation timing preferences
- Batch operations on multiple rallies
- Alternative visualization modes (grid, list, etc.)

## Dependencies

### Internal Dependencies
- **RallyNavigationState**: Must support stack-based navigation
- **RallyVideoPlayerView**: Needs modification for layered display
- **AVPlayer Management**: Requires multiple player instance handling
- **Gesture System**: Current implementation must be extended
- **Animation Framework**: SwiftUI animation capabilities

### External Dependencies
- **iOS 17+ APIs**: For modern SwiftUI features
- **AVFoundation**: Video playback framework
- **SwiftUI.Animation**: Spring and timing animations
- **CoreGraphics**: For transform calculations

### Data Dependencies
- Rally metadata must be preloaded
- Video URLs must be accessible
- Thumbnail generation for preview
- Action persistence system

## Implementation Approach

### Phase 1: Foundation (Week 1)
- Extend current gesture system for peel mechanics
- Implement basic card stack view structure
- Create animation controllers

### Phase 2: Visual Polish (Week 2)
- Add peel animation with rotation
- Implement icon overlay system
- Create depth effect for stack

### Phase 3: Integration (Week 3)
- Connect to existing navigation state
- Implement preloading strategy
- Add orientation support

### Phase 4: Refinement (Week 4)
- Performance optimization
- Gesture fine-tuning
- Edge case handling

## Risk Mitigation

### Performance Risk
**Risk**: Stacked videos consume too much memory
**Mitigation**: Implement smart preloading with maximum 2 videos in memory

### UX Risk
**Risk**: Users accidentally trigger actions
**Mitigation**: Add confirmation thresholds and undo capability

### Technical Risk
**Risk**: Animation conflicts with video playback
**Mitigation**: Separate animation layer from video rendering

## Migration Strategy

- Feature flag for gradual rollout
- Option to revert to classic interface
- User onboarding for new gestures
- Preserve all existing functionality

## Appendix

### Competitive Analysis
- **Tinder**: Gold standard for card swiping
- **TikTok**: Vertical video navigation
- **Instagram Reels**: Smooth video transitions

### Technical References
- Current RallyPlayerView implementation
- SwiftUI Animation documentation
- AVFoundation best practices
- iOS Human Interface Guidelines for gestures