#!/usr/bin/env python3
"""
Debug Annotator - Creates annotated debug videos with ball tracking overlays
Similar to BumpSetCut's DebugAnnotator.swift functionality

Enhanced with rally states, physics validation, and advanced tracking visualization.
"""

import cv2
import numpy as np
import os
from typing import List, Tuple, Optional, Dict, Any
from dataclasses import dataclass
from rally_decider import RallyState
from ballistics_gate import PhysicsValidation
from kalman_ball_tracker import TrackingState


@dataclass
class FrameDebugInfo:
    """Debug information for a single frame."""
    frame_idx: int
    timestamp: float
    detections: List[Tuple[float, float, float]]  # (x, y, confidence)
    tracking_states: List[TrackingState]
    rally_state: RallyState
    rally_confidence: float
    physics_validation: Optional[PhysicsValidation]
    rally_info: Optional[Dict]


class DebugAnnotator:
    """Creates debug videos with ball tracking annotations, similar to BumpSetCut's debug mode."""
    
    def __init__(self, input_path: str, output_path: str, frame_stride: int = 3):
        """
        Initialize debug annotator.
        
        Args:
            input_path: Input video file path
            output_path: Output debug video file path
            frame_stride: Process every Nth frame (3 = every 3rd frame, like BumpSetCut)
        """
        self.input_path = input_path
        self.output_path = output_path
        self.frame_stride = frame_stride
        
        # Enhanced annotation colors matching BumpSetCut
        self.detection_color = (0, 255, 0)      # Green for detections
        self.track_color = (255, 0, 0)          # Blue for trajectory trails
        self.prediction_color = (0, 255, 255)   # Yellow for predictions
        self.physics_valid_color = (0, 255, 0)  # Green for valid physics
        self.physics_invalid_color = (0, 0, 255) # Red for invalid physics
        self.rally_active_color = (0, 255, 255) # Yellow for active rally
        self.text_color = (255, 255, 255)       # White for text
        self.background_color = (0, 0, 0)       # Black for text backgrounds
        
        # Line thicknesses
        self.detection_thickness = 3
        self.track_thickness = 2
        self.prediction_thickness = 1
        
        # Track history for trajectory trails
        self.track_history: List[Tuple[int, int, float]] = []  # (x, y, confidence)
        self.prediction_history: List[Tuple[int, int]] = []
        self.max_track_history = 30  # Keep last 30 positions
        
        # Rally state colors
        self.rally_state_colors = {
            RallyState.IDLE: (128, 128, 128),        # Gray
            RallyState.POTENTIAL: (0, 165, 255),     # Orange
            RallyState.ACTIVE: (0, 255, 255),        # Yellow  
            RallyState.ENDING: (255, 0, 255)         # Magenta
        }
        
    def create_debug_video(self, detections: List[Tuple[float, float, float, float]] = None) -> bool:
        """Legacy method for backwards compatibility."""
        return self.create_enhanced_debug_video([])
        
    def create_enhanced_debug_video(self, debug_info_list: List[FrameDebugInfo]) -> bool:
        """
        Create annotated debug video with advanced overlays showing rally states, 
        physics validation, and tracking information.
        
        Args:
            debug_info_list: List of debug information per frame
            
        Returns:
            True if successful, False otherwise
        """
        try:
            print(f"🐛 Creating debug video...")
            print(f"   Input: {self.input_path}")
            print(f"   Output: {self.output_path}")
            print(f"   Frame stride: {self.frame_stride} (processing every {self.frame_stride} frames)")
            
            # Open input video
            cap = cv2.VideoCapture(self.input_path)
            if not cap.isOpened():
                print(f"❌ Could not open input video: {self.input_path}")
                return False
                
            # Get video properties
            fps = cap.get(cv2.CAP_PROP_FPS)
            width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            
            print(f"   Video: {width}x{height} @ {fps:.2f}fps, {total_frames} frames")
            
            # Create output directory if needed
            output_dir = os.path.dirname(self.output_path)
            if output_dir and not os.path.exists(output_dir):
                os.makedirs(output_dir)
            
            # Setup video writer
            fourcc = cv2.VideoWriter_fourcc(*'mp4v')
            writer = cv2.VideoWriter(self.output_path, fourcc, fps, (width, height))
            
            if not writer.isOpened():
                print(f"❌ Could not create output video writer")
                cap.release()
                return False
            
            # Create debug info lookup for fast frame access
            debug_by_frame = {}
            for debug_info in debug_info_list:
                debug_by_frame[debug_info.frame_idx] = debug_info
            
            frame_count = 0
            processed_count = 0
            
            print("   Processing frames...")
            
            while True:
                ret, frame = cap.read()
                if not ret:
                    break
                
                # Always write frame, but only annotate on stride boundaries
                annotated_frame = frame.copy()
                
                if frame_count % self.frame_stride == 0:
                    # This frame gets processed (like BumpSetCut's debug mode)
                    debug_info = debug_by_frame.get(frame_count)
                    annotated_frame = self._annotate_enhanced_frame(frame, frame_count, debug_info)
                    processed_count += 1
                
                writer.write(annotated_frame)
                frame_count += 1
                
                # Progress indicator
                if frame_count % 300 == 0:  # Every 10 seconds at 30fps
                    progress = (frame_count / total_frames) * 100
                    print(f"   Progress: {progress:.1f}% ({frame_count}/{total_frames} frames)")
            
            # Cleanup
            cap.release()
            writer.release()
            
            print(f"✅ Debug video created successfully!")
            print(f"   Processed {processed_count} frames (stride={self.frame_stride})")
            print(f"   Output saved to: {self.output_path}")
            
            return True
            
        except Exception as e:
            print(f"❌ Error creating debug video: {e}")
            return False
    
    def _annotate_enhanced_frame(self, frame: np.ndarray, frame_idx: int, debug_info: Optional[FrameDebugInfo]) -> np.ndarray:
        """
        Annotate a single frame with enhanced overlays including rally state, physics, and tracking.
        
        Args:
            frame: Input frame
            frame_idx: Frame index
            debug_info: Debug information for this frame
            
        Returns:
            Enhanced annotated frame
        """
        annotated = frame.copy()
        height, width = frame.shape[:2]
        
        # Add frame info and timestamp with fixed width formatting to prevent flickering
        timestamp = debug_info.timestamp if debug_info else frame_idx / 30.0
        frame_text = f"Frame: {frame_idx:4d} | Time: {timestamp:6.2f}s"
        self._draw_text_with_background(
            annotated, frame_text, 
            (10, 30), 0.7, self.text_color, self.background_color
        )
        
        if debug_info:
            # Draw rally state indicator
            self._draw_rally_state_overlay(annotated, debug_info, width, height)
            
            # Draw detections and tracking
            self._draw_detections(annotated, debug_info.detections, width, height)
            self._draw_tracking_states(annotated, debug_info.tracking_states, width, height)
            
            # Draw physics validation
            if debug_info.physics_validation:
                self._draw_physics_validation(annotated, debug_info.physics_validation, width, height)
            
            # Draw trajectory trails
            self._update_and_draw_trajectories(annotated, debug_info.detections, width, height)
            
            # Draw rally information
            if debug_info.rally_info and debug_info.rally_state == RallyState.ACTIVE:
                self._draw_rally_info(annotated, debug_info.rally_info, width, height)
        
        # Draw legends and status
        self._draw_legends(annotated, width, height)
        
        return annotated
    
    def _draw_text_with_background(self, img: np.ndarray, text: str, pos: Tuple[int, int], 
                                 scale: float, text_color: Tuple[int, int, int], 
                                 bg_color: Tuple[int, int, int], thickness: int = 2):
        """Draw text with a background rectangle for better visibility."""
        (text_width, text_height), baseline = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, thickness)
        
        # Add padding for stable background
        padding = 8
        
        # Draw background rectangle with fixed size to prevent flickering
        cv2.rectangle(img, 
                     (pos[0] - padding, pos[1] - text_height - padding),
                     (pos[0] + text_width + padding, pos[1] + baseline + padding),
                     bg_color, -1)
        
        # Draw text
        cv2.putText(img, text, pos, cv2.FONT_HERSHEY_SIMPLEX, scale, text_color, thickness)
    
    def _draw_rally_state_overlay(self, img: np.ndarray, debug_info: FrameDebugInfo, width: int, height: int):
        """Draw rally state information in the top-right corner."""
        state_color = self.rally_state_colors.get(debug_info.rally_state, self.text_color)
        
        # Rally state
        state_text = f"Rally: {debug_info.rally_state.value.upper()}"
        self._draw_text_with_background(
            img, state_text, (width - 250, 30), 0.7, state_color, self.background_color
        )
        
        # Rally confidence with fixed width
        conf_text = f"Confidence: {debug_info.rally_confidence:5.3f}"
        self._draw_text_with_background(
            img, conf_text, (width - 250, 60), 0.6, self.text_color, self.background_color
        )
    
    def _draw_detections(self, img: np.ndarray, detections: List[Tuple[float, float, float]], width: int, height: int):
        """Draw detection circles and confidence scores."""
        for x, y, confidence in detections:
            # ML model returns pixel coordinates directly
            px = int(x)
            py = int(y)
            
            # Detection circle with confidence-based size
            radius = int(15 + confidence * 10)  # 15-25 pixel radius
            cv2.circle(img, (px, py), radius, self.detection_color, self.detection_thickness)
            
            # Confidence text
            conf_text = f"{confidence:.3f}"
            self._draw_text_with_background(
                img, conf_text, (px + radius + 5, py - 5), 
                0.5, self.text_color, self.background_color
            )
    
    def _draw_tracking_states(self, img: np.ndarray, tracking_states: List[TrackingState], width: int, height: int):
        """Draw tracking state information including velocity vectors and predictions."""
        for track in tracking_states:
            px = int(track.state[0])
            py = int(track.state[1])
            vx = track.state[2]
            vy = track.state[3]
            
            # Track ID and confidence
            track_text = f"T{track.track_id} ({track.confidence:.2f})"
            self._draw_text_with_background(
                img, track_text, (px - 30, py - 30), 
                0.4, self.text_color, self.background_color
            )
            
            # Velocity vector
            if abs(vx) > 1 or abs(vy) > 1:
                end_x = int(px + vx * 3)  # Scale velocity for visibility
                end_y = int(py + vy * 3)
                cv2.arrowedLine(img, (px, py), (end_x, end_y), self.prediction_color, 2, tipLength=0.3)
            
            # Prediction circle (looser, dotted)
            pred_radius = int(20 + track.prediction_count * 2)
            self._draw_dashed_circle(img, (px, py), pred_radius, self.prediction_color, 1)
    
    def _draw_physics_validation(self, img: np.ndarray, physics: PhysicsValidation, width: int, height: int):
        """Draw physics validation results."""
        color = self.physics_valid_color if physics.is_valid else self.physics_invalid_color
        status = "VALID" if physics.is_valid else "INVALID"
        
        # Physics status in bottom-right
        physics_text = f"Physics: {status} ({physics.physics_score:.3f})"
        self._draw_text_with_background(
            img, physics_text, (width - 300, height - 60), 
            0.6, color, self.background_color
        )
        
        # Additional physics details
        if hasattr(physics, 'quadratic_fit') and physics.quadratic_fit:
            r2_text = f"R²: {physics.quadratic_fit.r_squared:.3f}"
            self._draw_text_with_background(
                img, r2_text, (width - 300, height - 30), 
                0.5, self.text_color, self.background_color
            )
    
    def _update_and_draw_trajectories(self, img: np.ndarray, detections: List[Tuple[float, float, float]], width: int, height: int):
        """Update trajectory history and draw trails."""
        # Add current detections to history
        for x, y, confidence in detections:
            # ML model returns pixel coordinates directly (not normalized)
            px = int(x)
            py = int(y)
            self.track_history.append((px, py, confidence))
        
        # Limit history size
        if len(self.track_history) > self.max_track_history:
            self.track_history = self.track_history[-self.max_track_history:]
        
        # Draw trajectory trail with fading
        if len(self.track_history) > 1:
            for i in range(1, len(self.track_history)):
                alpha = (i / len(self.track_history)) * 0.8 + 0.2  # Keep some minimum visibility
                color = tuple(int(c * alpha) for c in self.track_color)
                thickness = max(2, int(self.track_thickness * alpha))
                
                cv2.line(img, 
                        (self.track_history[i-1][0], self.track_history[i-1][1]),
                        (self.track_history[i][0], self.track_history[i][1]),
                        color, thickness)
    
    def _draw_rally_info(self, img: np.ndarray, rally_info: Dict, width: int, height: int):
        """Draw current rally information."""
        duration = rally_info.get('duration', 0)
        contacts = rally_info.get('estimated_contacts', 0)
        avg_conf = rally_info.get('avg_confidence', 0)
        
        rally_text = f"Rally: {duration:.1f}s | Contacts: {contacts} | Avg: {avg_conf:.3f}"
        self._draw_text_with_background(
            img, rally_text, (10, height - 60), 
            0.6, self.rally_active_color, self.background_color
        )
    
    def _draw_legends(self, img: np.ndarray, width: int, height: int):
        """Draw color legends and status information."""
        legend_y = height - 120
        
        # Detection legend
        cv2.circle(img, (20, legend_y), 8, self.detection_color, -1)
        cv2.putText(img, "Detections", (35, legend_y + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.4, self.text_color, 1)
        
        # Track legend
        cv2.line(img, (120, legend_y - 5), (140, legend_y + 5), self.track_color, 2)
        cv2.putText(img, "Tracks", (145, legend_y + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.4, self.text_color, 1)
        
        # Prediction legend  
        cv2.arrowedLine(img, (210, legend_y), (230, legend_y), self.prediction_color, 1, tipLength=0.5)
        cv2.putText(img, "Velocity", (235, legend_y + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.4, self.text_color, 1)
    
    def _draw_dashed_circle(self, img: np.ndarray, center: Tuple[int, int], radius: int, color: Tuple[int, int, int], thickness: int):
        """Draw a dashed circle."""
        import math
        
        # Draw circle as dashed lines
        for angle in range(0, 360, 10):  # Every 10 degrees
            if angle % 20 < 10:  # Dash pattern
                angle_rad = math.radians(angle)
                x1 = int(center[0] + radius * math.cos(angle_rad))
                y1 = int(center[1] + radius * math.sin(angle_rad))
                
                angle_rad2 = math.radians(angle + 8)
                x2 = int(center[0] + radius * math.cos(angle_rad2))
                y2 = int(center[1] + radius * math.sin(angle_rad2))
                
                cv2.line(img, (x1, y1), (x2, y2), color, thickness)


def create_debug_video_simple(input_path: str, output_path: str = None, 
                            detections: List[Tuple[float, float, float, float]] = None) -> bool:
    """
    Simple function to create debug video (like BumpSetCut's debug processing).
    
    Args:
        input_path: Input video file
        output_path: Output path (auto-generated if None)
        detections: Ball detections (empty list works fine)
        
    Returns:
        True if successful
    """
    if output_path is None:
        base_name = os.path.splitext(os.path.basename(input_path))[0]
        output_dir = os.path.dirname(input_path) or "."
        output_path = os.path.join(output_dir, f"Debug_{base_name}.mp4")
    
    annotator = DebugAnnotator(input_path, output_path)
    return annotator.create_debug_video(detections or [])


if __name__ == "__main__":
    # Test the debug annotator
    import argparse
    
    parser = argparse.ArgumentParser(description="Create debug annotated video")
    parser.add_argument("input", help="Input video file")
    parser.add_argument("-o", "--output", help="Output video file")
    
    args = parser.parse_args()
    
    success = create_debug_video_simple(args.input, args.output)
    exit(0 if success else 1)