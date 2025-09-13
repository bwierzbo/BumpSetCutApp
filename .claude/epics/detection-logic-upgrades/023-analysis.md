---
issue: 23
epic: detection-logic-upgrades
task: 003
analyzed: 2025-09-03T01:55:20Z
streams: 3
---

# Issue #23 Work Stream Analysis

## Overview
Create a comprehensive MetricsCollector service for quantitative accuracy measurement and performance monitoring. This addresses the user's core need: "I really need metrics to track so I can determine the accuracy of my settings and can tweak with actual numeric accuracy values."

## Core Requirements
- Precision/recall tracking against ground truth data
- Performance monitoring (processing time, memory, CPU)
- Multiple export formats (JSON, CSV, binary)
- <5% performance overhead
- Thread-safe operation
- Integration with enhanced BallisticsGate (Issue #21)

## Parallel Streams

### Stream A: Core MetricsCollector Architecture
- **Agent Type**: code-analyzer
- **Files**: 
  - `BumpSetCut/Domain/Services/MetricsCollector.swift` (new)
  - `BumpSetCut/Data/Models/MetricsData.swift` (new)
- **Scope**: Core metrics collection architecture, data structures, thread-safe collection
- **Dependencies**: None (foundation component)
- **Estimated Time**: 3 hours

### Stream B: Accuracy Metrics & Ground Truth Integration
- **Agent Type**: code-analyzer
- **Files**:
  - `BumpSetCut/Domain/Logic/AccuracyMetrics.swift` (new)
  - `BumpSetCut/Data/Models/GroundTruthData.swift` (new)
- **Scope**: Precision/recall calculations, ground truth data handling, trajectory validation accuracy
- **Dependencies**: None (can run parallel with Stream A)
- **Estimated Time**: 3 hours

### Stream C: Export & Performance Integration
- **Agent Type**: code-analyzer  
- **Files**:
  - `BumpSetCut/Infrastructure/Export/MetricsExporter.swift` (new)
  - `BumpSetCut/Domain/Logic/PerformanceMonitor.swift` (new)
  - VideoProcessor integration points
- **Scope**: Export functionality, performance monitoring, VideoProcessor integration
- **Dependencies**: Waits for Streams A & B (needs core architecture)
- **Estimated Time**: 2 hours

## Integration Points

### With Enhanced BallisticsGate (Issue #21)
- Hook into `isValidProjectile()` calls for accuracy tracking
- Collect trajectory quality scores and classification results
- Monitor physics validation performance impact

### With VideoProcessor Pipeline
- Integrate metrics collection at key processing points
- Collect frame processing times and detection accuracy
- Monitor memory usage and CPU utilization

## Data Collection Strategy

### Accuracy Metrics
- **True Positives**: Correctly identified volleyball trajectories
- **False Positives**: Incorrectly accepted non-volleyball motion
- **False Negatives**: Missed volleyball trajectories  
- **Precision**: TP/(TP+FP) - accuracy of accepted trajectories
- **Recall**: TP/(TP+FN) - coverage of actual volleyball motion

### Performance Metrics
- Frame processing time per detection cycle
- Memory usage during trajectory analysis
- CPU utilization during physics validation
- Enhanced vs baseline processing time comparison

### Export Formats
- **JSON**: Human-readable, web-dashboard friendly
- **CSV**: Spreadsheet analysis, statistical tools
- **Binary**: High-frequency data, minimal overhead

## Coordination Notes

### Stream A (Foundation)
- Must establish core MetricsCollector architecture
- Creates thread-safe collection mechanisms
- Defines data structures for all metric types

### Stream B (Parallel)
- Implements accuracy calculation algorithms
- Handles ground truth data integration
- Can develop independently of core collector

### Stream C (Integration)
- Integrates completed components with VideoProcessor
- Implements export functionality using Stream A data structures
- Validates performance overhead requirements

## Definition of Done
- MetricsCollector integrated with VideoProcessor pipeline
- Precision/recall tracking operational with ground truth data
- Performance monitoring shows <5% overhead
- Export functionality supports JSON, CSV, binary formats
- Thread-safe operation validated
- Configurable sampling rates implemented
- Real-time metrics capability demonstrated

## Success Metrics
- Quantitative accuracy measurement capability delivered
- User can "determine accuracy of settings and tweak with actual numeric values"
- Performance impact <5% validated through measurement
- Foundation established for Issue #24 (Parameter Optimization)