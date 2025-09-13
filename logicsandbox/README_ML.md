# Volleyball ML Model Testing & Visualization

**Real ML model testing sandbox using `bestv2.mlpackage` from BumpSetCut iOS app**

## 🎯 Purpose

Test the actual `bestv2.mlpackage` volleyball detection model and visualize results with comprehensive post-processing analysis. **No mock simulation** - only real ML model inference and visualization.

## 🚀 Quick Start

```bash
# Install dependencies
pip install -r requirements.txt

# Analyze a video with full visualization
python analyze_video.py --video input.mp4 --output results/

# Debug mode for detailed output
python analyze_video.py --video input.mp4 --output results/ --debug

# Skip annotated video creation for faster processing
python analyze_video.py --video input.mp4 --output results/ --no-annotated
```

## 🏗️ Architecture

### Core Components

- **`ml_detector.py`**: Real `bestv2.mlpackage` model integration
- **`analyze_video.py`**: Main analysis pipeline
- **`visualization.py`**: Post-processing visualization
- **`segmentation.py`**: Rally segmentation from ML detections
- **`rally_analysis.py`**: Rally metadata extraction

### ML Model Pipeline

```
Video Input → bestv2.mlpackage → Ball Detections → Rally Segmentation → Visualization
```

## 📊 Output Files

For each analyzed video, the sandbox generates:

```
results/
├── detections.json           # Raw ML detection data
├── annotated_video.mp4       # Video with detection overlays
├── detection_summary.png     # Detection analysis plots
├── rally_analysis.png        # Rally segmentation plots
└── analysis_report.json      # Comprehensive results
```

## 🎬 Visualization Features

### Annotated Video
- **Green bounding boxes** around detected volleyballs
- **Orange trajectory lines** showing ball movement
- **Red frame borders** during active rally periods
- **Real-time confidence scores** and frame information

### Analysis Plots
- **Detection confidence timeline**
- **Ball position trajectory map**
- **Detection frequency distribution**
- **Rally duration statistics**

### JSON Reports
- Complete detection data with timestamps
- Rally segment boundaries
- Processing performance metrics
- Model configuration details

## 🤖 Model Integration Details

### bestv2.mlpackage Support
- **Automatic discovery** from iOS app bundle
- **YOLO preprocessing**: Resize, normalize, RGB conversion
- **NMS post-processing**: Remove duplicate detections
- **Confidence filtering**: Configurable detection threshold

### Performance
- **Real-time capable**: Processes at video frame rate
- **Batch processing**: Handles videos of any length
- **Memory efficient**: Streams video without loading entire file

## 📈 Rally Analysis

### Segmentation Logic
- Groups ML detections into continuous periods
- Configurable gap tolerance and minimum duration
- Buffers rally start/end times for complete coverage

### Quality Metrics
- Detection density per rally
- Average confidence scores
- Trajectory complexity analysis
- Rally duration distribution

## 🛠️ Configuration

### Detection Parameters
```python
confidence_threshold = 0.3    # Minimum detection confidence
nms_threshold = 0.4          # Non-maximum suppression
input_size = (640, 640)      # Model input resolution
```

### Rally Parameters
```python
min_rally_duration = 2.0     # Minimum rally length (seconds)
max_gap_duration = 1.5       # Maximum gap within rally
start_buffer = 0.5           # Pre-rally buffer
end_buffer = 0.3             # Post-rally buffer
```

## 🔧 Development Workflow

1. **Test with real videos**: Use actual volleyball footage
2. **Analyze ML performance**: Review detection accuracy and coverage
3. **Visualize results**: Examine annotated videos and plots
4. **Tune parameters**: Adjust thresholds based on results
5. **Export insights**: Use findings to improve iOS app

## 📋 Requirements

- **Python 3.8+**
- **OpenCV**: Video processing and visualization
- **CoreML Tools**: ML model inference
- **NumPy**: Numerical computations  
- **Matplotlib**: Plot generation

## 🎪 Example Results

### Detection Statistics
```
Total detections: 1,247
Average confidence: 0.742
Processing speed: 28.3 fps
Rally coverage: 34.2% of video
```

### Rally Analysis
```
Total rallies: 8
Average duration: 12.4s
Longest rally: 28.7s
Detection density: 4.2 per second
```

## 🔄 Integration with iOS App

Analysis results can inform iOS app improvements:

- **Confidence threshold tuning** based on real performance
- **Rally detection parameters** optimized for actual footage  
- **Processing performance** benchmarks for mobile deployment
- **Quality metrics** to validate detection accuracy

---

**🏐 Focus**: Real ML model testing and comprehensive visualization - no mock data, just actual `bestv2.mlpackage` performance analysis.