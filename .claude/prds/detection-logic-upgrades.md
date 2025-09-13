---
name: detection-logic-upgrades
description: Enhanced trajectory validation and metrics-driven rally analysis for volleyball detection accuracy
status: backlog
created: 2025-09-02T23:54:23Z
---

# PRD: Detection Logic Upgrades

## Executive Summary

Upgrade the volleyball detection pipeline to enforce proper parabolic trajectory validation and implement comprehensive metrics tracking. This will significantly improve rally analysis accuracy by filtering out non-volleyball movements (carried balls, ground rolls) and provide quantifiable data for system optimization.

**Key Value:** Transform subjective "feels accurate" assessments into precise, metrics-driven optimization of volleyball rally detection.

## Problem Statement

### Current Issues
1. **False Rally Continuance:** Balls carried back to serve line or rolling on ground are incorrectly classified as valid rally segments due to poor trajectory validation
2. **No Quantitative Feedback:** Cannot measure detection accuracy or optimize settings with concrete data
3. **Trajectory Analysis Gaps:** Current BallisticsGate doesn't enforce proper parabolic flight patterns for volleyball physics

### Why This Matters Now
- Rally highlights include invalid sequences, reducing video quality
- Manual parameter tuning without accuracy feedback is inefficient
- User trust decreases when obviously non-rally movements are included in highlights

## User Stories

### Primary Persona: Volleyball Coach/Player
**User Goal:** Accurate rally highlights that only include actual volleyball gameplay

**Current Pain Points:**
- "My highlight reel shows someone walking the ball back to serve - that's not a rally!"
- "I can't tell if my detection settings are actually better or worse"
- "Ground rolls and carried balls mess up my rally analysis"

**Desired Experience:**
- Clean rally segments that only include airborne volleyball physics
- Clear accuracy metrics to understand system performance
- Confidence in automated rally detection for training analysis

### Secondary Persona: App Developer (You)
**Developer Goal:** Data-driven optimization of detection parameters

**Current Pain Points:**
- No quantitative way to measure improvement from config changes
- Difficult to justify parameter choices without accuracy data
- Manual testing doesn't scale across diverse video conditions

**Desired Experience:**
- Accuracy dashboard showing detection performance metrics
- A/B testing capability for different parameter configurations
- Historical tracking of improvement over time

## Requirements

### Functional Requirements

#### 1. Enhanced Trajectory Validation
- **Physics-Based Filtering:** Enforce parabolic trajectory requirements for valid rally segments
- **Movement Classification:** Distinguish between volleyball flight, carried ball, and ground movement
- **Smoothness Analysis:** Reject trajectories with excessive jitter or non-ballistic patterns
- **Velocity Constraints:** Filter movements outside realistic volleyball speed ranges

#### 2. Comprehensive Metrics System
- **Accuracy Tracking:** Precision, recall, and F1 scores for rally detection
- **Trajectory Quality Metrics:** Parabolic fit quality, velocity consistency, smoothness scores
- **Performance Analytics:** Processing time, memory usage, detection confidence distributions
- **Historical Data:** Track metrics over time for trend analysis

#### 3. Configuration Optimization
- **Parameter Validation:** Test multiple configuration sets against ground truth data
- **Automatic Tuning:** Suggest optimal parameters based on accuracy metrics
- **A/B Testing Framework:** Compare different detection strategies quantitatively

#### 4. Debug and Visualization Tools
- **Trajectory Visualization:** Display detected paths with quality scores
- **Metrics Dashboard:** Real-time accuracy and performance monitoring
- **False Positive Analysis:** Detailed breakdown of incorrect detections

### Non-Functional Requirements

#### Performance
- **Processing Time:** No more than 10% increase in video processing time
- **Memory Usage:** Metrics collection should not exceed 50MB additional RAM
- **Storage:** Metrics data should be efficiently stored and rotated

#### Accuracy
- **Rally Detection:** Target 95%+ precision (reduce false positives from carried balls)
- **Trajectory Validation:** Reject 90%+ of non-parabolic movements
- **Metrics Reliability:** Accuracy measurements within ±2% of manual verification

#### Usability
- **Developer Interface:** Clear metrics API for accessing accuracy data
- **Configuration:** Easy parameter adjustment with immediate feedback
- **Debugging:** Visual tools to understand detection failures

## Success Criteria

### Primary Metrics
1. **False Positive Reduction:** Decrease invalid rally segments by 80%+ (especially carried balls and ground rolls)
2. **Trajectory Quality:** 95%+ of accepted rallies have proper parabolic fit scores
3. **Detection Confidence:** Quantifiable accuracy metrics available for all processing runs

### Secondary Metrics
1. **Processing Efficiency:** Maintain current processing speeds (±10%)
2. **Developer Productivity:** 50% reduction in manual testing time through automated metrics
3. **Parameter Optimization:** Data-driven parameter recommendations with measurable improvements

### User Validation
- Rally highlights contain only airborne volleyball movements
- Developers can optimize settings using concrete accuracy data
- System performance can be tracked and improved over time

## Technical Architecture

### Core Components

#### 1. Enhanced BallisticsGate
```swift
// Upgrade existing BallisticsGate with:
- ParabolicValidator: Physics-based trajectory analysis
- MovementClassifier: Distinguish ball types (airborne vs carried vs rolling)
- QualityScorer: Rate trajectory fitness for volleyball physics
```

