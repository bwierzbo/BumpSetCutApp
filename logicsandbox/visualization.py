"""
Post-Processing Visualization

Visualize ML model detection results and rally analysis on processed videos.
"""

import cv2
import numpy as np
import os
import json
from typing import List, Dict, Any, Tuple, Optional
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import matplotlib.animation as animation


class VideoVisualizer:
    """
    Visualize volleyball detection and rally analysis results on video.
    """
    
    def __init__(self):
        self.colors = {
            'detection': (0, 255, 0),      # Green for detections
            'trajectory': (255, 100, 0),   # Orange for trajectory
            'rally': (0, 0, 255),          # Red for rally segments
            'text': (255, 255, 255),       # White for text
            'background': (0, 0, 0)        # Black for backgrounds
        }
        
        self.fonts = {
            'main': cv2.FONT_HERSHEY_SIMPLEX,
            'mono': cv2.FONT_HERSHEY_DUPLEX
        }
    
    def create_annotated_video(self, input_video_path: str, detections: List[Dict], 
                              rally_segments: List[Tuple[float, float]], 
                              output_path: str, debug: bool = False):
        """
        Create annotated video with detection boxes, trajectories, and rally segments.
        """
        print(f"🎬 Creating annotated video: {output_path}")
        
        cap = cv2.VideoCapture(input_video_path)
        if not cap.isOpened():
            raise ValueError(f"Cannot open video: {input_video_path}")
        
        # Get video properties
        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        
        # Create video writer
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        out = cv2.VideoWriter(output_path, fourcc, fps, (width, height))
        
        # Prepare detection data by timestamp
        detection_timeline = self._prepare_detection_timeline(detections, fps)
        
        # Track trajectory points
        trajectory_points = []
        max_trajectory_points = int(fps * 2)  # 2 seconds of trajectory
        
        frame_count = 0
        while True:
            ret, frame = cap.read()
            if not ret:
                break
            
            timestamp = frame_count / fps
            
            # Draw rally segment indicators
            frame = self._draw_rally_indicators(frame, rally_segments, timestamp)
            
            # Get detections for current frame
            frame_detections = detection_timeline.get(frame_count, [])
            
            # Draw detections and update trajectory
            for detection in frame_detections:
                frame = self._draw_detection(frame, detection, debug)
                
                # Add to trajectory
                center = detection['center']
                trajectory_points.append((int(center[0]), int(center[1])))
                
                # Limit trajectory length
                if len(trajectory_points) > max_trajectory_points:
                    trajectory_points.pop(0)
            
            # Draw trajectory
            if len(trajectory_points) > 1:
                frame = self._draw_trajectory(frame, trajectory_points)
            
            # Draw frame info
            frame = self._draw_frame_info(frame, frame_count, timestamp, len(frame_detections))
            
            out.write(frame)
            frame_count += 1
            
            if frame_count % 100 == 0:
                progress = (frame_count / total_frames) * 100
                print(f"   Progress: {progress:.1f}% ({frame_count}/{total_frames})")
        
        cap.release()
        out.release()
        print(f"✅ Annotated video saved: {output_path}")
    
    def _prepare_detection_timeline(self, detections: List[Dict], fps: float) -> Dict[int, List[Dict]]:
        """Organize detections by frame number."""
        timeline = {}
        
        for detection in detections:
            timestamp = detection.get('timestamp', 0)
            frame_num = int(timestamp * fps)
            
            if frame_num not in timeline:
                timeline[frame_num] = []
            timeline[frame_num].append(detection)
        
        return timeline
    
    def _draw_detection(self, frame: np.ndarray, detection: Dict, debug: bool) -> np.ndarray:
        """Draw detection bounding box and info."""
        bbox = detection['bbox']
        confidence = detection['confidence']
        
        x1, y1, x2, y2 = bbox
        
        # Draw bounding box
        cv2.rectangle(frame, (x1, y1), (x2, y2), self.colors['detection'], 2)
        
        # Draw confidence
        confidence_text = f"{confidence:.2f}"
        text_size = cv2.getTextSize(confidence_text, self.fonts['main'], 0.6, 2)[0]
        
        # Background for text
        cv2.rectangle(frame, (x1, y1 - text_size[1] - 10), 
                     (x1 + text_size[0] + 10, y1), self.colors['detection'], -1)
        
        # Text
        cv2.putText(frame, confidence_text, (x1 + 5, y1 - 5), 
                   self.fonts['main'], 0.6, self.colors['text'], 2)
        
        if debug:
            # Draw center point
            center = detection['center']
            cv2.circle(frame, (int(center[0]), int(center[1])), 5, self.colors['detection'], -1)
        
        return frame
    
    def _draw_trajectory(self, frame: np.ndarray, points: List[Tuple[int, int]]) -> np.ndarray:
        """Draw volleyball trajectory."""
        if len(points) < 2:
            return frame
        
        # Draw trajectory line with fading effect
        for i in range(1, len(points)):
            alpha = i / len(points)  # Fade older points
            thickness = max(1, int(3 * alpha))
            
            cv2.line(frame, points[i-1], points[i], self.colors['trajectory'], thickness)
        
        return frame
    
    def _draw_rally_indicators(self, frame: np.ndarray, rally_segments: List[Tuple[float, float]], 
                              current_time: float) -> np.ndarray:
        """Draw rally segment indicators."""
        height, width = frame.shape[:2]
        
        # Check if current time is in a rally
        in_rally = False
        for start_time, end_time in rally_segments:
            if start_time <= current_time <= end_time:
                in_rally = True
                break
        
        # Draw rally indicator
        if in_rally:
            # Red border to indicate active rally
            cv2.rectangle(frame, (0, 0), (width-1, height-1), self.colors['rally'], 8)
            
            # Rally text
            cv2.putText(frame, "RALLY", (20, 50), self.fonts['main'], 1.5, self.colors['rally'], 3)
        
        return frame
    
    def _draw_frame_info(self, frame: np.ndarray, frame_num: int, timestamp: float, 
                        detection_count: int) -> np.ndarray:
        """Draw frame information overlay."""
        height, width = frame.shape[:2]
        
        # Create info panel
        panel_height = 80
        panel = np.zeros((panel_height, width, 3), dtype=np.uint8)
        panel[:] = (30, 30, 30)  # Dark gray
        
        # Frame info
        info_text = [
            f"Frame: {frame_num:6d}",
            f"Time:  {timestamp:6.2f}s",
            f"Detections: {detection_count}"
        ]
        
        y_offset = 20
        for i, text in enumerate(info_text):
            cv2.putText(panel, text, (10, y_offset + i * 20), 
                       self.fonts['mono'], 0.5, self.colors['text'], 1)
        
        # Overlay panel
        frame[-panel_height:, :] = panel
        
        return frame
    
    def create_detection_summary_plot(self, detections: List[Dict], output_path: str):
        """Create summary plot of detection results."""
        print(f"📊 Creating detection summary plot: {output_path}")
        
        if not detections:
            print("⚠️  No detections to plot")
            return
        
        # Extract data
        timestamps = [d.get('timestamp', 0) for d in detections]
        confidences = [d['confidence'] for d in detections]
        x_positions = [d['center'][0] for d in detections]
        y_positions = [d['center'][1] for d in detections]
        
        # Create subplots
        fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(15, 10))
        fig.suptitle('Volleyball Detection Analysis', fontsize=16, fontweight='bold')
        
        # Plot 1: Confidence over time
        ax1.plot(timestamps, confidences, 'g-', alpha=0.7, linewidth=1)
        ax1.scatter(timestamps, confidences, c='green', s=20, alpha=0.6)
        ax1.set_xlabel('Time (seconds)')
        ax1.set_ylabel('Detection Confidence')
        ax1.set_title('Detection Confidence Timeline')
        ax1.grid(True, alpha=0.3)
        
        # Plot 2: Ball position trajectory
        scatter = ax2.scatter(x_positions, y_positions, c=timestamps, s=30, 
                            cmap='viridis', alpha=0.7)
        ax2.set_xlabel('X Position (pixels)')
        ax2.set_ylabel('Y Position (pixels)')
        ax2.set_title('Ball Position Trajectory')
        ax2.invert_yaxis()  # Invert Y to match image coordinates
        plt.colorbar(scatter, ax=ax2, label='Time (seconds)')
        ax2.grid(True, alpha=0.3)
        
        # Plot 3: Detection frequency histogram
        detection_bins = np.histogram(timestamps, bins=20)
        bin_centers = (detection_bins[1][:-1] + detection_bins[1][1:]) / 2
        ax3.bar(bin_centers, detection_bins[0], width=np.diff(detection_bins[1])[0] * 0.8, 
               alpha=0.7, color='orange')
        ax3.set_xlabel('Time (seconds)')
        ax3.set_ylabel('Detections per Interval')
        ax3.set_title('Detection Frequency Distribution')
        ax3.grid(True, alpha=0.3)
        
        # Plot 4: Confidence distribution
        ax4.hist(confidences, bins=20, alpha=0.7, color='blue', edgecolor='black')
        ax4.set_xlabel('Confidence Score')
        ax4.set_ylabel('Frequency')
        ax4.set_title('Confidence Score Distribution')
        ax4.axvline(np.mean(confidences), color='red', linestyle='--', 
                   label=f'Mean: {np.mean(confidences):.3f}')
        ax4.legend()
        ax4.grid(True, alpha=0.3)
        
        plt.tight_layout()
        plt.savefig(output_path, dpi=300, bbox_inches='tight')
        plt.close()
        
        print(f"✅ Summary plot saved: {output_path}")
    
    def create_rally_analysis_plot(self, rally_segments: List[Tuple[float, float]], 
                                  detections: List[Dict], video_duration: float, 
                                  output_path: str):
        """Create rally analysis visualization."""
        print(f"📈 Creating rally analysis plot: {output_path}")
        
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(15, 8))
        fig.suptitle('Rally Segmentation Analysis', fontsize=16, fontweight='bold')
        
        # Plot 1: Rally timeline
        ax1.set_xlim(0, video_duration)
        ax1.set_ylim(-0.5, 1.5)
        
        # Draw rally segments
        for i, (start, end) in enumerate(rally_segments):
            ax1.barh(0, end - start, left=start, height=0.4, 
                    alpha=0.7, color='red', label='Rally' if i == 0 else '')
        
        # Draw detection timeline
        if detections:
            timestamps = [d.get('timestamp', 0) for d in detections]
            ax1.scatter(timestamps, [0.7] * len(timestamps), 
                       c='green', s=10, alpha=0.6, label='Detections')
        
        ax1.set_xlabel('Time (seconds)')
        ax1.set_ylabel('')
        ax1.set_title('Rally Segments and Detections Timeline')
        ax1.set_yticks([0, 0.7], ['Rally Segments', 'Detections'])
        ax1.legend()
        ax1.grid(True, alpha=0.3)
        
        # Plot 2: Rally statistics
        if rally_segments:
            durations = [end - start for start, end in rally_segments]
            ax2.bar(range(1, len(durations) + 1), durations, alpha=0.7, color='blue')
            ax2.set_xlabel('Rally Number')
            ax2.set_ylabel('Duration (seconds)')
            ax2.set_title('Rally Duration Distribution')
            ax2.grid(True, alpha=0.3)
            
            # Add statistics
            avg_duration = np.mean(durations)
            ax2.axhline(avg_duration, color='red', linestyle='--', 
                       label=f'Average: {avg_duration:.1f}s')
            ax2.legend()
        else:
            ax2.text(0.5, 0.5, 'No rallies detected', ha='center', va='center', 
                    transform=ax2.transAxes, fontsize=14)
        
        plt.tight_layout()
        plt.savefig(output_path, dpi=300, bbox_inches='tight')
        plt.close()
        
        print(f"✅ Rally analysis plot saved: {output_path}")


