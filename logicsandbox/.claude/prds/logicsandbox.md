---
name: logicsandbox
description: Python-based parameter experimentation environment replicating BumpSetCut's beach volleyball processing pipeline
status: backlog
created: 2025-09-13T04:52:04Z
---

# PRD: logicsandbox

## Executive Summary

The logicsandbox is a Python-based experimental environment that provides an exact replica of BumpSetCut's beach volleyball video processing pipeline. It enables rapid parameter tuning and algorithm optimization without requiring iOS development cycles, allowing for quick iteration on rally segmentation and processing algorithms before implementing changes in the production iOS app.

## Problem Statement

### What problem are we solving?
Currently, optimizing BumpSetCut's volleyball processing parameters requires:
1. Modifying Swift code in the iOS app
2. Rebuilding and deploying the app
3. Testing on device with video files
4. Analyzing results and repeating the cycle

This development cycle is slow and inefficient for parameter experimentation, making it difficult to quickly test and refine algorithm configurations.

### Why is this important now?
- Parameter optimization is critical for improving rally detection accuracy
- The iOS development cycle creates friction for rapid experimentation
- Need ability to quickly test different algorithm configurations on sample videos
- Current workflow slows down algorithm refinement and research

## User Stories

### Primary User Persona: Algorithm Developer (Self)
**Role**: Developer working on BumpSetCut's volleyball processing algorithms
**Goal**: Optimize rally detection and video processing parameters efficiently

#### User Journey: Parameter Optimization
1. **Setup**: Load a beach volleyball video into logicsandbox
2. **Baseline**: Run processing with current BumpSetCut parameters
3. **Experiment**: Modify specific parameters (rally thresholds, physics constraints, etc.)
4. **Analyze**: Review debug video output to assess algorithm performance
5. **Iterate**: Quickly adjust parameters and reprocess
6. **Finalize**: Identify optimal parameters for iOS implementation

#### Pain Points Being Addressed
- Slow iOS development cycle for parameter changes
- Inability to quickly compare different parameter configurations
- Difficulty analyzing algorithm behavior without debug visualization
- Time-consuming process to test algorithm improvements

## Requirements

### Functional Requirements

#### Core Video Processing
- **FR-1**: Process beach volleyball videos through complete BumpSetCut pipeline
- **FR-2**: Support same video formats as BumpSetCut iOS app (.mov, .mp4)
- **FR-3**: Generate debug videos with visual overlays identical to BumpSetCut debug mode

#### Algorithm Replication
- **FR-4**: Implement exact replicas of BumpSetCut algorithms:
  - ML-based volleyball detection using bestv2.mlpackage
  - Kalman ball tracking with constant velocity model
  - Physics-based trajectory validation (ballistics gate)
  - Hysteresis-based rally state machine
  - Advanced video segmentation with padding and merging

#### Parameter Configuration
- **FR-5**: Provide comprehensive configuration system matching BumpSetCut's ProcessorConfig
- **FR-6**: Support all 59+ tunable parameters from iOS app
- **FR-7**: Enable easy parameter modification through configuration files
- **FR-8**: Support parameter presets (conservative, aggressive, high-precision)

#### Debug Visualization
- **FR-9**: Generate debug videos with overlays showing:
  - Ball detection circles with confidence scores
  - Trajectory trails with fading effects
  - Rally state indicators (IDLE/POTENTIAL/ACTIVE/ENDING)
  - Physics validation status
  - Kalman tracking vectors and predictions
  - Frame-by-frame processing information

#### Output Generation
- **FR-10**: Produce video outputs matching BumpSetCut formats:
  - Trimmed videos containing only rally segments
  - Debug videos with comprehensive algorithm visualization
  - Processing statistics and rally detection metrics

### Non-Functional Requirements

#### Performance
- **NFR-1**: Process videos efficiently (target: <5 seconds for 10-second video)
- **NFR-2**: Support videos up to common match lengths (30+ minutes)
- **NFR-3**: Memory usage should be reasonable for laptop development

#### Accuracy
- **NFR-4**: Algorithm outputs must match BumpSetCut iOS app within acceptable tolerance
- **NFR-5**: Debug visualizations must accurately represent algorithm state

#### Usability
- **NFR-6**: Simple command-line interface for processing videos
- **NFR-7**: Clear parameter configuration through readable config files
- **NFR-8**: Comprehensive logging of processing steps and decisions