#### 2. Metrics Collection Service
```swift
// New MetricsService for:
- AccuracyTracker: Precision/recall calculations
- PerformanceMonitor: Processing time and resource usage
- ConfigurationAnalyzer: Parameter effectiveness measurement
```

#### 3. Trajectory Analysis Engine
```swift
// Enhanced trajectory processing:
- Parabolic curve fitting with R² correlation scores
- Velocity profile analysis for realistic volleyball physics
- Smoothness detection to filter jittery non-ballistic movement
```

#### 4. Debug Visualization System
```swift
// Developer tools:
- TrajectoryVisualizer: Display paths with quality scores
- MetricsDashboard: Real-time accuracy monitoring
- ConfigTester: A/B test different parameter sets
```

## Implementation Phases

### Phase 1: Trajectory Validation (Week 1-2)
- Implement parabolic fit validation in BallisticsGate
- Add movement classification (airborne/carried/rolling)
- Create quality scoring system for trajectories

### Phase 2: Metrics Foundation (Week 2-3)
- Build metrics collection infrastructure
- Implement accuracy tracking (precision/recall)
- Create performance monitoring system

### Phase 3: Visualization & Tools (Week 3-4)
- Develop trajectory visualization tools
- Build metrics dashboard for developers
- Create configuration testing framework

### Phase 4: Optimization & Tuning (Week 4-5)
- Use metrics to optimize existing parameters
- Implement automated parameter suggestions
- Validate improvements with quantitative data

## Dependencies

### Internal Dependencies
- **VideoProcessor:** Core processing pipeline for integration
- **BallisticsGate:** Existing trajectory tracking to enhance
- **RallyDecider:** Rally segmentation logic for metrics validation
- **ProcessorConfig:** Parameter management system for optimization

### External Dependencies
- **Mathematical Libraries:** Advanced curve fitting and statistical analysis
- **Visualization Frameworks:** Charts and graphs for metrics display
- **Storage System:** Efficient metrics data persistence

## Constraints & Assumptions

### Technical Constraints
- **iOS Performance:** Must maintain real-time processing capability on mobile devices
- **Memory Limits:** Additional analysis cannot exceed reasonable mobile memory usage
- **Battery Life:** Enhanced processing should not significantly impact battery consumption

### Business Constraints
- **Development Time:** 4-5 week implementation window
- **Backward Compatibility:** Must work with existing video processing pipeline
- **User Experience:** No disruption to current app functionality

### Assumptions
- Current YOLO detection accuracy is sufficient (focus on trajectory analysis)
- Ground truth data available for accuracy validation
- Users prefer fewer, more accurate rally segments over more segments with noise

## Out of Scope

### Explicitly NOT Building
- **New ML Models:** Not replacing or retraining YOLO detection models
- **Real-time Processing:** Focus remains on post-processing pipeline
- **Multi-object Tracking:** Still focused on single volleyball detection
- **UI Changes:** No changes to user-facing video processing interface
- **Cloud Processing:** All analysis remains on-device

### Future Considerations
- Player detection and tracking
- Real-time rally analysis
- Advanced game statistics
- Cloud-based model updates

## Risk Assessment

### Technical Risks
- **Performance Impact:** Complex trajectory analysis may slow processing
  - *Mitigation:* Optimize algorithms and profile performance continuously
- **False Negatives:** Overly strict validation may reject valid rallies
  - *Mitigation:* Tune thresholds using comprehensive test data

### Business Risks
- **Development Complexity:** Physics-based validation is mathematically complex
  - *Mitigation:* Start with simple implementations and iterate
- **Measurement Accuracy:** Metrics may not reflect real-world usage
  - *Mitigation:* Validate metrics against manual ground truth verification

## Acceptance Criteria

### Must Have
- [ ] Parabolic trajectory validation prevents carried ball false positives
- [ ] Accuracy metrics (precision/recall) available for all processing runs
- [ ] Ground movement and rolling balls filtered from rally segments
- [ ] Processing time impact < 10% of current baseline

### Should Have  
- [ ] Visual trajectory analysis tools for debugging
- [ ] Parameter optimization recommendations based on accuracy data
- [ ] Historical metrics tracking for performance trends
- [ ] Quality scoring for individual rally segments

### Could Have
- [ ] A/B testing framework for configuration comparison
- [ ] Automated parameter tuning based on accuracy feedback
- [ ] Advanced physics validation (spin, air resistance modeling)
- [ ] Exportable metrics reports for analysis

## Metrics for Success

### Quantitative Measurements
1. **False Positive Rate:** < 5% for carried balls and ground rolls
2. **Trajectory Quality Score:** > 0.9 R² correlation for accepted rallies
3. **Processing Performance:** Maintain current speed ±10%
4. **Memory Usage:** < 50MB additional RAM for metrics collection

### Qualitative Assessments
1. **Developer Experience:** Faster parameter optimization through data feedback
2. **Rally Quality:** Cleaner, more accurate highlight reels
3. **System Confidence:** Quantifiable trust in detection accuracy

---

*This PRD focuses on measurable improvements to trajectory validation and provides the metrics foundation needed for continuous system optimization.*