def create_visualization_report(detections: List[Dict], rally_segments: List[Tuple[float, float]], 
                               video_info: Dict, output_dir: str):
    """Create comprehensive visualization report."""
    os.makedirs(output_dir, exist_ok=True)
    
    visualizer = VideoVisualizer()
    
    # Create plots
    detection_plot = os.path.join(output_dir, "detection_summary.png")
    rally_plot = os.path.join(output_dir, "rally_analysis.png")
    
    visualizer.create_detection_summary_plot(detections, detection_plot)
    visualizer.create_rally_analysis_plot(rally_segments, detections, 
                                         video_info['duration'], rally_plot)
    
    # Create JSON report
    report = {
        'video_info': video_info,
        'detection_summary': {
            'total_detections': len(detections),
            'avg_confidence': np.mean([d['confidence'] for d in detections]) if detections else 0,
            'detection_rate': len(detections) / video_info['duration'] if video_info['duration'] > 0 else 0
        },
        'rally_summary': {
            'total_rallies': len(rally_segments),
            'total_rally_time': sum(end - start for start, end in rally_segments),
            'avg_rally_duration': np.mean([end - start for start, end in rally_segments]) if rally_segments else 0,
            'rally_coverage': (sum(end - start for start, end in rally_segments) / video_info['duration'] * 100) if video_info['duration'] > 0 else 0
        }
    }
    
    report_file = os.path.join(output_dir, "analysis_report.json")
    with open(report_file, 'w') as f:
        json.dump(report, f, indent=2)
    
    print(f"📋 Visualization report created in: {output_dir}")
    return report