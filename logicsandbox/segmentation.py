"""
Video Segmentation Module

Mock implementation of volleyball rally segmentation logic.
This simulates the rally detection and video segmentation functionality
from the BumpSetCut iOS app.
"""

import numpy as np
from typing import List, Tuple, Dict, Any


def segment_video(ball_detections: List[Tuple[float, float, float, float]], 
                  video_info: Dict[str, Any]) -> List[Tuple[float, float]]:
    """
    Segment video into rally periods based on ball tracking data.
    
    Args:
        ball_detections: List of (timestamp, x, y, confidence) tuples
        video_info: Dictionary containing video metadata
        
    Returns:
        List of (start_time, end_time) tuples representing rally segments
    """
    if not ball_detections:
        return []
    
    # Configuration parameters (matching iOS app logic)
    config = {
        'min_rally_duration': 2.0,      # Minimum rally length in seconds
        'max_gap_duration': 1.5,        # Maximum gap within a rally
        'start_buffer': 0.5,            # Buffer before rally start
        'end_buffer': 0.3,              # Buffer after rally end
        'min_detections_per_second': 3, # Minimum detection density
        'confidence_threshold': 0.4      # Minimum confidence for valid detection
    }
    
    print(f"📊 Segmentation config: {config}")
    
    # Filter detections by confidence
    valid_detections = [
        det for det in ball_detections 
        if det[3] >= config['confidence_threshold']
    ]
    
    print(f"   Filtered detections: {len(valid_detections)}/{len(ball_detections)} above confidence threshold")
    
    if not valid_detections:
        return []
    
    # Group detections into continuous segments
    segments = []
    current_segment_start = valid_detections[0][0]
    last_detection_time = valid_detections[0][0]
    
    for timestamp, x, y, confidence in valid_detections[1:]:
        gap_duration = timestamp - last_detection_time
        
        if gap_duration > config['max_gap_duration']:
            # End current segment
            segment_end = last_detection_time
            segment_duration = segment_end - current_segment_start
            
            if segment_duration >= config['min_rally_duration']:
                segments.append((current_segment_start, segment_end))
            
            # Start new segment
            current_segment_start = timestamp
        
        last_detection_time = timestamp
    
    # Add final segment
    segment_end = last_detection_time
    segment_duration = segment_end - current_segment_start
    if segment_duration >= config['min_rally_duration']:
        segments.append((current_segment_start, segment_end))
    
    print(f"   Initial segments found: {len(segments)}")
    
    # Apply quality filters
    quality_segments = []
    
    for start_time, end_time in segments:
        segment_detections = [
            det for det in valid_detections 
            if start_time <= det[0] <= end_time
        ]
        
        duration = end_time - start_time
        detection_density = len(segment_detections) / duration
        
        # Check if segment meets quality requirements
        if detection_density >= config['min_detections_per_second']:
            # Apply buffers
            buffered_start = max(0, start_time - config['start_buffer'])
            buffered_end = min(video_info['duration'], end_time + config['end_buffer'])
            
            quality_segments.append((buffered_start, buffered_end))
            
            print(f"   ✅ Rally segment: {buffered_start:.1f}s - {buffered_end:.1f}s "
                  f"(duration: {buffered_end - buffered_start:.1f}s, "
                  f"density: {detection_density:.1f} det/s)")
        else:
            print(f"   ❌ Rejected segment: {start_time:.1f}s - {end_time:.1f}s "
                  f"(low density: {detection_density:.1f} det/s)")
    
    # Merge overlapping segments
    merged_segments = merge_overlapping_segments(quality_segments)
    
    print(f"   Final segments after merging: {len(merged_segments)}")
    
    return merged_segments


def merge_overlapping_segments(segments: List[Tuple[float, float]]) -> List[Tuple[float, float]]:
    """
    Merge overlapping or adjacent rally segments.
    """
    if not segments:
        return []
    
    # Sort segments by start time
    sorted_segments = sorted(segments, key=lambda x: x[0])
    merged = [sorted_segments[0]]
    
    for start, end in sorted_segments[1:]:
        last_start, last_end = merged[-1]
        
        # Check for overlap or adjacency (within 0.5 seconds)
        if start <= last_end + 0.5:
            # Merge segments
            merged[-1] = (last_start, max(last_end, end))
        else:
            # Add as new segment
            merged.append((start, end))
    
    return merged


def calculate_rally_activity(ball_detections: List[Tuple[float, float, float, float]], 
                           start_time: float, end_time: float) -> Dict[str, float]:
    """
    Calculate activity metrics for a rally segment.
    """
    segment_detections = [
        det for det in ball_detections 
        if start_time <= det[0] <= end_time
    ]
    
    if not segment_detections:
        return {'activity_score': 0.0, 'avg_confidence': 0.0, 'detection_rate': 0.0}
    
    duration = end_time - start_time
    avg_confidence = sum(det[3] for det in segment_detections) / len(segment_detections)
    detection_rate = len(segment_detections) / duration
    
    # Calculate movement activity (based on position changes)
    movement_activity = 0.0
    if len(segment_detections) > 1:
        total_movement = 0.0
        for i in range(1, len(segment_detections)):
            prev_x, prev_y = segment_detections[i-1][1], segment_detections[i-1][2]
            curr_x, curr_y = segment_detections[i][1], segment_detections[i][2]
            
            distance = np.sqrt((curr_x - prev_x)**2 + (curr_y - prev_y)**2)
            total_movement += distance
        
        movement_activity = total_movement / (len(segment_detections) - 1)
    
    # Combine metrics into activity score
    activity_score = (avg_confidence * 0.4 + 
                     min(detection_rate / 10, 1.0) * 0.4 + 
                     min(movement_activity / 100, 1.0) * 0.2)
    
    return {
        'activity_score': activity_score,
        'avg_confidence': avg_confidence,
        'detection_rate': detection_rate,
        'movement_activity': movement_activity
    }


def apply_temporal_smoothing(segments: List[Tuple[float, float]], 
                           min_gap: float = 0.3) -> List[Tuple[float, float]]:
    """
    Apply temporal smoothing to rally segments to remove very short gaps.
    """
    if len(segments) < 2:
        return segments
    
    smoothed_segments = [segments[0]]
    
    for start, end in segments[1:]:
        last_start, last_end = smoothed_segments[-1]
        
        gap = start - last_end
        if gap <= min_gap:
            # Merge with previous segment
            smoothed_segments[-1] = (last_start, end)
        else:
            smoothed_segments.append((start, end))
    
    return smoothed_segments