#!/usr/bin/env python3
"""
Volleyball Ball Tracking Logic Sandbox

A standalone Python testbed for testing volleyball ball tracking, segmentation,
and rally tracking logic from the BumpSetCut iOS app.

Usage:
    python main.py --video testvideos/example1.mp4
    python main.py --video testvideos/example1.mp4 --debug
"""

import argparse
import os
import sys
import cv2
import time
from typing import List, Tuple, Optional

from ball_tracking import track_ball
from segmentation import segment_video
from rally_analysis import analyze_rallies
from ml_integration import print_ml_status, validate_ml_installation
from debug_annotator import create_debug_video_simple


def load_video(video_path: str) -> cv2.VideoCapture:
    """Load video file and return VideoCapture object."""
    if not os.path.exists(video_path):
        raise FileNotFoundError(f"Video file not found: {video_path}")
    
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Could not open video file: {video_path}")
    
    return cap


def get_video_info(cap: cv2.VideoCapture) -> dict:
    """Extract basic video information."""
    fps = cap.get(cv2.CAP_PROP_FPS)
    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration = frame_count / fps if fps > 0 else 0
    
    return {
        'fps': fps,
        'frame_count': frame_count,
        'width': width,
        'height': height,
        'duration': duration
    }


def process_video_frames(cap: cv2.VideoCapture, debug: bool = False) -> List[Tuple[float, float, float, float]]:
    """
    Process video frame by frame and track ball positions using ML model.
    
    Args:
        cap: Video capture object
        debug: Enable debug output
    
    Returns:
        List of (timestamp, x, y, confidence) tuples
    """
    ball_detections = []
    frame_count = 0
    fps = cap.get(cv2.CAP_PROP_FPS)
    
    print("🎾 Starting frame-by-frame ball tracking...")
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        
        timestamp = frame_count / fps if fps > 0 else frame_count * 0.033  # 30fps fallback
        
        # Track ball in current frame using ML model
        detection = track_ball(frame)
        
        if detection:
            x, y, confidence = detection
            ball_detections.append((timestamp, x, y, confidence))
            
            if debug and confidence > 0.5:  # Only show high-confidence detections in debug
                print(f"  Frame {frame_count:4d} ({timestamp:6.2f}s): Ball at ({x:6.1f}, {y:6.1f}) confidence={confidence:.3f}")
        
        frame_count += 1
        
        # Progress indicator every 100 frames
        if frame_count % 100 == 0:
            print(f"  Processed {frame_count} frames...")
    
    print(f"✅ Ball tracking complete. Found {len(ball_detections)} detections in {frame_count} frames.")
    return ball_detections


def main():
    parser = argparse.ArgumentParser(
        description="Test volleyball ball tracking and rally segmentation logic",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python main.py --video testvideos/example1.mp4
    python main.py --video testvideos/example1.mp4 --debug
    python main.py --video testvideos/example1.mp4 --output results.json
    python main.py --video testvideos/example1.mp4 --create-debug-video
        """
    )
    
    parser.add_argument(
        '--video', '-v',
        help='Path to input video file'
    )
    
    parser.add_argument(
        '--debug', '-d',
        action='store_true',
        help='Enable debug output'
    )
    
    parser.add_argument(
        '--output', '-o',
        help='Output file for results (optional)'
    )
    
    
    parser.add_argument(
        '--ml-status',
        action='store_true',
        help='Show ML model integration status and exit'
    )
    
    parser.add_argument(
        '--create-debug-video', '-cdv',
        action='store_true',
        help='Create debug video with detection annotations (like BumpSetCut debug mode)'
    )
    
    args = parser.parse_args()
    
    # Handle ML status check
    if args.ml_status:
        print_ml_status()
        return True
    
    # Video argument is required for normal operation
    if not args.video:
        parser.error("--video is required unless using --ml-status")
    
    # Check ML integration at startup
    ml_ready = validate_ml_installation()
    
    if ml_ready['requirements_met']:
        print("🤖 Using bestv2.mlpackage ML model for ball detection")
    else:
        print("❌ ML model not available - cannot proceed")
        print("   Ensure bestv2.mlpackage is available and CoreML tools are installed")
        return False
    
    try:
        # Load video
        print(f"📹 Loading video: {args.video}")
        cap = load_video(args.video)
        
        # Get video information
        video_info = get_video_info(cap)
        print(f"   Resolution: {video_info['width']}x{video_info['height']}")
        print(f"   Duration: {video_info['duration']:.2f}s ({video_info['frame_count']} frames at {video_info['fps']:.2f} fps)")
        print()
        
        # Process video frame by frame
        start_time = time.time()
        ball_detections = process_video_frames(cap, debug=args.debug)
        processing_time = time.time() - start_time
        
        cap.release()
        
        print(f"⚡ Processing completed in {processing_time:.2f} seconds")
        print(f"   Speed: {video_info['frame_count'] / processing_time:.1f} fps")
        print()
        
        # Segment video into rallies
        print("🏐 Segmenting video into rally segments...")
        rally_segments = segment_video(ball_detections, video_info)
        print(f"✅ Found {len(rally_segments)} rally segments")
        print()
        
        # Analyze rallies
        print("📊 Analyzing rally segments...")
        analyze_rallies(rally_segments, ball_detections, video_info, debug=args.debug)
        
        # Save results if requested
        if args.output:
            import json
            results = {
                'video_info': video_info,
                'ball_detections': ball_detections,
                'rally_segments': rally_segments,
                'processing_time': processing_time
            }
            
            with open(args.output, 'w') as f:
                json.dump(results, f, indent=2)
            print(f"💾 Results saved to {args.output}")
        
        # Create debug video if requested (always works, even with ML failures)
        if args.create_debug_video:
            print("\n🐛 Creating debug video (BumpSetCut-style)...")
            debug_output_path = args.output.replace('.json', '_debug.mp4') if args.output else None
            debug_success = create_debug_video_simple(args.video, debug_output_path, ball_detections)
            
            if debug_success:
                print("✅ Debug video created successfully!")
            else:
                print("❌ Debug video creation failed")
        
        print("\n🎯 Analysis complete!")
        
    except KeyboardInterrupt:
        print("\n⚠️  Processing interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()