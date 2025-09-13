#!/usr/bin/env python3
"""
Simple test script for the volleyball tracking sandbox.
Tests basic logic without external dependencies.
"""

import math
import random
import sys
import os

# Mock numpy functions for basic testing
class MockNumPy:
    @staticmethod
    def sqrt(x):
        return math.sqrt(x)
    
    @staticmethod
    def sin(x):
        return math.sin(x)
    
    @staticmethod
    def cos(x):
        return math.cos(x)
    
    @staticmethod
    def pi():
        return math.pi
    
    @staticmethod
    def random_array(shape, dtype=None):
        """Create a mock array for testing."""
        if len(shape) == 3:
            h, w, c = shape
            return [[[random.randint(0, 255) for _ in range(c)] for _ in range(w)] for _ in range(h)]
        return [[random.random() for _ in range(shape[1])] for _ in range(shape[0])]

# Replace numpy import in modules
sys.modules['numpy'] = MockNumPy()
np = MockNumPy()

# Add current directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def create_mock_frame():
    """Create a mock video frame."""
    return np.random_array((720, 1280, 3), dtype='uint8')


def test_basic_functionality():
    """Test basic functionality without heavy dependencies."""
    print("🧪 Testing Basic Volleyball Tracking Logic")
    print("=" * 50)
    
    # Test 1: Mock detections
    print("\n🎾 Test 1: Creating mock ball detections...")
    detections = []
    
    # Create realistic detection pattern
    for i in range(50):
        timestamp = i * 0.2  # 5fps equivalent
        if i % 3 == 0:  # Intermittent detections (realistic)
            x = 100 + 800 * (i / 50.0)  # Left to right movement
            y = 300 + 200 * math.sin((i / 50.0) * math.pi)  # Parabolic arc
            confidence = 0.6 + 0.3 * math.sin(i * 0.5)
            detections.append((timestamp, x, y, confidence))
    
    print(f"   ✅ Created {len(detections)} mock detections")
    
    # Test 2: Segmentation logic
    print("\n📊 Test 2: Basic segmentation logic...")
    
    # Simple segmentation: group continuous detections
    segments = []
    if detections:
        current_start = detections[0][0]
        last_time = detections[0][0]
        
        for timestamp, x, y, confidence in detections[1:]:
            gap = timestamp - last_time
            if gap > 1.0:  # 1 second gap threshold
                segments.append((current_start, last_time))
                current_start = timestamp
            last_time = timestamp
        
        # Add final segment
        segments.append((current_start, last_time))
    
    print(f"   ✅ Found {len(segments)} potential rally segments:")
    for i, (start, end) in enumerate(segments, 1):
        duration = end - start
        print(f"      Segment {i}: {start:.1f}s - {end:.1f}s (duration: {duration:.1f}s)")
    
    # Test 3: Basic analysis
    print("\n🏐 Test 3: Basic rally analysis...")
    
    total_rally_time = sum(end - start for start, end in segments)
    avg_duration = total_rally_time / len(segments) if segments else 0
    
    # Simple contact estimation based on direction changes
    contacts_estimated = 0
    if len(detections) > 2:
        direction_changes = 0
        for i in range(2, len(detections)):
            # Simple direction change detection
            prev_x = detections[i-1][1] - detections[i-2][1]
            curr_x = detections[i][1] - detections[i-1][1]
            
            if prev_x * curr_x < 0:  # Sign change = direction change
                direction_changes += 1
        
        contacts_estimated = max(1, direction_changes // 2)
    
    print(f"   ✅ Analysis results:")
    print(f"      Total rally time: {total_rally_time:.1f}s")
    print(f"      Average rally duration: {avg_duration:.1f}s")
    print(f"      Estimated ball contacts: {contacts_estimated}")
    
    # Test 4: Configuration validation
    print("\n⚙️  Test 4: Configuration validation...")
    
    config = {
        'min_rally_duration': 2.0,
        'max_gap_duration': 1.5,
        'start_buffer': 0.5,
        'end_buffer': 0.3,
        'confidence_threshold': 0.4
    }
    
    # Validate configuration
    valid = True
    if config['min_rally_duration'] <= 0:
        print("   ❌ Invalid min_rally_duration")
        valid = False
    if config['confidence_threshold'] < 0 or config['confidence_threshold'] > 1:
        print("   ❌ Invalid confidence_threshold")
        valid = False
    
    if valid:
        print("   ✅ Configuration is valid:")
        for key, value in config.items():
            print(f"      {key}: {value}")
    
    print("\n" + "=" * 50)
    print("✅ Basic functionality tests completed!")
    print("\nNext steps to run the full sandbox:")
    print("1. Install dependencies: pip install opencv-python numpy")
    print("2. Create test videos: python create_test_videos.py")
    print("3. Run full analysis: python main.py --video testvideos/example1.mp4")
    
    return True


def main():
    """Run basic tests."""
    try:
        return test_basic_functionality()
    except Exception as e:
        print(f"\n❌ Test failed: {e}")
        import traceback
        traceback.print_exc()
        return False


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)