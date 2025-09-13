---
name: detection-logic-upgrades
status: backlog
created: 2025-09-03T00:02:01Z
progress: 0%
prd: .claude/prds/detection-logic-upgrades.md
github: https://github.com/bwierzbo/BumpSetCutApp/issues/20
---

# Epic: Detection Logic Upgrades

## Overview

Enhance existing volleyball detection pipeline with physics-based trajectory validation and metrics collection to eliminate false positives from carried balls and ground rolls. Focus on leveraging current BallisticsGate, RallyDecider, and SegmentBuilder architecture rather than creating new systems.

**Core Strategy:** Upgrade existing components with trajectory quality scoring and metrics collection, avoiding architectural changes.

## Architecture Decisions

### Leverage Existing Pipeline
- **Extend BallisticsGate:** Add parabolic validation to existing `isValidProjectile()` method
- **Enhance ProcessorConfig:** Add trajectory validation parameters to existing config system  
- **Utilize Current Tracking:** Build on existing KalmanBallTracker.TrackedBall data
- **Preserve VideoProcessor Flow:** No changes to main processing pipeline

### Metrics Integration Approach
- **Lightweight Collection:** Add metrics as optional data collection, not core processing requirement
- **Existing Data Structures:** Use current TrackedBall and rally structures for metrics calculation
- **Non-Blocking Design:** Metrics collection cannot impact processing performance
- **Developer-Only Features:** Metrics tools for optimization, not user-facing features

### Physics Validation Strategy
- **R² Correlation:** Add parabolic curve fitting to existing trajectory analysis
- **Velocity Profiling:** Analyze speed consistency within existing time windows
- **Movement Classification:** Simple heuristics to identify carried vs airborne movement
- **Quality Scoring:** Numerical scores for trajectory fitness without complex ML

## Technical Approach

### Enhanced Trajectory Validation (Core Focus)
**Extend BallisticsGate.swift:**
- Add `ParabolicValidator` struct with R² correlation calculation
- Implement `MovementClassifier` for airborne vs carried vs rolling detection
- Create `TrajectoryQualityScore` struct with smoothness and velocity metrics
- Enhance `isValidProjectile()` with physics-based filtering

**Key Enhancement:**
```swift
// Add to existing BallisticsGate
private func validateTrajectoryPhysics(_ track: TrackedBall) -> TrajectoryQuality {
    // R² parabolic correlation, velocity consistency, smoothness analysis
}
```

### Metrics Collection System (Secondary)
**New MetricsCollector.swift:**
- Lightweight data collection during existing processing
- Track precision/recall against manual ground truth
- Performance monitoring (processing time, memory usage)
- Export metrics data for analysis

**Integration Point:**
```swift
// Add to VideoProcessor without disrupting flow
private let metricsCollector = MetricsCollector()
// Collect data during existing rally analysis
```

### Configuration Enhancement (Minimal)
**Extend ProcessorConfig.swift:**
- Add trajectory validation thresholds
- Physics constraint parameters (min R², velocity ranges)
- Metrics collection toggles
- Quality score thresholds

## Implementation Strategy

### Phase 1: Core Physics Validation (Week 1)
Focus on the main problem - filtering false positives from carried balls
- Enhance BallisticsGate with parabolic fitting
- Add movement classification (airborne vs carried vs rolling)
- Implement quality scoring system

### Phase 2: Metrics Foundation (Week 2)
Build measurement capability for optimization
- Add lightweight metrics collection
- Implement precision/recall tracking
- Create basic performance monitoring

### Phase 3: Configuration & Tuning (Week 3)
Use metrics to optimize the system
- Add trajectory validation parameters to config
- Implement parameter testing framework
- Validate improvements with quantitative data

## Tasks Created

- [ ] 001.md - Enhanced Trajectory Physics Engine (#21, parallel: false, 16 hours)
- [ ] 002.md - Configuration Enhancement (#22, parallel: true, 4 hours)
- [ ] 003.md - Metrics Collection Service (#23, parallel: true, depends: [001], 8 hours)
- [ ] 004.md - Parameter Optimization Framework (#24, parallel: true, depends: [003], 10 hours)
- [ ] 005.md - Integration & Testing (#25, parallel: false, depends: [001], 12 hours)
- [ ] 006.md - Debug Visualization Tools (#26, parallel: true, depends: [003], 6 hours)

**Total tasks:** 6  
**Parallel tasks:** 4 (002, 003, 004, 006)  
**Sequential tasks:** 2 (001 foundation, 005 integration)  
**Estimated total effort:** 56 hours (3.5 weeks for 1 developer)

## Dependencies

### Internal Dependencies
- **BallisticsGate.swift**: Core trajectory validation component to enhance
- **ProcessorConfig.swift**: Configuration system for new parameters
- **VideoProcessor.swift**: Main pipeline for integration points
- **KalmanBallTracker**: Existing trajectory data for analysis

### External Dependencies
- **Mathematical Libraries**: Swift's Accelerate framework for curve fitting
- **iOS Performance Tools**: Instruments integration for performance validation
- **Storage System**: Existing app storage for optional metrics persistence

### No New External Frameworks
- Use existing Swift math capabilities
- Leverage current app architecture patterns
- Build on established processing pipeline

## Success Criteria (Technical)

### Performance Benchmarks
- **Processing Speed**: <10% increase in video processing time
- **Memory Usage**: <25MB additional RAM for trajectory analysis
- **Accuracy**: 95%+ precision for rally detection (eliminate carried ball false positives)
- **Physics Validation**: R² >0.85 correlation for accepted volleyball trajectories

### Quality Gates
- All existing tests continue to pass
- New trajectory validation has >90% effectiveness on test videos
- Metrics collection doesn't impact user experience
- Parameter optimization shows measurable accuracy improvements

### Acceptance Criteria
- Carried balls and ground rolls filtered from rally highlights
- Quantifiable accuracy metrics available for system optimization
- Developer tools provide actionable feedback on detection quality
- Enhanced system maintains current processing performance

## Estimated Effort

### Overall Timeline
- **3 weeks development** (leverage existing architecture for speed)
- **8 tasks maximum** (focus on enhancing vs rebuilding)
- **1 developer** (work within established patterns)

### Resource Requirements
- Primary iOS developer familiar with existing BallisticsGate logic
- Access to test videos with ground truth data for validation
- Performance profiling tools for optimization validation

### Critical Path Items
1. **BallisticsGate Enhancement** (foundation for all trajectory improvements)
2. **Physics Validation Logic** (core problem solution)
3. **Metrics Integration** (measurement capability for optimization)
4. **Parameter Tuning** (data-driven accuracy improvements)

## Risk Mitigation

### Low Risk Implementation
- **Extend Existing Code**: Build on proven BallisticsGate architecture
- **Incremental Enhancement**: Add features without replacing core logic
- **Performance Safeguards**: Metrics collection is optional and non-blocking
- **Backward Compatibility**: All enhancements are additive

### Complexity Reduction
- **Leverage Current Tracking**: Use existing TrackedBall data structures
- **Simple Physics Models**: R² correlation vs complex trajectory modeling
- **Optional Features**: Metrics tools don't affect core processing
- **Focused Scope**: Solve carried ball problem without major refactoring

---

*This epic transforms the trajectory validation problem into manageable enhancements to existing, proven components while providing the metrics foundation needed for continuous optimization.*