---
created: 2025-09-01T15:19:09Z
last_updated: 2025-09-01T15:19:09Z
version: 1.0
author: Claude Code PM System
---

# Technology Context

## Platform & Language

**Primary Platform:** iOS (iPhone/iPad)  
**Language:** Swift (SwiftUI framework)  
**Deployment Target:** iOS 15+ (inferred from @Observable usage)  
**Development Environment:** Xcode

## Core Technology Stack

### UI Framework
- **SwiftUI**: Modern declarative UI framework
- **@Observable**: State management pattern (iOS 17+)
- **NavigationStack**: Modern navigation paradigm
- **Modal Presentation**: Custom popup system via MijickPopups

### Computer Vision & Machine Learning
- **CoreML**: Apple's on-device machine learning framework
- **Vision**: High-level computer vision APIs
- **YOLO**: Object detection model (volleyball-specific training)
- **Custom Models**: Specialized volleyball detection algorithms

### Video Processing
- **AVFoundation**: Core video processing and playback
- **AVAssetReader**: Frame-by-frame video analysis
- **CoreImage**: Image processing and filtering
- **Metal**: GPU-accelerated processing (via CoreML)

### Third-Party Dependencies

#### Camera Integration
- **MijickCamera**: Modern SwiftUI camera capture library
- **Features**: Video recording, photo capture, custom controls
- **Integration**: Modal camera interface with custom UI

#### UI Components
- **MijickPopups**: SwiftUI modal and popup system
- **Features**: Bottom sheets, overlays, custom presentations
- **Usage**: Camera capture modal, processing status displays

## Algorithmic Components

### Object Detection
- **YOLO-based Detection**: Real-time volleyball detection
- **Static Object Suppression**: Filters out non-moving objects
- **Confidence Thresholding**: Quality-based detection filtering
- **CoreML Integration**: On-device inference for privacy

### Object Tracking
- **Kalman Filter**: Constant-velocity motion model
- **Association Gating**: Matches detections to tracks
- **Trajectory Prediction**: Forward motion estimation
- **Track Management**: Birth/death lifecycle handling

### Physics Validation
- **Ballistics Modeling**: Projectile motion verification
- **Quadratic Fitting**: Parabolic trajectory analysis
- **Gravity Compensation**: Physical constraint validation
- **Noise Filtering**: Removes impossible trajectories

### Rally Detection
- **State Machine**: Hysteresis-based rally detection
- **Evidence Accumulation**: Time-windowed decision making
- **Configurable Thresholds**: Tunable sensitivity parameters
- **Temporal Smoothing**: Reduces false positive/negative rates

## Performance Optimizations

### Processing Efficiency
- **Frame Skipping**: Debug mode processes every 3rd frame
- **Async Processing**: Non-blocking video analysis
- **Memory Management**: Explicit resource cleanup
- **GPU Acceleration**: CoreML leverages Neural Engine/GPU

### Data Handling
- **Streaming Processing**: Frame-by-frame analysis
- **Lazy Loading**: On-demand resource allocation  
- **File-Based Storage**: Efficient local storage without database overhead
- **Background Processing**: Non-UI blocking operations

## Development Tools & Environment

### Build System
- **Xcode Build System**: Standard iOS compilation
- **Swift Package Manager**: Dependency management (if used)
- **Code Signing**: Apple Developer Program integration

### Development Workflow
- **Version Control**: Git with GitHub integration
- **Branch Strategy**: Main branch development
- **Testing**: Manual testing with video samples
- **Distribution**: Standard iOS App Store process

## System Requirements

### Device Capabilities
- **Camera**: Video recording capability required
- **Storage**: Local video file storage
- **Processing Power**: CoreML inference capability
- **Memory**: Sufficient for video processing and ML models

### iOS Features Used
- **File System Access**: Documents directory manipulation
- **Camera Permissions**: AVFoundation camera access
- **Photo Library**: Video import/export capabilities
- **Background Processing**: Video analysis tasks

## Configuration Management

### Processing Parameters
- **Centralized Config**: ProcessorConfig class
- **Runtime Tunable**: Physics and detection thresholds
- **Debug Settings**: Processing mode switches
- **Export Options**: Video quality and format settings

### Model Configuration
- **ML Model Loading**: Runtime CoreML model initialization
- **Detection Thresholds**: Confidence and NMS parameters
- **Tracking Parameters**: Kalman filter noise models
- **Physics Constants**: Gravity, air resistance, court dimensions

## Integration Patterns

### Data Flow
```
Camera/File → AVAsset → Frame Extraction → Detection → Tracking → Physics → Rally Logic → Export
```

### State Management
```
@Observable VideoProcessor ← ProcessVideoView
@Observable MediaStore ← LibraryView, ContentView
```

### Error Handling
- **Graceful Degradation**: Continue processing with warnings
- **User Feedback**: Clear error messages in UI
- **Resource Recovery**: Cleanup on failure conditions
- **Logging**: Comprehensive error tracking

## Future Technology Considerations

### Scalability
- **Cloud Processing**: Potential server-side analysis
- **Model Updates**: Over-the-air ML model updates
- **Multi-Platform**: Potential macOS/tvOS expansion
- **Real-Time Processing**: Live camera analysis capabilities

### Performance Improvements
- **Metal Shaders**: Custom GPU processing
- **Vision Framework**: Enhanced detection capabilities
- **CoreML Optimization**: Model quantization and optimization
- **Parallel Processing**: Multi-threaded analysis pipeline