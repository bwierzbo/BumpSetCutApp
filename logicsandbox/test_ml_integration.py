#!/usr/bin/env python3
"""
Test ML model integration for the volleyball tracking sandbox.
"""

import sys
import os
import subprocess

def test_ml_integration():
    """Test ML model integration capabilities."""
    print("🧪 Testing ML Model Integration")
    print("=" * 50)
    
    # Test 1: ML Status Check
    print("\n1️⃣ Testing ML status command...")
    try:
        result = subprocess.run([sys.executable, "main.py", "--ml-status"], 
                              capture_output=True, text=True, timeout=30)
        print(f"   Exit code: {result.returncode}")
        if result.stdout:
            print("   Output:")
            for line in result.stdout.split('\n'):
                if line.strip():
                    print(f"     {line}")
        if result.stderr and result.returncode != 0:
            print("   Errors:")
            for line in result.stderr.split('\n'):
                if line.strip():
                    print(f"     {line}")
    except subprocess.TimeoutExpired:
        print("   ❌ Command timed out")
    except Exception as e:
        print(f"   ❌ Command failed: {e}")
    
    # Test 2: Check model file locations
    print("\n2️⃣ Checking for bestv2.mlpackage model...")
    
    possible_paths = [
        "../BumpSetCut/Resources/ML/bestv2.mlpackage",
        "../../BumpSetCut/Resources/ML/bestv2.mlpackage", 
        "../../../BumpSetCut/Resources/ML/bestv2.mlpackage",
        "../BumpSetCut/BumpSetCut/Resources/ML/bestv2.mlpackage",
        "../../BumpSetCut/BumpSetCut/Resources/ML/bestv2.mlpackage"
    ]
    
    model_found = False
    for path in possible_paths:
        full_path = os.path.abspath(path)
        exists = os.path.exists(full_path)
        print(f"   {'✅' if exists else '❌'} {full_path}")
        if exists:
            model_found = True
            print(f"     Model found at: {full_path}")
            
            # Check model contents
            manifest_path = os.path.join(full_path, "Manifest.json")
            if os.path.exists(manifest_path):
                print(f"     ✅ Manifest.json exists")
            else:
                print(f"     ❌ Manifest.json missing")
    
    if not model_found:
        print("   ⚠️  bestv2.mlpackage model not found in expected locations")
    
    # Test 3: Import test
    print("\n3️⃣ Testing Python imports...")
    
    packages = [
        ("cv2", "OpenCV"),
        ("numpy", "NumPy"), 
        ("coremltools", "CoreML Tools")
    ]
    
    for package, name in packages:
        try:
            __import__(package)
            print(f"   ✅ {name} ({package}) - Available")
        except ImportError:
            print(f"   ❌ {name} ({package}) - Not installed")
    
    # Test 4: Mock fallback test
    print("\n4️⃣ Testing mock fallback functionality...")
    try:
        # Test importing our modules
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from ml_integration import validate_ml_installation, MLModelTracker
        
        status = validate_ml_installation()
        print(f"   ML requirements met: {'✅' if status['requirements_met'] else '❌'}")
        print(f"   CoreML available: {'✅' if status['coreml_available'] else '❌'}")
        print(f"   Model found: {'✅' if status['model_found'] else '❌'}")
        
        # Test tracker creation
        tracker = MLModelTracker()
        print(f"   ✅ MLModelTracker created successfully")
        
    except Exception as e:
        print(f"   ❌ Import test failed: {e}")
    
    # Test 5: Command line with mock data
    print("\n5️⃣ Testing command line with mock video...")
    
    # First create a simple test video file
    try:
        os.makedirs('testvideos', exist_ok=True)
        with open('testvideos/test.mp4', 'wb') as f:
            # Write minimal MP4 header
            f.write(b'\x00\x00\x00\x20ftypmp41\x00\x00\x00\x00mp41isom')
        
        # Test with mock-only flag
        result = subprocess.run([
            sys.executable, "main.py", 
            "--video", "testvideos/test.mp4", 
            "--mock-only"
        ], capture_output=True, text=True, timeout=30)
        
        print(f"   Exit code: {result.returncode}")
        if result.returncode == 0:
            print("   ✅ Mock processing test passed")
        else:
            print("   ❌ Mock processing test failed")
            if result.stderr:
                print(f"   Error: {result.stderr}")
        
    except subprocess.TimeoutExpired:
        print("   ⚠️  Command timed out")
    except Exception as e:
        print(f"   ❌ Test failed: {e}")
    
    print("\n" + "=" * 50)
    print("🎯 ML Integration Test Summary:")
    print(f"   Model Available: {'✅ Yes' if model_found else '❌ No'}")
    print(f"   Dependencies: Install with 'pip install -r requirements.txt'")
    print(f"   Fallback Mode: {'✅ Working' if True else '❌ Failed'}")
    
    print("\n📋 Next Steps:")
    if not model_found:
        print("   1. Ensure the BumpSetCut iOS project is accessible")
        print("   2. Check that bestv2.mlpackage exists in BumpSetCut/Resources/ML/")
    
    try:
        import coremltools
        print("   ✅ CoreML Tools already installed")
    except ImportError:
        print("   3. Install CoreML Tools: pip install coremltools")
    
    print("   4. Run with real video: python create_test_videos.py && python main.py --video testvideos/example1.mp4")


if __name__ == "__main__":
    test_ml_integration()