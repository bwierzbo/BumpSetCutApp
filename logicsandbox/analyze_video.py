#!/usr/bin/env python3
"""
Real ML Video Analysis

Analyze volleyball videos using the actual bestv2.mlpackage model
and generate comprehensive visualizations of the results.
"""

import argparse
import os
import sys
import cv2
import time
import json
from typing import List, Dict, Any

from ml_detector import BestV2Detector
from segmentation import segment_video
from rally_analysis import analyze_rallies
from visualization import VideoVisualizer, create_visualization_report


def analyze_video_with_ml(video_path: str, output_dir: str, 
                         create_annotated: bool = True, debug: bool = False) -> Dict[str, Any]:
    """
    Analyze video using real ML model and create visualizations.
    
    Args:
        video_path: Path to input video
        output_dir: Directory for output files
        create_annotated: Whether to create annotated video
        debug: Enable debug output
    
    Returns:
        Analysis results dictionary
    """
    print(f"🎬 Analyzing video with real bestv2.mlpackage model: {video_path}")
    
    # Create output directory
    os.makedirs(output_dir, exist_ok=True)
    
    # Initialize ML detector
    detector = BestV2Detector()
    model_info = detector.get_model_info()
    
    if debug:
        print("🤖 Model Information:")
        for key, value in model_info.items():
            print(f"   {key}: {value}")
    
    # Load video
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Cannot open video: {video_path}")
    
    # Get video info
    fps = cap.get(cv2.CAP_PROP_FPS)
    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration = frame_count / fps if fps > 0 else 0
    
    video_info = {
        'path': video_path,
        'fps': fps,
        'frame_count': frame_count,
        'width': width,
        'height': height,
        'duration': duration
    }
    
    print(f"   Resolution: {width}x{height}")
    print(f"   Duration: {duration:.2f}s ({frame_count} frames at {fps:.1f} fps)")
    
    # Process video frame by frame
    print("🔍 Running ML inference on all frames...")
    detections = []
    frame_num = 0
    start_time = time.time()
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        
        timestamp = frame_num / fps
        
        # Run ML detection
        frame_detections = detector.detect_volleyball(frame)
        
        # Add timestamp to detections
        for detection in frame_detections:
            detection['timestamp'] = timestamp
            detection['frame'] = frame_num
            detections.append(detection)
        
        if debug and frame_detections:
            print(f"   Frame {frame_num:4d} ({timestamp:6.2f}s): {len(frame_detections)} detections")
        
        frame_num += 1
        
        # Progress indicator
        if frame_num % 100 == 0:
            progress = (frame_num / frame_count) * 100
            print(f"   Progress: {progress:.1f}% ({frame_num}/{frame_count})")
    
    cap.release()
    processing_time = time.time() - start_time
    
    print(f"✅ ML inference complete!")
    print(f"   Found {len(detections)} total detections")
    print(f"   Processing time: {processing_time:.2f}s ({frame_count / processing_time:.1f} fps)")
    
    # Convert detections to segmentation format
    ball_detection_data = []
    for det in detections:
        x, y = det['center']
        conf = det['confidence']
        timestamp = det['timestamp']
        ball_detection_data.append((timestamp, x, y, conf))
    
    # Segment video into rallies
    print("🏐 Segmenting video into rally periods...")
    rally_segments = segment_video(ball_detection_data, video_info)
    print(f"   Found {len(rally_segments)} rally segments")
    
    # Analyze rallies
    print("📊 Analyzing rally characteristics...")
    rally_analysis = analyze_rallies(rally_segments, ball_detection_data, video_info, debug=debug)
    
    # Create visualizations
    print("🎨 Creating visualizations...")
    visualizer = VideoVisualizer()
    
    # Save detection data
    detection_file = os.path.join(output_dir, "detections.json")
    with open(detection_file, 'w') as f:
        # Convert numpy types to native Python types for JSON serialization
        json_detections = []
        for det in detections:
            json_det = {
                'timestamp': float(det['timestamp']),
                'frame': int(det['frame']),
                'bbox': [int(x) for x in det['bbox']],
                'center': [float(x) for x in det['center']],
                'confidence': float(det['confidence']),
                'class': det['class']
            }
            json_detections.append(json_det)
        
        json.dump({
            'video_info': video_info,
            'model_info': model_info,
            'detections': json_detections,
            'processing_stats': {
                'total_detections': len(detections),
                'processing_time': processing_time,
                'fps_processed': frame_count / processing_time
            }
        }, f, indent=2)
    
    print(f"💾 Detection data saved: {detection_file}")
    
    # Create annotated video
    if create_annotated:
        print("🎬 Creating annotated video...")
        annotated_path = os.path.join(output_dir, "annotated_video.mp4")
        visualizer.create_annotated_video(video_path, detections, rally_segments, 
                                        annotated_path, debug=debug)
    
    # Create visualization report
    report = create_visualization_report(detections, rally_segments, video_info, output_dir)
    
    # Combine all results
    results = {
        'video_info': video_info,
        'model_info': model_info,
        'detections': detections,
        'rally_segments': rally_segments,
        'rally_analysis': rally_analysis,
        'processing_stats': {
            'total_detections': len(detections),
            'processing_time': processing_time,
            'fps_processed': frame_count / processing_time
        },
        'output_files': {
            'detections': detection_file,
            'annotated_video': annotated_path if create_annotated else None,
            'visualization_report': output_dir
        }
    }
    
    return results


def main():
    """Main analysis interface."""
    parser = argparse.ArgumentParser(
        description="Analyze volleyball videos using real bestv2.mlpackage ML model",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python analyze_video.py --video input.mp4 --output results/
    python analyze_video.py --video input.mp4 --output results/ --debug
    python analyze_video.py --video input.mp4 --output results/ --no-annotated
        """
    )
    
    parser.add_argument(
        '--video', '-v',
        required=True,
        help='Path to input video file'
    )
    
    parser.add_argument(
        '--output', '-o',
        required=True,
        help='Output directory for results'
    )
    
    parser.add_argument(
        '--debug', '-d',
        action='store_true',
        help='Enable debug output'
    )
    
    parser.add_argument(
        '--no-annotated',
        action='store_true',
        help='Skip creating annotated video (faster processing)'
    )
    
    args = parser.parse_args()
    
    try:
        # Validate input
        if not os.path.exists(args.video):
            print(f"❌ Video file not found: {args.video}")
            sys.exit(1)
        
        # Run analysis
        results = analyze_video_with_ml(
            video_path=args.video,
            output_dir=args.output,
            create_annotated=not args.no_annotated,
            debug=args.debug
        )
        
        # Print summary
        print(f"\n🎯 Analysis Complete!")
        print(f"   Input video: {args.video}")
        print(f"   Output directory: {args.output}")
        print(f"   Total detections: {results['processing_stats']['total_detections']}")
        print(f"   Rally segments: {len(results['rally_segments'])}")
        print(f"   Processing speed: {results['processing_stats']['fps_processed']:.1f} fps")
        
        # List output files
        print(f"\n📁 Generated files:")
        for name, path in results['output_files'].items():
            if path:
                print(f"   {name}: {path}")
        
    except KeyboardInterrupt:
        print("\n⚠️  Analysis interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Analysis failed: {e}")
        if args.debug:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()