## Success Criteria

### Primary Success Metrics
1. **Functional Parity**: Logicsandbox produces debug videos visually identical to BumpSetCut iOS debug mode
2. **Parameter Accessibility**: All BumpSetCut processing parameters are configurable and testable
3. **Processing Speed**: Video processing completes significantly faster than iOS rebuild cycle
4. **Output Quality**: Generated rally segments match expected BumpSetCut behavior

### Key Performance Indicators
- **Processing Time**: <5 seconds for typical test videos (9-second trainingshort2.mov)
- **Algorithm Coverage**: 100% of BumpSetCut processing pipeline replicated
- **Parameter Count**: 59+ configurable parameters available
- **Debug Visualization**: Complete visual representation of algorithm decisions

## Constraints & Assumptions

### Technical Constraints
- **TC-1**: Must use same CoreML model (bestv2.mlpackage) as iOS app
- **TC-2**: Python implementation limits (OpenCV, NumPy-based processing)
- **TC-3**: Single-threaded processing acceptable for experimentation use case
- **TC-4**: macOS development environment (accessing iOS app's ML models)

### Timeline Constraints
- **TC-5**: Implementation should be completed efficiently as internal tooling
- **TC-6**: No extensive documentation or user interface required

### Resource Constraints
- **TC-7**: Single developer (self) as only user
- **TC-8**: No need for production-level error handling or user support

### Assumptions
- **A-1**: Primary testing will use existing beach volleyball videos
- **A-2**: Parameter optimization will be manual/iterative process
- **A-3**: CoreML model and iOS app architecture remain stable
- **A-4**: No need for real-time processing capabilities

## Out of Scope

### Explicitly NOT Building
- **OOS-1**: User interface beyond command-line tools
- **OOS-2**: Automated parameter optimization or machine learning
- **OOS-3**: Integration with iOS app build system
- **OOS-4**: Support for sports other than beach volleyball
- **OOS-5**: Real-time video processing capabilities
- **OOS-6**: Multi-user or collaborative features
- **OOS-7**: Cloud deployment or remote processing
- **OOS-8**: Automated testing frameworks or CI/CD integration
- **OOS-9**: Video editing or annotation capabilities beyond debug overlays
- **OOS-10**: Performance benchmarking or profiling tools

## Dependencies

### External Dependencies
- **ED-1**: Access to BumpSetCut's bestv2.mlpackage CoreML model
- **ED-2**: Python environment with required packages (OpenCV, CoreML Tools, NumPy)
- **ED-3**: macOS system for CoreML model compatibility
- **ED-4**: Sample beach volleyball videos for testing

### Internal Dependencies
- **ID-1**: Understanding of BumpSetCut's current algorithm implementations
- **ID-2**: Access to BumpSetCut iOS app source code for reference
- **ID-3**: Knowledge of current ProcessorConfig parameters and their effects

### Risk Mitigation
- **RM-1**: If CoreML model access is lost, logicsandbox becomes non-functional
- **RM-2**: Changes to iOS app algorithms may require logicsandbox updates
- **RM-3**: Python package compatibility issues may require environment management

## Implementation Notes

### Current Status
The logicsandbox has been successfully implemented with:
- Complete BumpSetCut algorithm parity achieved
- All major components working (ML detection, Kalman tracking, physics validation, rally detection)
- Enhanced debug visualization with trajectory trails and state overlays
- Comprehensive 59-parameter configuration system
- Successful processing of trainingshort2.mov test video

### Key Technical Achievements
- **KTA-1**: Python equivalent of KalmanBallTracker with constant velocity model
- **KTA-2**: BallisticsGate physics validation using quadratic trajectory fitting
- **KTA-3**: RallyDecider hysteresis state machine with IDLE→POTENTIAL→ACTIVE→ENDING transitions
- **KTA-4**: SegmentBuilder for advanced video segmentation with padding and gap merging
- **KTA-5**: Enhanced debug visualization matching BumpSetCut's professional debug mode

### Next Steps
1. Continue parameter experimentation using trainingshort2.mov and other test videos
2. Document optimal parameter configurations discovered through testing
3. Transfer successful parameter optimizations to BumpSetCut iOS app
4. Expand testing with additional beach volleyball video samples as needed