"""
Kalman Ball Tracker - Python equivalent of BumpSetCut's KalmanBallTracker.swift

Advanced ball tracking with constant-velocity Kalman filter prediction.
Handles occlusions, missed detections, and provides smooth trajectory estimates.
"""

import numpy as np
import math
from typing import Optional, Tuple, List, Dict
from dataclasses import dataclass
from processor_config import ProcessorConfig


@dataclass
class TrackingState:
    """Represents the state of a ball track."""
    # Position and velocity (x, y, vx, vy)
    state: np.ndarray           # 4x1 state vector [x, y, vx, vy]
    covariance: np.ndarray      # 4x4 covariance matrix
    confidence: float           # tracking confidence [0-1]
    last_detection_frame: int   # frame number of last detection
    prediction_count: int       # consecutive frames without detection
    track_id: int              # unique track identifier
    age: int                   # total age of track in frames


class KalmanBallTracker:
    """
    Advanced ball tracking using Kalman filter with constant velocity model.
    Mirrors BumpSetCut's KalmanBallTracker.swift functionality.
    """
    
    def __init__(self, config: ProcessorConfig):
        self.config = config
        self.tracks: Dict[int, TrackingState] = {}
        self.next_track_id = 0
        self.frame_count = 0
        
        # Kalman filter matrices (constant velocity model)
        self.dt = 1.0  # Time step (1 frame)
        
        # State transition matrix (constant velocity)
        self.F = np.array([
            [1, 0, self.dt, 0],      # x = x + vx*dt
            [0, 1, 0, self.dt],      # y = y + vy*dt  
            [0, 0, 1, 0],            # vx = vx
            [0, 0, 0, 1]             # vy = vy
        ])
        
        # Observation matrix (we observe position only)
        self.H = np.array([
            [1, 0, 0, 0],            # observe x
            [0, 1, 0, 0]             # observe y
        ])
        
        # Process noise covariance
        self.Q = np.array([
            [self.config.process_noise_position, 0, 0, 0],
            [0, self.config.process_noise_position, 0, 0],
            [0, 0, self.config.process_noise_velocity, 0],
            [0, 0, 0, self.config.process_noise_velocity]
        ])
        
        # Measurement noise covariance
        self.R = np.array([
            [self.config.measurement_noise, 0],
            [0, self.config.measurement_noise]
        ])
        
        print(f"🎯 Kalman Ball Tracker initialized with {len(self.config.to_dict())} parameters")
    
    def update(self, detections: List[Tuple[float, float, float]], frame_time: float) -> List[TrackingState]:
        """
        Update tracker with new detections.
        
        Args:
            detections: List of (x, y, confidence) detections
            frame_time: Current frame timestamp
            
        Returns:
            List of active tracking states
        """
        self.frame_count += 1
        
        # 1. Predict all existing tracks
        self._predict_tracks()
        
        # 2. Associate detections with tracks
        associations = self._associate_detections(detections)
        
        # 3. Update tracks with associated detections
        self._update_tracks(associations)
        
        # 4. Create new tracks for unassociated detections
        self._create_new_tracks(associations, detections)
        
        # 5. Remove old/lost tracks
        self._cleanup_tracks()
        
        # 6. Update tracking confidence for all tracks
        self._update_confidence()
        
        return list(self.tracks.values())
    
    def get_best_track(self) -> Optional[TrackingState]:
        """Get the track with highest confidence."""
        if not self.tracks:
            return None
        
        return max(self.tracks.values(), key=lambda t: t.confidence)
    
    def get_predicted_position(self, track_id: int, frames_ahead: int = 1) -> Optional[Tuple[float, float]]:
        """Predict future position of a track."""
        if track_id not in self.tracks:
            return None
        
        track = self.tracks[track_id]
        
        # Predict position using constant velocity
        dt = frames_ahead * self.dt
        pred_x = track.state[0] + track.state[2] * dt
        pred_y = track.state[1] + track.state[3] * dt
        
        return (float(pred_x), float(pred_y))
    
    def _predict_tracks(self):
        """Predict next state for all tracks using Kalman filter."""
        for track in self.tracks.values():
            # Predict state: x_pred = F * x
            track.state = self.F @ track.state
            
            # Predict covariance: P_pred = F * P * F^T + Q
            track.covariance = self.F @ track.covariance @ self.F.T + self.Q
            
            # Increment prediction count
            track.prediction_count += 1
            track.age += 1
    
    def _associate_detections(self, detections: List[Tuple[float, float, float]]) -> Dict[int, int]:
        """
        Associate detections with existing tracks using nearest neighbor with gating.
        
        Returns:
            Dictionary mapping track_id -> detection_index
        """
        associations = {}
        used_detections = set()
        
        # Calculate distances between all tracks and detections
        distances = {}
        for track_id, track in self.tracks.items():
            pred_pos = (track.state[0], track.state[1])
            
            for det_idx, (det_x, det_y, conf) in enumerate(detections):
                if det_idx in used_detections:
                    continue
                
                # Calculate Mahalanobis distance for proper gating
                distance = self._mahalanobis_distance(track, (det_x, det_y))
                
                if distance < self.config.association_gate_threshold:
                    distances[(track_id, det_idx)] = distance
        
        # Greedy nearest neighbor association
        sorted_pairs = sorted(distances.items(), key=lambda x: x[1])
        
        for (track_id, det_idx), distance in sorted_pairs:
            if track_id not in associations and det_idx not in used_detections:
                associations[track_id] = det_idx
                used_detections.add(det_idx)
        
        return associations
    
    def _mahalanobis_distance(self, track: TrackingState, detection: Tuple[float, float]) -> float:
        """Calculate Mahalanobis distance for gating."""
        # Innovation (measurement residual)
        z = np.array([[detection[0]], [detection[1]]])
        z_pred = self.H @ track.state.reshape(-1, 1)
        y = z - z_pred
        
        # Innovation covariance
        S = self.H @ track.covariance @ self.H.T + self.R
        
        # Mahalanobis distance
        try:
            distance = float(y.T @ np.linalg.inv(S) @ y)
            return math.sqrt(distance)
        except np.linalg.LinAlgError:
            # Fallback to Euclidean distance if covariance is singular
            return math.sqrt(float(y.T @ y))
    
    def _update_tracks(self, associations: Dict[int, int]):
        """Update tracks with associated detections using Kalman filter."""
        for track_id, det_idx in associations.items():
            track = self.tracks[track_id]
            
            # Get measurement
            # Note: detections should be passed separately to this function
            # For now, we'll store them as instance variable
            if hasattr(self, '_current_detections'):
                det_x, det_y, conf = self._current_detections[det_idx]
                z = np.array([[det_x], [det_y]])
                
                # Kalman update
                z_pred = self.H @ track.state.reshape(-1, 1)
                y = z - z_pred  # Innovation
                
                S = self.H @ track.covariance @ self.H.T + self.R  # Innovation covariance
                K = track.covariance @ self.H.T @ np.linalg.pinv(S)  # Kalman gain
                
                # Update state and covariance
                track.state = (track.state.reshape(-1, 1) + K @ y).flatten()
                I = np.eye(4)
                track.covariance = (I - K @ self.H) @ track.covariance
                
                # Reset prediction count and update frame
                track.prediction_count = 0
                track.last_detection_frame = self.frame_count
    
    def _create_new_tracks(self, associations: Dict[int, int], detections: List[Tuple[float, float, float]]):
        """Create new tracks for unassociated detections."""
        # Store detections for update function
        self._current_detections = detections
        
        associated_detections = set(associations.values())
        
        for det_idx, (det_x, det_y, conf) in enumerate(detections):
            if det_idx not in associated_detections and conf >= self.config.min_tracking_confidence:
                # Create new track
                track_id = self.next_track_id
                self.next_track_id += 1
                
                # Initialize state [x, y, vx, vy] with zero velocity
                initial_state = np.array([det_x, det_y, 0.0, 0.0])
                
                # Initialize covariance with high uncertainty
                initial_covariance = np.eye(4) * 100.0
                
                track = TrackingState(
                    state=initial_state,
                    covariance=initial_covariance,
                    confidence=conf,
                    last_detection_frame=self.frame_count,
                    prediction_count=0,
                    track_id=track_id,
                    age=0
                )
                
                self.tracks[track_id] = track
    
    def _cleanup_tracks(self):
        """Remove tracks that haven't been updated for too long."""
        tracks_to_remove = []
        
        for track_id, track in self.tracks.items():
            frames_since_detection = self.frame_count - track.last_detection_frame
            
            if frames_since_detection > self.config.max_missed_frames:
                tracks_to_remove.append(track_id)
            elif track.confidence < 0.1:  # Very low confidence
                tracks_to_remove.append(track_id)
        
        for track_id in tracks_to_remove:
            del self.tracks[track_id]
    
    def _update_confidence(self):
        """Update tracking confidence for all tracks."""
        for track in self.tracks.values():
            # Decay confidence over time
            track.confidence *= self.config.confidence_decay_rate
            
            # Boost confidence if recently detected
            if track.prediction_count == 0:
                track.confidence = min(1.0, track.confidence + self.config.confidence_boost_on_detection)
            
            # Clamp confidence to valid range
            track.confidence = max(0.0, min(1.0, track.confidence))
    
    def get_track_velocity(self, track_id: int) -> Optional[Tuple[float, float]]:
        """Get velocity of a specific track."""
        if track_id not in self.tracks:
            return None
        
        track = self.tracks[track_id]
        return (float(track.state[2]), float(track.state[3]))
    
    def get_track_statistics(self) -> Dict:
        """Get statistics about current tracking state."""
        if not self.tracks:
            return {"active_tracks": 0}
        
        confidences = [t.confidence for t in self.tracks.values()]
        ages = [t.age for t in self.tracks.values()]
        prediction_counts = [t.prediction_count for t in self.tracks.values()]
        
        return {
            "active_tracks": len(self.tracks),
            "avg_confidence": sum(confidences) / len(confidences),
            "max_confidence": max(confidences),
            "avg_age": sum(ages) / len(ages),
            "max_predictions": max(prediction_counts) if prediction_counts else 0,
            "tracks_predicting": sum(1 for p in prediction_counts if p > 0)
        }
    
    def reset(self):
        """Reset tracker state."""
        self.tracks.clear()
        self.next_track_id = 0
        self.frame_count = 0
        
    def export_trajectories(self) -> Dict:
        """Export trajectory data for analysis."""
        trajectories = {}
        
        for track_id, track in self.tracks.items():
            trajectories[track_id] = {
                "position": [float(track.state[0]), float(track.state[1])],
                "velocity": [float(track.state[2]), float(track.state[3])],
                "confidence": track.confidence,
                "age": track.age,
                "last_detection_frame": track.last_detection_frame,
                "prediction_count": track.prediction_count
            }
        
        return {
            "frame": self.frame_count,
            "tracks": trajectories,
            "statistics": self.get_track_statistics()
        }


