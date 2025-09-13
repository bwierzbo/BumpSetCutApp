# Volleyball Tracking Logic Sandbox

A standalone Python testbed for iterating on volleyball ball tracking, segmentation, and rally analysis logic outside the iOS environment.

## Overview

This sandbox simulates the core volleyball detection and analysis pipeline from the BumpSetCut iOS app, allowing for rapid prototyping and testing of algorithm improvements.

## Features

- **Ball Tracking**: Frame-by-frame volleyball detection with confidence scoring
- **Rally Segmentation**: Automatic identification of rally periods vs dead time
- **Rally Analysis**: Detailed metadata extraction including estimated contacts, trajectory analysis, and quality scoring
- **Mock Data Generation**: Realistic test videos for consistent testing

## Quick Start

1. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

2. **Create test videos**:
   ```bash
   python create_test_videos.py
   ```

3. **Run analysis**:
   ```bash
   python main.py --video testvideos/example1.mp4
   ```

## Usage Examples

```bash
# Basic analysis with real ML model
python main.py --video testvideos/example1.mp4

# Debug mode with detailed output
python main.py --video testvideos/example2.mp4 --debug

# Use mock detection only (skip ML model)
python main.py --video testvideos/example1.mp4 --mock-only

# Check ML model integration status
python main.py --ml-status

# Save results to JSON
python main.py --video testvideos/example3.mp4 --output results.json
```

## Architecture

### Core Modules

- **`main.py`**: CLI interface and orchestration
- **`ball_tracking.py`**: Ball detection and trajectory tracking
- **`segmentation.py`**: Rally segmentation logic
- **`rally_analysis.py`**: Rally metadata analysis
- **`ml_integration.py`**: Real ML model integration (bestv2.mlpackage)

### ML Model Integration

The sandbox now supports **both real ML model inference and mock detection**:

#### Real ML Model (bestv2.mlpackage)
- **Automatic Detection**: Finds the bestv2.mlpackage model from the iOS app bundle
- **CoreML Integration**: Uses Apple's CoreML Tools for Python inference
- **YOLO Processing**: Handles YOLO-style preprocessing and postprocessing
- **Fallback Support**: Gracefully falls back to mock detection if model unavailable

#### Mock Implementation
- **Ball Tracking**: Generates parabolic trajectories with realistic confidence patterns
- **Segmentation**: Groups detections into rally periods using configurable thresholds
- **Analysis**: Estimates ball contacts and trajectory characteristics

### Configuration

Key parameters that mirror the iOS app configuration:

```python
{
    'min_rally_duration': 2.0,      # Minimum rally length (seconds)
    'max_gap_duration': 1.5,        # Maximum gap within rally
    'start_buffer': 0.5,            # Buffer before rally start
    'end_buffer': 0.3,              # Buffer after rally end
    'confidence_threshold': 0.4      # Minimum detection confidence
}
```

## Integration with iOS App

This sandbox is designed to facilitate algorithm development that can be integrated back into the BumpSetCut iOS app:

1. **Test algorithms here** with rapid iteration
2. **Port successful algorithms** to Swift/Core ML
3. **Validate consistency** between Python and iOS implementations

### Key iOS App Equivalents

| Python Module | iOS App Component |
|---------------|------------------|
| `ball_tracking.py` | `BallTracker.swift` |
| `segmentation.py` | `RallyDetector.swift` |
| `rally_analysis.py` | `RallyAnalyzer.swift` |

## Testing

The sandbox includes three test videos with different characteristics:

- **`example1.mp4`**: Short serve trajectory (15s)
- **`example2.mp4`**: Active rally with exchanges (25s)  
- **`example3.mp4`**: Short clip with different frame rate (10s, 24fps)

## Development Workflow

1. **Iterate on algorithms** in Python modules
2. **Test with mock videos** using various parameters
3. **Validate results** match expected volleyball behavior
4. **Export configurations** for iOS integration

## Future Enhancements

- [ ] Real ML model integration (YOLOv8, etc.)
- [ ] Physics-based trajectory validation
- [ ] Advanced trajectory classification
- [ ] Performance benchmarking suite
- [ ] Real video dataset testing

## Dependencies

- Python 3.8+
- OpenCV 4.8+
- NumPy 1.24+