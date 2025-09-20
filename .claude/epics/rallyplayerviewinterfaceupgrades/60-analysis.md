---
issue: 60
analyzed: 2025-09-19T18:15:00Z
complexity: medium
approach: parallel
---

# Issue #60: Smart Video Preloading - Analysis

## Overview
Implement intelligent video preloading with 1-video lookahead for seamless transitions, thumbnail fallbacks for cards 2-3 positions ahead, and efficient memory management.

## Work Streams

### Stream A: Player Management & Preloading
**Type**: Core video preloading
**Agent**: general-purpose
**Files**:
- BumpSetCut/Presentation/Views/RallyPlayerView.swift
- BumpSetCut/Domain/Models/RallyNavigationState.swift

**Scope**:
1. Implement smart player management with 1-video lookahead
2. Add player swapping for seamless transitions
3. Integrate preloading status tracking
4. Optimize memory usage (single preloaded player vs current all players)

**Dependencies**: Issue #57 (Thumbnail System) ✅ COMPLETED

### Stream B: Enhanced Thumbnail Prefetching
**Type**: Thumbnail optimization
**Agent**: general-purpose
**Files**:
- BumpSetCut/Infrastructure/Media/FrameExtractor.swift
- BumpSetCut/Domain/Services/RallyCacheManager.swift

**Scope**:
1. Extend thumbnail prefetching to positions 4-6 ahead
2. Optimize background prefetching queue
3. Enhance memory pressure handling
4. Coordinate with existing LRU cache system

**Dependencies**: Issue #57 (Thumbnail System) ✅ COMPLETED - can run in parallel

### Stream C: Rally Segment Preloading
**Type**: Background caching
**Agent**: general-purpose
**Files**:
- BumpSetCut/Domain/Services/RallyCacheManager.swift
- BumpSetCut/Domain/Services/VideoExporter.swift

**Scope**:
1. Implement background rally segment export
2. Add priority-based preloading queue
3. Create cache validation and cleanup
4. Performance monitoring and optimization

**Dependencies**: None - can run in parallel

## Implementation Approach

### Phase 1: Smart Player Management
- Replace "all players" approach with smart preloading
- Implement player swapping for seamless navigation
- Add preloading status tracking in RallyNavigationState
- Memory optimization (1 preloaded player vs current all players)

### Phase 2: Enhanced Thumbnail Strategy
- Extend thumbnail prefetching beyond current 3-card stack
- Background prefetching for positions 4-6 ahead
- Enhanced memory pressure handling with LRU eviction
- Integration with existing FrameExtractor system

### Phase 3: Rally Segment Caching
- Background export of next 2-3 rally segments
- Priority queue (current=high, next=normal, future=low)
- Automatic cleanup of old cached segments
- Performance monitoring and metrics

## Current System Analysis

### Strengths:
- Rally segment caching provides instant loading
- Thumbnail system with LRU cache and prefetching
- Memory pressure monitoring in FrameExtractor
- Navigation state management infrastructure

### Enhancement Opportunities:
- Replace "all players" with smart 1-ahead preloading
- Extend thumbnail prefetching beyond 3-card stack
- Background rally segment preloading
- Coordinated memory management across systems

## Preloading Strategy:
```swift
// Smart player management
currentPlayer: AVPlayer     // Active rally
preloadedPlayer: AVPlayer   // Next rally (1-ahead)

// Thumbnail strategy
immediate: positions 2-3    // In stack (existing)
background: positions 4-6   // Background prefetch (new)

// Rally segment caching
priority: next 2-3 segments // Background export (new)
```

## Risk Assessment
- **Low Risk**: Building on existing robust caching and thumbnail systems
- **Medium Risk**: Memory management coordination across multiple systems
- **Mitigation**: Incremental approach with graceful degradation, existing pressure monitoring

## Success Criteria
- Seamless transitions with 1-video lookahead
- Thumbnail fallbacks for cards 2-3 positions ahead
- Efficient memory management with single preloaded player
- Background preloading without UI blocking