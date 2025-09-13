#!/usr/bin/env python3
"""
Setup script for the volleyball tracking logic sandbox.
"""

import subprocess
import sys
import os


def install_requirements():
    """Install required packages."""
    print("📦 Installing required packages...")
    
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-r", "requirements.txt"])
        print("✅ Dependencies installed successfully")
        return True
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to install dependencies: {e}")
        return False


def create_test_videos():
    """Create mock test videos."""
    print("🎬 Creating test videos...")
    
    try:
        import cv2
        import numpy as np
        
        # Run the video creation script
        subprocess.check_call([sys.executable, "create_test_videos.py"])
        return True
    except ImportError:
        print("❌ OpenCV not available for video creation")
        return False
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to create test videos: {e}")
        return False


def create_mock_video_files():
    """Create placeholder video files when OpenCV is not available."""
    print("📁 Creating mock video file placeholders...")
    
    os.makedirs('testvideos', exist_ok=True)
    
    # Create empty placeholder files
    mock_files = ['example1.mp4', 'example2.mp4', 'example3.mp4']
    
    for filename in mock_files:
        filepath = os.path.join('testvideos', filename)
        with open(filepath, 'wb') as f:
            # Write minimal MP4 header (won't be playable but will exist)
            f.write(b'\x00\x00\x00\x20ftypmp41\x00\x00\x00\x00mp41isom')
        print(f"   Created placeholder: {filepath}")
    
    print("⚠️  Note: These are placeholder files. Install OpenCV and run create_test_videos.py for real videos.")


def main():
    """Main setup routine."""
    print("🚀 Setting up Volleyball Tracking Logic Sandbox\n")
    
    # Install dependencies
    if not install_requirements():
        print("❌ Setup failed: Could not install dependencies")
        return False
    
    print()
    
    # Try to create real test videos
    if not create_test_videos():
        # Fall back to mock files
        create_mock_video_files()
    
    print("\n✅ Setup complete!")
    print("\nNext steps:")
    print("1. If using placeholder videos, install OpenCV and run: python create_test_videos.py")
    print("2. Test the sandbox: python main.py --video testvideos/example1.mp4")
    print("3. Enable debug mode: python main.py --video testvideos/example1.mp4 --debug")
    
    return True


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)