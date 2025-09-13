# Logicsandbox Usage Guide

The logicsandbox is a Python-based volleyball video analysis environment that provides exact algorithmic parity with the BumpSetCut iOS app. Use it for parameter experimentation, testing, and optimization.

## 🚀 **Quick Start**

### **Navigate to Logicsandbox**
```bash
cd /Users/benjaminwierzbanowski/Code/BumpSetCut/logicsandbox
```

### **Install Dependencies** (if needed)
```bash
pip install -r requirements.txt
```

## 📹 **Video Analysis Commands**

### **1. Simple Video Analysis** (Recommended)
```bash
python3 analyze_video_simple.py --video testvideos/trainingshort2.mov --output results/
```
- **Works reliably** without dependency issues
- **Processes video** with timestamp overlays
- **Generates** processed video and analysis results
- **Fast processing** (~113 fps for test video)

### **2. Advanced Video Analysis** (Full ML Pipeline)
```bash
python3 analyze_video.py --video testvideos/trainingshort2.mov --output results/
```
- **Uses bestv2.mlpackage** ML model for volleyball detection
- **Full pipeline** with tracking and rally detection
- **May have dependency issues** (numpy version conflicts)

### **3. Main Processing Script**
```bash
python3 main.py
```
- **Default processing** with embedded test video
- **Comprehensive pipeline** testing

### **4. Quick Test**
```bash
python3 simple_test.py
```
- **Basic functionality** verification
- **Quick sanity check**

## 🎛️ **Command Options**

### **Common Flags**
- `--debug` or `-d`: Enable detailed debug output
- `--video` or `-v`: Specify input video file
- `--output` or `-o`: Specify output directory
- `--no-annotated`: Skip annotated video creation (faster)

### **Examples**
```bash
# Debug mode with detailed output
python3 analyze_video_simple.py --video testvideos/trainingshort2.mov --output results/ --debug

# Process different video
python3 analyze_video_simple.py --video testvideos/trainingmedium.mov --output medium_results/

# Fast processing without annotated video
python3 analyze_video.py --video testvideos/trainingshort2.mov --output results/ --no-annotated
```

## 📂 **Available Test Videos**

Located in `testvideos/` directory:
- `trainingshort2.mov` - 9.18s, 1920x1080, 58.7fps (recommended for testing)
- `trainingmedium.mov` - Medium length volleyball video
- `Debug_trainingshort.mp4` - Pre-processed debug video
- `Debug_trainingmedium.mp4` - Pre-processed debug video

## 📊 **Output Files**

### **analyze_video_simple.py generates:**
- `processed_video.mp4` - Video with timestamp and analysis overlays
- `analysis_results.json` - Processing statistics and detection data

### **analyze_video.py generates:**
- `annotated_video.mp4` - Full ML pipeline annotated video
- `detections.json` - Detailed volleyball detection results
- `visualization_report/` - Comprehensive analysis reports

## ⚙️ **Configuration & Parameters**

### **Processor Configuration**
Edit `processor_config.py` to modify processing parameters:
- **Detection thresholds** - Confidence levels for volleyball detection
- **Tracking parameters** - Kalman filter settings
- **Physics validation** - Ballistic trajectory constraints
- **Rally detection** - State machine hysteresis settings

### **Available Presets**
- `default` - Balanced performance and accuracy
- `conservative` - High precision, fewer false positives
- `aggressive` - Maximum coverage, more detections
- `high_precision` - Strictest validation for professional analysis

## 🔧 **Troubleshooting**

### **Dependency Issues**
If you encounter numpy version conflicts:
```bash
pip install "numpy>=1.22.0,<1.28.0" --force-reinstall
```

### **Permission Issues**
Ensure output directory is writable:
```bash
mkdir -p results/
chmod 755 results/
```

### **Video File Issues**
- Check video file exists: `ls testvideos/`
- Verify video format is supported (MP4, MOV)
- Try different video if one fails

### **Memory Issues**
For large videos, use the `--no-annotated` flag or process in chunks.

## 🎯 **Performance Benchmarks**

Based on `trainingshort2.mov` (9.18s, 1920x1080):
- **Simple Analysis**: ~113 fps processing speed
- **ML Analysis**: ~64.1% average detection confidence
- **Processing Time**: <5 seconds for test videos
- **Output Quality**: Professional debug visualization

## 🔄 **Integration with iOS App**

The logicsandbox provides exact algorithmic parity with BumpSetCut iOS app:
1. **Experiment** with parameters in Python
2. **Export optimized** settings via parameter transfer workflow
3. **Apply settings** to iOS ProcessorConfig.swift
4. **Validate improvements** in production app

## 📚 **Advanced Usage**

### **Batch Processing**
```bash
for video in testvideos/*.mov; do
    python3 analyze_video_simple.py --video "$video" --output "results/$(basename "$video" .mov)/"
done
```

### **Custom Configuration**
```python
# Edit processor_config.py
config = ProcessorConfig()
config.detectionThreshold = 0.7  # Higher confidence
config.enableEnhancedPhysics = True  # Stricter physics
```

### **Performance Testing**
```bash
python3 test_video_coverage.py  # Test multiple videos and configurations
```

## 🎥 **Expected Results**

When working correctly, you should see:
- **Clear processing output** with frame counts and timing
- **Generated video files** with visible overlays
- **JSON results** with detection statistics
- **Processing speeds** over 50 fps for typical videos

The logicsandbox is production-ready and provides a reliable environment for volleyball video analysis and parameter optimization!