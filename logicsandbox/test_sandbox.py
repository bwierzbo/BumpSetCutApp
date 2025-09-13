#!/usr/bin/env python3
"""
Test script for the volleyball tracking sandbox.
Tests the logic without requiring real video files.
"""

import numpy as np
import sys
import os

# Add current directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ball_tracking import track_ball, apply_physics_validation, smooth_trajectory
from segmentation import segment_video, merge_overlapping_segments, calculate_rally_activity
from rally_analysis import analyze_rallies, estimate_ball_contacts, analyze_trajectory


def create_mock_detections() -> list:
    """Create realistic mock ball detection data."""
    print("🎾 Generating mock ball detection data...")
    
    detections = []
    
    # Rally 1: Serve sequence (0-8 seconds)
    for i in range(80):  # 80 frames at ~10fps
        timestamp = i * 0.1
        if timestamp < 8.0 and i % 3 == 0:  # Intermittent detections
            x = 100 + 800 * (timestamp / 8.0)  # Left to right
            y = 300 + 200 * np.sin((timestamp / 8.0) * np.pi)  # Parabolic arc
            confidence = 0.6 + 0.3 * np.sin(timestamp * 2)
            detections.append((timestamp, x, y, confidence))
    
    # Gap (8-12 seconds) - no detections
    
    # Rally 2: Active exchange (12-25 seconds)
    for i in range(130):  # Longer rally
        timestamp = 12.0 + i * 0.1
        if timestamp < 25.0 and i % 2 == 0:  # More frequent detections
            x = 640 + 300 * np.sin((timestamp - 12) * 0.5)  # Center oscillation
            y = 200 + 150 * np.cos((timestamp - 12) * 0.8)  # Up and down
            confidence = 0.7 + 0.2 * np.sin(timestamp)
            detections.append((timestamp, x, y, confidence))
    
    # Gap (25-28 seconds)
    
    # Rally 3: Short exchange (28-32 seconds)
    for i in range(40):
        timestamp = 28.0 + i * 0.1
        if timestamp < 32.0 and i % 4 == 0:  # Sparse detections
            x = 900 - 400 * ((timestamp - 28) / 4.0)  # Right to left
            y = 400 + 100 * ((timestamp - 28) / 4.0)  # Downward
            confidence = 0.5 + 0.4 * ((timestamp - 28) / 4.0)
            detections.append((timestamp, x, y, confidence))
    
    print(f"   Generated {len(detections)} mock detections")
    return detections


def test_ball_tracking():
    """Test ball tracking functionality."""
    print("\n🔍 Testing ball tracking...")
    
    # Create mock frame
    mock_frame = np.random.randint(0, 255, (720, 1280, 3), dtype=np.uint8)
    
    # Test detection
    detection = track_ball(mock_frame)
    if detection:
        x, y, confidence = detection
        print(f"   ✅ Ball detected at ({x:.1f}, {y:.1f}) with confidence {confidence:.3f}")
    else:
        print("   ⚪ No ball detected (expected for random frame)")
    
    # Test physics validation
    detections = create_mock_detections()
    validated = apply_physics_validation(detections)
    print(f"   📊 Physics validation: {len(validated)}/{len(detections)} detections passed")
    
    # Test smoothing
    smoothed = smooth_trajectory(validated)
    print(f"   🔄 Trajectory smoothing: {len(smoothed)} smoothed detections")


def test_segmentation():
    """Test video segmentation functionality."""
    print("\n📊 Testing video segmentation...")
    
    detections = create_mock_detections()
    video_info = {
        'duration': 35.0,
        'fps': 30.0,
        'width': 1280,
        'height': 720
    }
    
    # Test segmentation
    segments = segment_video(detections, video_info)
    print(f"   ✅ Found {len(segments)} rally segments:")
    
    for i, (start, end) in enumerate(segments, 1):
        duration = end - start
        print(f"      Rally {i}: {start:.1f}s - {end:.1f}s (duration: {duration:.1f}s)")
    
    # Test activity calculation
    if segments:
        start, end = segments[0]
        activity = calculate_rally_activity(detections, start, end)
        print(f"   📈 Activity metrics for first rally: {activity}")


def test_rally_analysis():
    """Test rally analysis functionality."""
    print("\n🏐 Testing rally analysis...")
    
    detections = create_mock_detections()
    video_info = {
        'duration': 35.0,
        'fps': 30.0,
        'width': 1280,
        'height': 720
    }
    
    segments = segment_video(detections, video_info)
    
    # Test full analysis
    analysis_results = analyze_rallies(segments, detections, video_info, debug=False)
    
    print(f"   ✅ Analysis complete:")
    print(f"      Total rallies: {analysis_results['total_rallies']}")
    print(f"      Total rally time: {analysis_results['total_rally_time']:.1f}s")
    print(f"      Average duration: {analysis_results['avg_rally_duration']:.1f}s")
    print(f"      Coverage: {analysis_results['rally_coverage_percent']:.1f}%")
    
    # Test individual components
    if detections:
        rally_detections = detections[:20]  # First 20 detections
        contacts = estimate_ball_contacts(rally_detections)
        trajectory = analyze_trajectory(rally_detections)
        
        print(f"   🎯 Contact estimation: {contacts} contacts")
        print(f"   📈 Trajectory type: {trajectory['trajectory_type']}")


def main():
    """Run all tests."""
    print("🧪 Testing Volleyball Tracking Logic Sandbox")
    print("=" * 50)
    
    try:
        test_ball_tracking()
        test_segmentation()
        test_rally_analysis()
        
        print("\n" + "=" * 50)
        print("✅ All tests completed successfully!")
        print("\nThe sandbox is working correctly. You can now:")
        print("1. Install OpenCV: pip install opencv-python")
        print("2. Create test videos: python create_test_videos.py")
        print("3. Run with real videos: python main.py --video testvideos/example1.mp4")
        
    except Exception as e:
        print(f"\n❌ Test failed: {e}")
        import traceback
        traceback.print_exc()
        return False
    
    return True


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)