if __name__ == "__main__":
    # Test the Kalman tracker
    from processor_config import ProcessorConfig
    
    config = ProcessorConfig()
    tracker = KalmanBallTracker(config)
    
    # Simulate some detections
    test_detections = [
        [(100, 200, 0.8), (150, 250, 0.7)],  # Frame 1
        [(105, 205, 0.9)],                   # Frame 2 - one track continues
        [(110, 210, 0.8), (200, 300, 0.6)], # Frame 3 - track continues + new track
        [(115, 215, 0.7)],                   # Frame 4 - only first track
        []                                   # Frame 5 - no detections
    ]
    
    print("🧪 Testing Kalman Ball Tracker:")
    
    for frame_idx, detections in enumerate(test_detections):
        tracks = tracker.update(detections, frame_idx * 0.033)  # 30 FPS
        
        print(f"Frame {frame_idx}: {len(detections)} detections → {len(tracks)} tracks")
        
        for track in tracks:
            pos = (track.state[0], track.state[1])
            vel = (track.state[2], track.state[3])
            print(f"  Track {track.track_id}: pos=({pos[0]:.1f},{pos[1]:.1f}) "
                  f"vel=({vel[0]:.1f},{vel[1]:.1f}) conf={track.confidence:.3f}")
    
    print(f"\n📊 Final statistics: {tracker.get_track_statistics()}")
    print("✅ Kalman tracker test completed!")