---
created: 2025-09-01T15:19:09Z
last_updated: 2025-09-01T15:19:09Z
version: 1.0
author: Claude Code PM System
---

# Project Brief

## What BumpSetCut Does

BumpSetCut is an iOS app that uses artificial intelligence to automatically identify and extract volleyball rally segments from recorded videos. The app analyzes video footage frame-by-frame, tracks volleyball movement using computer vision, and creates clean, shareable clips of the most important moments.

**Core Capability:** Transform hours of volleyball footage into a curated collection of rally highlights with zero manual editing required.

## Why This Project Exists

### The Problem
Volleyball players, coaches, and analysts spend countless hours manually reviewing game footage to find and extract meaningful rally sequences. Traditional video editing requires:
- Manually scrubbing through entire games to find action
- Determining exact start/stop points for each rally
- Technical video editing skills to create clean segments
- Significant time investment that scales poorly with video volume

### The Solution Approach
Leverage modern computer vision and machine learning to automate the detection and segmentation process:
- **Intelligent Detection**: YOLO-based object detection specifically trained for volleyball recognition
- **Physics-Informed Tracking**: Kalman filter tracking validated by real-world physics constraints  
- **Smart Segmentation**: Evidence-based rally boundary detection using hysteresis logic
- **Mobile-Native Processing**: On-device processing for privacy and immediate results

### Technical Innovation
The system combines multiple AI/ML techniques in a sophisticated pipeline:
1. **Computer Vision**: CoreML-powered volleyball detection with static object suppression
2. **Object Tracking**: Kalman filter with association gating for trajectory consistency  
3. **Physics Modeling**: Ballistics validation using projectile motion equations
4. **State Machine Logic**: Hysteresis-based rally detection to prevent false triggers
5. **Temporal Analysis**: Time-windowed decision making for robust boundary detection

## Project Goals & Objectives

### Primary Goals
1. **Automation**: Eliminate manual video editing for volleyball rally extraction
2. **Accuracy**: Achieve high precision in rally detection with minimal false positives
3. **Performance**: Process typical game videos in reasonable time on mobile devices
4. **Usability**: Create intuitive mobile-first user experience requiring no technical expertise

### Technical Objectives
- **Detection Accuracy**: >95% correct identification of actual rally sequences
- **Processing Speed**: Process 1 hour of video in <10 minutes on modern iPhone
- **Resource Efficiency**: Memory usage under 500MB for typical processing tasks
- **Reliability**: <5% failure rate across diverse video conditions

### User Experience Objectives
- **Simplicity**: Single-tap processing with intelligent defaults
- **Transparency**: Debug mode to build user trust in automated decisions
- **Flexibility**: Support various video formats and quality levels
- **Integration**: Seamless iOS ecosystem integration (Photos, sharing, etc.)

## Success Criteria

### Technical Success Metrics
✅ **Rally Detection Working**: Recent commits show "rally is working well"  
✅ **Performance Optimization**: Successfully implemented 3-frame processing for debug mode  
✅ **Modular Architecture**: Major refactoring completed with clean separation of concerns  
✅ **Debug Visualization**: Comprehensive debug mode with detection overlays implemented

### Development Milestones Achieved
- ✅ Core computer vision pipeline operational
- ✅ Physics-based validation system implemented  
- ✅ Debug visualization and performance optimization
- ✅ Clean iOS app architecture with SwiftUI integration
- ✅ File management and video export functionality

### Outstanding Success Criteria
- 📋 Formal testing framework implementation
- 📋 Performance benchmarking across device types
- 📋 User acceptance testing with volleyball community
- 📋 App Store deployment and user feedback integration

## Project Scope

### In Scope
**Core Functionality:**
- Automated volleyball rally detection and extraction
- Debug mode for algorithm transparency and validation
- iOS native app with camera integration and file management
- On-device processing with no cloud dependencies

**Technical Implementation:**
- SwiftUI-based mobile interface optimized for volleyball workflows
- CoreML integration for efficient on-device machine learning inference
- Multi-stage processing pipeline with configurable parameters
- Comprehensive error handling and graceful degradation

### Out of Scope (Current Phase)
- **Multi-Sport Support**: Focus remains volleyball-specific
- **Cloud Processing**: All processing remains on-device for privacy
- **Real-Time Analysis**: Current focus on post-recording processing
- **Advanced Editing**: Basic segmentation only, not full video editor replacement
- **Social Features**: Sharing via standard iOS mechanisms, no custom social platform

### Future Scope Considerations
- **Performance Analytics**: Detailed rally statistics and performance metrics
- **Multi-Camera Support**: Synchronized processing from multiple camera angles  
- **Real-Time Mode**: Live rally detection during recording
- **Cloud Backup**: Optional cloud storage for processed videos
- **Coaching Tools**: Advanced analysis features for professional coaching use

## Key Success Indicators

### Current Status Assessment
**✅ Technical Foundation Solid**
- Robust computer vision pipeline with volleyball-specific intelligence
- Clean, maintainable architecture supporting future enhancements
- Performance optimizations proven effective (3-frame debug processing)

**✅ Core Functionality Operational**  
- Rally detection algorithm working reliably ("rally is working well")
- Debug mode providing transparency and validation capabilities
- Complete iOS app with intuitive user interface

**📋 Ready for Validation Phase**
- Need formal testing framework to validate accuracy claims
- Require user testing with target volleyball community
- Performance benchmarking across different device capabilities

### Definition of Done
The project will be considered successfully complete when:
1. **Accuracy Validated**: Formal testing confirms >90% rally detection accuracy
2. **Performance Verified**: Benchmarking confirms acceptable processing speeds across target devices
3. **User Validated**: Volleyball community testing confirms ease of use and value proposition
4. **Production Ready**: App Store deployment with initial user feedback integration

This represents a sophisticated technical achievement combining multiple AI/ML disciplines to solve a real problem in the volleyball community while maintaining the highest standards of user experience and technical excellence.