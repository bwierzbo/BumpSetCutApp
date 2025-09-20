---
issue: 57
analyzed: 2025-09-19T16:10:00Z
complexity: medium
approach: incremental
---

# Issue #57: Thumbnail Generation System - Analysis

## Overview
Create thumbnail generation system for stack preview using FrameExtractor with intelligent caching.

## Work Streams

### Stream A: Thumbnail Generation Enhancement
**Type**: Feature enhancement
**Agent**: general-purpose
**Files**:
- BumpSetCut/Infrastructure/Media/FrameExtractor.swift

**Scope**:
1. Enhance FrameExtractor for thumbnail generation at timestamps
2. Add async thumbnail extraction methods
3. Optimize frame extraction for performance
4. Support multiple quality levels

**Dependencies**: None - independent development

### Stream B: Cache Management System
**Type**: New implementation
**Agent**: general-purpose
**Files**:
- BumpSetCut/Domain/Services/RallyCacheManager.swift (new)

**Scope**:
1. Create intelligent caching system
2. Implement LRU eviction policy
3. Add size limit management
4. Background cleanup tasks

**Dependencies**: Stream A for thumbnail format

## Implementation Approach

### Phase 1: FrameExtractor Enhancement
- Add `generateThumbnail(at:)` method for specific timestamps
- Support configurable thumbnail sizes
- Implement async/await pattern
- Add batch thumbnail generation

### Phase 2: Cache Infrastructure
- Design cache key strategy (video ID + timestamp)
- Implement memory and disk caching tiers
- Add automatic cleanup on memory warnings
- Monitor cache performance metrics

### Phase 3: Integration
- Connect to RallyPlayerView stack
- Preload thumbnails for upcoming rallies
- Handle cache misses gracefully
- Background thumbnail prefetching

## Risk Assessment
- **Low Risk**: FrameExtractor already exists and works
- **Medium Risk**: Cache size management on limited devices
- **Mitigation**: Conservative cache limits with monitoring

## Success Criteria
- Thumbnails generate in <100ms
- Cache hit rate >80% for recent videos
- No UI blocking during generation
- Memory usage stays within limits