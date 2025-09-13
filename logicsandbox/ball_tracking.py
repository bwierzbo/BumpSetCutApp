"""
Ball Tracking Module

Real ML-based volleyball ball tracking logic using bestv2.mlpackage.
This implements the core ball detection functionality from the BumpSetCut iOS app.
"""

import cv2
import numpy as np
from typing import Optional, Tuple

# ML model integration
from ml_integration import MLModelTracker

# Global ML tracker instance
_ml_tracker = None


def track_ball(frame: np.ndarray) -> Optional[Tuple[float, float, float]]:
    """
    Track volleyball in the given frame using ML model.
    
    Args:
        frame: Input video frame as numpy array
        
    Returns:
        Tuple of (x, y, confidence) if ball detected, None otherwise
        - x, y: Ball center coordinates in pixels
        - confidence: Detection confidence (0-1)
    """
    if frame is None or frame.size == 0:
        return None
    
    global _ml_tracker
    if _ml_tracker is None:
        _ml_tracker = MLModelTracker()
    
    return _ml_tracker.track_ball_ml(frame)


def apply_physics_validation(detections: list) -> list:
    """
    Apply physics-based validation to filter out impossible ball movements.
    
    This is a simplified version of the physics validation from the iOS app.
    """
    if len(detections) < 3:
        return detections
    
    validated_detections = []
    
    for i, (timestamp, x, y, confidence) in enumerate(detections):
        if i == 0:
            validated_detections.append((timestamp, x, y, confidence))
            continue
        
        # Check velocity constraints
        prev_time, prev_x, prev_y, _ = validated_detections[-1]
        dt = timestamp - prev_time
        
        if dt > 0:
            velocity_x = abs(x - prev_x) / dt
            velocity_y = abs(y - prev_y) / dt
            
            # Maximum reasonable velocity (pixels per second)
            max_velocity = 1000.0  # Adjust based on video resolution and expected ball speed
            
            if velocity_x < max_velocity and velocity_y < max_velocity:
                validated_detections.append((timestamp, x, y, confidence))
            # Skip detection if velocity is too high (likely false positive)
    
    return validated_detections


def smooth_trajectory(detections: list, window_size: int = 5) -> list:
    """
    Apply temporal smoothing to ball trajectory.
    """
    if len(detections) < window_size:
        return detections
    
    smoothed_detections = []
    
    for i, (timestamp, x, y, confidence) in enumerate(detections):
        if i < window_size // 2 or i >= len(detections) - window_size // 2:
            # Keep original detections at edges
            smoothed_detections.append((timestamp, x, y, confidence))
        else:
            # Apply moving average
            window_start = i - window_size // 2
            window_end = i + window_size // 2 + 1
            window_detections = detections[window_start:window_end]
            
            avg_x = sum(det[1] for det in window_detections) / len(window_detections)
            avg_y = sum(det[2] for det in window_detections) / len(window_detections)
            
            smoothed_detections.append((timestamp, avg_x, avg_y, confidence))
    
    return smoothed_detections