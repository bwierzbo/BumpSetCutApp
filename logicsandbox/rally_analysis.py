"""
Rally Analysis Module

Mock implementation of volleyball rally analysis logic.
This simulates the rally metadata analysis functionality
from the BumpSetCut iOS app.
"""

import numpy as np
import math
from typing import List, Tuple, Dict, Any


def analyze_rallies(rally_segments: List[Tuple[float, float]], 
                   ball_detections: List[Tuple[float, float, float, float]], 
                   video_info: Dict[str, Any],
                   debug: bool = False) -> Dict[str, Any]:
    """
    Analyze rally segments and provide detailed metadata.
    
    Args:
        rally_segments: List of (start_time, end_time) tuples
        ball_detections: List of (timestamp, x, y, confidence) tuples
        video_info: Dictionary containing video metadata
        debug: Enable debug output
        
    Returns:
        Dictionary containing analysis results
    """
    if not rally_segments:
        print("   No rally segments to analyze")
        return {'total_rallies': 0, 'total_rally_time': 0, 'rally_details': []}
    
    rally_details = []
    total_rally_time = 0
    
    for i, (start_time, end_time) in enumerate(rally_segments, 1):
        duration = end_time - start_time
        total_rally_time += duration
        
        # Get detections for this rally
        rally_detections = [
            det for det in ball_detections 
            if start_time <= det[0] <= end_time
        ]
        
        # Analyze this rally
        analysis = analyze_single_rally(rally_detections, start_time, end_time, video_info)
        rally_details.append(analysis)
        
        # Print rally summary
        print(f"   Rally {i:2d}: {start_time:6.1f}s - {end_time:6.1f}s "
              f"(duration: {duration:5.1f}s, "
              f"contacts: ~{analysis['estimated_contacts']:2d}, "
              f"quality: {analysis['quality_score']:.2f})")
        
        if debug:
            print(f"     Details: {analysis['analysis_details']}")
    
    # Overall statistics
    avg_rally_duration = total_rally_time / len(rally_segments)
    total_video_time = video_info['duration']
    rally_coverage = (total_rally_time / total_video_time) * 100
    
    summary = {
        'total_rallies': len(rally_segments),
        'total_rally_time': total_rally_time,
        'avg_rally_duration': avg_rally_duration,
        'rally_coverage_percent': rally_coverage,
        'rally_details': rally_details
    }
    
    print("\n📈 Rally Analysis Summary:")
    print(f"   Total rallies found: {summary['total_rallies']}")
    print(f"   Total rally time: {summary['total_rally_time']:.1f}s / {total_video_time:.1f}s ({rally_coverage:.1f}%)")
    print(f"   Average rally duration: {avg_rally_duration:.1f}s")
    print(f"   Estimated total ball contacts: {sum(r['estimated_contacts'] for r in rally_details)}")
    
    return summary


def analyze_single_rally(detections: List[Tuple[float, float, float, float]], 
                        start_time: float, end_time: float,
                        video_info: Dict[str, Any]) -> Dict[str, Any]:
    """
    Analyze a single rally segment in detail.
    """
    duration = end_time - start_time
    
    if not detections:
        return {
            'duration': duration,
            'detection_count': 0,
            'estimated_contacts': 0,
            'quality_score': 0.0,
            'analysis_details': 'No ball detections found'
        }
    
    # Basic metrics
    detection_count = len(detections)
    detection_density = detection_count / duration
    avg_confidence = sum(det[3] for det in detections) / detection_count
    
    # Estimate ball contacts
    estimated_contacts = estimate_ball_contacts(detections)
    
    # Calculate trajectory analysis
    trajectory_analysis = analyze_trajectory(detections)
    
    # Calculate quality score
    quality_score = calculate_quality_score(
        detection_density, avg_confidence, trajectory_analysis, duration
    )
    
    # Generate analysis details
    analysis_details = generate_analysis_details(
        detections, trajectory_analysis, estimated_contacts
    )
    
    return {
        'start_time': start_time,
        'end_time': end_time,
        'duration': duration,
        'detection_count': detection_count,
        'detection_density': detection_density,
        'avg_confidence': avg_confidence,
        'estimated_contacts': estimated_contacts,
        'quality_score': quality_score,
        'trajectory_analysis': trajectory_analysis,
        'analysis_details': analysis_details
    }


