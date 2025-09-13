#!/usr/bin/env python3
"""
Create mock test video files for the volleyball tracking sandbox.
"""

import cv2
import numpy as np
import os


def create_mock_video(filename: str, duration_seconds: int = 30, fps: int = 30, 
                     width: int = 1280, height: int = 720):
    """Create a mock video file with simple content."""
    
    output_path = os.path.join('testvideos', filename)
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    out = cv2.VideoWriter(output_path, fourcc, fps, (width, height))
    
    total_frames = duration_seconds * fps
    
    print(f"Creating {filename} ({duration_seconds}s, {total_frames} frames)")
    
    for frame_num in range(total_frames):
        # Create a frame with volleyball court-like appearance
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        
        # Court background (green)
        frame[:, :] = (34, 139, 34)  # Forest green
        
        # Court lines (white)
        center_x = width // 2
        center_y = height // 2
        
        # Center line
        cv2.line(frame, (center_x, 0), (center_x, height), (255, 255, 255), 5)
        
        # Attack lines (3m lines)
        attack_line_offset = width // 6
        cv2.line(frame, (center_x - attack_line_offset, 0), 
                (center_x - attack_line_offset, height), (255, 255, 255), 3)
        cv2.line(frame, (center_x + attack_line_offset, 0), 
                (center_x + attack_line_offset, height), (255, 255, 255), 3)
        
        # Court boundaries
        cv2.rectangle(frame, (50, 50), (width-50, height-50), (255, 255, 255), 3)
        
        # Add some frame-specific elements for variation
        time_progress = frame_num / total_frames
        
        # Moving "volleyball" (white circle)
        if filename == 'example1.mp4':
            # Simulate a serve trajectory
            ball_x = int(100 + (width - 200) * time_progress)
            ball_y = int(height * 0.3 + 200 * np.sin(time_progress * np.pi))
        elif filename == 'example2.mp4':
            # Simulate rally exchange
            ball_x = int(width * 0.5 + 300 * np.sin(time_progress * 4 * np.pi))
            ball_y = int(height * 0.4 + 100 * np.cos(time_progress * 6 * np.pi))
        else:
            # Random movement
            ball_x = int(width * 0.5 + 200 * np.sin(time_progress * 3 * np.pi))
            ball_y = int(height * 0.5 + 150 * np.cos(time_progress * 2 * np.pi))
        
        # Draw ball (make it visible for testing)
        cv2.circle(frame, (ball_x, ball_y), 15, (255, 255, 255), -1)
        cv2.circle(frame, (ball_x, ball_y), 15, (0, 0, 0), 2)
        
        # Add frame number for debugging
        cv2.putText(frame, f"Frame {frame_num}", (10, 30), 
                   cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
        
        out.write(frame)
    
    out.release()
    print(f"✅ Created {output_path}")


def main():
    """Create all test video files."""
    
    # Ensure testvideos directory exists
    os.makedirs('testvideos', exist_ok=True)
    
    # Create different types of test videos
    create_mock_video('example1.mp4', duration_seconds=15, fps=30)  # Short serve video
    create_mock_video('example2.mp4', duration_seconds=25, fps=30)  # Rally video
    create_mock_video('example3.mp4', duration_seconds=10, fps=24)  # Short clip, different fps
    
    print("\n🎬 All test videos created successfully!")
    print("Usage examples:")
    print("  python main.py --video testvideos/example1.mp4")
    print("  python main.py --video testvideos/example2.mp4 --debug")
    print("  python main.py --video testvideos/example3.mp4 --output results.json")


if __name__ == "__main__":
    main()