def estimate_ball_contacts(detections: List[Tuple[float, float, float, float]]) -> int:
    """
    Estimate number of ball contacts based on trajectory changes.
    """
    if len(detections) < 3:
        return 1 if detections else 0
    
    # Look for direction changes that indicate contacts
    direction_changes = 0
    velocity_threshold = 50.0  # pixels per second
    
    for i in range(2, len(detections)):
        # Calculate velocity vectors
        t1, x1, y1, _ = detections[i-2]
        t2, x2, y2, _ = detections[i-1]
        t3, x3, y3, _ = detections[i]
        
        dt1 = t2 - t1
        dt2 = t3 - t2
        
        if dt1 > 0 and dt2 > 0:
            # Velocity before and after
            v1_x, v1_y = (x2 - x1) / dt1, (y2 - y1) / dt1
            v2_x, v2_y = (x3 - x2) / dt2, (y3 - y2) / dt2
            
            # Check for significant velocity change
            velocity_change = math.sqrt((v2_x - v1_x)**2 + (v2_y - v1_y)**2)
            
            if velocity_change > velocity_threshold:
                direction_changes += 1
    
    # Estimate contacts (each contact causes direction change)
    # Add baseline of 1-2 contacts for serves/attacks
    estimated_contacts = max(1, direction_changes // 2 + 1)
    
    # Cap at reasonable maximum (very long rallies)
    return min(estimated_contacts, 15)


def analyze_trajectory(detections: List[Tuple[float, float, float, float]]) -> Dict[str, Any]:
    """
    Analyze ball trajectory patterns.
    """
    if len(detections) < 2:
        return {'trajectory_type': 'insufficient_data', 'movement_patterns': []}
    
    # Calculate movement statistics
    total_distance = 0.0
    max_height = 0.0
    min_height = float('inf')
    vertical_changes = 0
    horizontal_changes = 0
    
    positions = [(det[1], det[2]) for det in detections]
    
    for i, (x, y) in enumerate(positions):
        max_height = max(max_height, y)
        min_height = min(min_height, y)
        
        if i > 0:
            prev_x, prev_y = positions[i-1]
            distance = math.sqrt((x - prev_x)**2 + (y - prev_y)**2)
            total_distance += distance
            
            # Count significant direction changes
            if abs(y - prev_y) > 20:  # Vertical movement threshold
                vertical_changes += 1
            if abs(x - prev_x) > 30:  # Horizontal movement threshold
                horizontal_changes += 1
    
    # Classify trajectory type
    height_range = max_height - min_height
    
    if height_range > 200:  # High trajectory
        if horizontal_changes > vertical_changes:
            trajectory_type = 'serve_or_attack'
        else:
            trajectory_type = 'high_set'
    elif total_distance > 400:  # Long distance
        trajectory_type = 'cross_court'
    elif vertical_changes > 3:  # Multiple bounces
        trajectory_type = 'rally_exchange'
    else:
        trajectory_type = 'short_play'
    
    return {
        'trajectory_type': trajectory_type,
        'total_distance': total_distance,
        'height_range': height_range,
        'vertical_changes': vertical_changes,
        'horizontal_changes': horizontal_changes,
        'avg_position': (
            sum(pos[0] for pos in positions) / len(positions),
            sum(pos[1] for pos in positions) / len(positions)
        )
    }


def calculate_quality_score(detection_density: float, avg_confidence: float, 
                          trajectory_analysis: Dict[str, Any], duration: float) -> float:
    """
    Calculate overall quality score for rally segment.
    """
    # Density score (higher density = better tracking)
    density_score = min(detection_density / 5.0, 1.0)  # Normalize to 5 detections/sec
    
    # Confidence score
    confidence_score = avg_confidence
    
    # Trajectory complexity score (more complex = more interesting)
    trajectory_complexity = (
        trajectory_analysis.get('vertical_changes', 0) + 
        trajectory_analysis.get('horizontal_changes', 0)
    ) / 10.0
    trajectory_score = min(trajectory_complexity, 1.0)
    
    # Duration score (prefer rallies that are not too short or too long)
    if duration < 3.0:
        duration_score = duration / 3.0
    elif duration > 20.0:
        duration_score = 20.0 / duration
    else:
        duration_score = 1.0
    
    # Weighted combination
    quality_score = (
        density_score * 0.3 +
        confidence_score * 0.3 +
        trajectory_score * 0.2 +
        duration_score * 0.2
    )
    
    return quality_score


def generate_analysis_details(detections: List[Tuple[float, float, float, float]], 
                            trajectory_analysis: Dict[str, Any], 
                            estimated_contacts: int) -> str:
    """
    Generate human-readable analysis details.
    """
    if not detections:
        return "No ball tracking data available"
    
    trajectory_type = trajectory_analysis.get('trajectory_type', 'unknown')
    total_distance = trajectory_analysis.get('total_distance', 0)
    height_range = trajectory_analysis.get('height_range', 0)
    
    # Generate description based on analysis
    details = []
    
    if trajectory_type == 'serve_or_attack':
        details.append("High-speed serve or attack trajectory")
    elif trajectory_type == 'high_set':
        details.append("High arc trajectory (likely set)")
    elif trajectory_type == 'cross_court':
        details.append("Long cross-court movement")
    elif trajectory_type == 'rally_exchange':
        details.append("Active rally with multiple exchanges")
    else:
        details.append("Short play or defensive action")
    
    details.append(f"Movement distance: {total_distance:.0f}px")
    details.append(f"Height variation: {height_range:.0f}px")
    details.append(f"Estimated {estimated_contacts} ball contact(s)")
    
    return " | ".join(details)