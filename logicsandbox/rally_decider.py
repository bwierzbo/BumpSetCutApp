"""
Rally Decider - Python equivalent of BumpSetCut's RallyDecider.swift

Hysteresis-based state machine for detecting volleyball rally periods.
Prevents flicker between rally/dead states and provides smooth state transitions.
"""

import math
from enum import Enum
from typing import List, Tuple, Optional, Dict
from dataclasses import dataclass
from processor_config import ProcessorConfig
from ballistics_gate import PhysicsValidation


class RallyState(Enum):
    """Rally state enumeration matching BumpSetCut."""
    IDLE = "idle"                    # No activity detected
    POTENTIAL = "potential"          # Possible rally starting
    ACTIVE = "active"               # Rally confirmed and ongoing
    ENDING = "ending"               # Rally winding down


@dataclass
class RallyEvent:
    """Represents a rally state change event."""
    timestamp: float
    old_state: RallyState
    new_state: RallyState
    confidence: float
    reason: str


@dataclass
class RallyPeriod:
    """Represents a detected rally period."""
    start_time: float
    end_time: float
    duration: float
    max_confidence: float
    avg_confidence: float
    estimated_contacts: int
    quality_score: float
    
    
@dataclass
class RallyContext:
    """Context information for rally decision making."""
    current_time: float
    detection_confidence: float
    tracking_confidence: float
    physics_validation: Optional[PhysicsValidation]
    velocity_magnitude: float
    time_since_last_detection: float
    consecutive_detections: int


class RallyDecider:
    """
    Hysteresis-based rally detection state machine.
    Mirrors BumpSetCut's RallyDecider.swift functionality.
    """
    
    def __init__(self, config: ProcessorConfig):
        self.config = config
        
        # State machine
        self.current_state = RallyState.IDLE
        self.state_start_time = 0.0
        self.last_state_change_time = 0.0
        
        # Hysteresis tracking
        self.rally_confidence_history: List[Tuple[float, float]] = []  # (time, confidence)
        self.last_high_confidence_time = 0.0
        self.last_detection_time = 0.0
        
        # Rally tracking
        self.current_rally_start = 0.0
        self.current_rally_confidence_sum = 0.0
        self.current_rally_confidence_count = 0
        self.current_rally_max_confidence = 0.0
        self.estimated_contacts = 0
        
        # History
        self.completed_rallies: List[RallyPeriod] = []
        self.state_change_events: List[RallyEvent] = []
        
        # Contact detection
        self.last_velocity_magnitude = 0.0
        self.velocity_history: List[Tuple[float, float]] = []  # (time, velocity)
        
        print(f"🏐 Rally Decider initialized with hysteresis thresholds: {config.rally_start_threshold:.2f}/{config.rally_end_threshold:.2f}")
    
    def update(self, context: RallyContext) -> RallyState:
        """
        Update rally state based on current context.
        
        Args:
            context: Current detection and tracking context
            
        Returns:
            Current rally state after update
        """
        # Update internal tracking
        self._update_confidence_history(context)
        self._update_velocity_tracking(context)
        
        # Calculate rally confidence score
        rally_confidence = self._calculate_rally_confidence(context)
        
        # State machine logic with hysteresis
        new_state = self._determine_new_state(rally_confidence, context)
        
        # Handle state transitions
        if new_state != self.current_state:
            self._transition_to_state(new_state, rally_confidence, context.current_time)
        
        # Update rally tracking
        self._update_rally_tracking(rally_confidence, context)
        
        return self.current_state
    
    def _calculate_rally_confidence(self, context: RallyContext) -> float:
        """Calculate overall rally confidence from multiple sources."""
        
        # Base confidence from detection
        detection_conf = context.detection_confidence if context.detection_confidence > 0 else 0.0
        
        # Tracking confidence contribution
        tracking_conf = context.tracking_confidence if context.tracking_confidence > 0 else 0.0
        
        # Physics validation contribution
        physics_conf = 0.0
        if context.physics_validation and context.physics_validation.is_valid:
            physics_conf = context.physics_validation.physics_score
        
        # Temporal consistency (recent detection history)
        temporal_conf = self._calculate_temporal_confidence(context.current_time)
        
        # Motion consistency (velocity patterns)
        motion_conf = self._calculate_motion_confidence(context.velocity_magnitude)
        
        # Weighted combination
        weights = {
            'detection': 0.4,
            'tracking': 0.2, 
            'physics': 0.2,
            'temporal': 0.1,
            'motion': 0.1
        }
        
        rally_confidence = (
            weights['detection'] * detection_conf +
            weights['tracking'] * tracking_conf +
            weights['physics'] * physics_conf +
            weights['temporal'] * temporal_conf +
            weights['motion'] * motion_conf
        )
        
        return max(0.0, min(1.0, rally_confidence))
    
    def _calculate_temporal_confidence(self, current_time: float) -> float:
        """Calculate confidence based on recent detection history."""
        if not self.rally_confidence_history:
            return 0.0
        
        # Look at recent history (last 2 seconds)
        recent_window = 2.0
        recent_confidences = [
            conf for time, conf in self.rally_confidence_history
            if current_time - time <= recent_window
        ]
        
        if not recent_confidences:
            return 0.0
        
        # Average confidence in recent window
        avg_recent_conf = sum(recent_confidences) / len(recent_confidences)
        
        # Boost if consistently high
        consistency_bonus = 0.0
        if len(recent_confidences) >= 5:  # At least 5 recent detections
            high_conf_count = sum(1 for conf in recent_confidences if conf > 0.6)
            consistency_bonus = (high_conf_count / len(recent_confidences)) * 0.2
        
        return min(1.0, avg_recent_conf + consistency_bonus)
    
    def _calculate_motion_confidence(self, velocity_magnitude: float) -> float:
        """Calculate confidence based on motion patterns."""
        # Volleyball should have reasonable velocity
        min_reasonable_vel = 10.0   # pixels per frame
        max_reasonable_vel = 200.0  # pixels per frame
        
        if velocity_magnitude == 0:
            return 0.0
        
        if min_reasonable_vel <= velocity_magnitude <= max_reasonable_vel:
            return 1.0
        elif velocity_magnitude < min_reasonable_vel:
            return velocity_magnitude / min_reasonable_vel
        else:
            return max(0.0, 1.0 - (velocity_magnitude - max_reasonable_vel) / max_reasonable_vel)
    
    def _determine_new_state(self, rally_confidence: float, context: RallyContext) -> RallyState:
        """Determine new state based on hysteresis logic."""
        current_time = context.current_time
        time_in_state = current_time - self.state_start_time
        time_since_last_detection = context.time_since_last_detection
        
        if self.current_state == RallyState.IDLE:
            # Transition to POTENTIAL if confidence starts rising
            if rally_confidence > self.config.rally_end_threshold:
                return RallyState.POTENTIAL
        
        elif self.current_state == RallyState.POTENTIAL:
            # Transition to ACTIVE if confidence crosses start threshold
            if rally_confidence >= self.config.rally_start_threshold:
                return RallyState.ACTIVE
            
            # Return to IDLE if confidence drops and we've been in POTENTIAL long enough
            elif (rally_confidence <= self.config.rally_end_threshold and 
                  time_in_state > 1.0):
                return RallyState.IDLE
        
        elif self.current_state == RallyState.ACTIVE:
            # Stay ACTIVE with hysteresis - only end if confidence drops significantly
            if (rally_confidence <= self.config.rally_end_threshold and
                time_since_last_detection > self.config.max_gap_in_rally):
                return RallyState.ENDING
        
        elif self.current_state == RallyState.ENDING:
            # Quick return to ACTIVE if confidence rises again
            if rally_confidence >= self.config.rally_start_threshold:
                return RallyState.ACTIVE
            
            # Transition to IDLE after cooldown period
            elif time_in_state > self.config.rally_cooldown_period:
                return RallyState.IDLE
        
        return self.current_state
    
    def _transition_to_state(self, new_state: RallyState, confidence: float, timestamp: float):
        """Handle state transition logic."""
        old_state = self.current_state
        
        # Create state change event
        event = RallyEvent(
            timestamp=timestamp,
            old_state=old_state,
            new_state=new_state,
            confidence=confidence,
            reason=self._get_transition_reason(old_state, new_state, confidence)
        )
        
        self.state_change_events.append(event)
        
        # Handle state-specific logic
        if new_state == RallyState.ACTIVE and old_state != RallyState.ACTIVE:
            # Starting a new rally
            self._start_rally(timestamp)
        
        elif old_state == RallyState.ACTIVE and new_state != RallyState.ACTIVE:
            # Ending current rally  
            self._end_rally(timestamp)
        
        # Update state
        self.current_state = new_state
        self.state_start_time = timestamp
        self.last_state_change_time = timestamp
        
        print(f"🏐 Rally state: {old_state.value} → {new_state.value} (conf={confidence:.3f})")
    
    def _start_rally(self, timestamp: float):
        """Initialize rally tracking."""
        self.current_rally_start = timestamp
        self.current_rally_confidence_sum = 0.0
        self.current_rally_confidence_count = 0
        self.current_rally_max_confidence = 0.0
        self.estimated_contacts = 0
    
    def _end_rally(self, timestamp: float):
        """Finalize and record completed rally."""
        if self.current_rally_confidence_count > 0:
            duration = timestamp - self.current_rally_start
            avg_confidence = self.current_rally_confidence_sum / self.current_rally_confidence_count
            
            # Only record rallies that meet minimum duration
            if duration >= self.config.min_rally_duration:
                quality_score = self._calculate_rally_quality(duration, avg_confidence)
                
                rally = RallyPeriod(
                    start_time=self.current_rally_start,
                    end_time=timestamp,
                    duration=duration,
                    max_confidence=self.current_rally_max_confidence,
                    avg_confidence=avg_confidence,
                    estimated_contacts=self.estimated_contacts,
                    quality_score=quality_score
                )
                
                self.completed_rallies.append(rally)
                print(f"✅ Rally completed: {duration:.1f}s, contacts≈{self.estimated_contacts}, quality={quality_score:.3f}")
    
    def _calculate_rally_quality(self, duration: float, avg_confidence: float) -> float:
        """Calculate quality score for a rally."""
        # Duration score (longer rallies are generally better)
        duration_score = min(1.0, duration / 10.0)  # Max score at 10+ seconds
        
        # Confidence score
        confidence_score = avg_confidence
        
        # Contact score (more contacts = better rally)
        contact_score = min(1.0, self.estimated_contacts / 10.0)  # Max score at 10+ contacts
        
        # Weighted combination
        quality = (duration_score * 0.3 + confidence_score * 0.4 + contact_score * 0.3)
        return quality
    
    def _update_confidence_history(self, context: RallyContext):
        """Update confidence history for temporal analysis."""
        self.rally_confidence_history.append((context.current_time, context.detection_confidence))
        
        # Limit history size
        max_history = 100
        if len(self.rally_confidence_history) > max_history:
            self.rally_confidence_history.pop(0)
        
        # Track last high confidence time
        if context.detection_confidence > 0.7:
            self.last_high_confidence_time = context.current_time
        
        if context.detection_confidence > 0:
            self.last_detection_time = context.current_time
    
    def _update_velocity_tracking(self, context: RallyContext):
        """Update velocity tracking for contact detection."""
        current_vel = context.velocity_magnitude
        current_time = context.current_time
        
        self.velocity_history.append((current_time, current_vel))
        
        # Limit velocity history
        if len(self.velocity_history) > 50:
            self.velocity_history.pop(0)
        
        # Detect potential ball contacts (significant velocity changes)
        if (self.last_velocity_magnitude > 0 and 
            abs(current_vel - self.last_velocity_magnitude) > self.config.velocity_change_threshold):
            
            # Check if enough time has passed since last contact
            if (not hasattr(self, 'last_contact_time') or 
                current_time - self.last_contact_time > self.config.min_contact_separation):
                
                self.estimated_contacts += 1
                self.last_contact_time = current_time
        
        self.last_velocity_magnitude = current_vel
    
    def _update_rally_tracking(self, rally_confidence: float, context: RallyContext):
        """Update current rally statistics."""
        if self.current_state == RallyState.ACTIVE:
            self.current_rally_confidence_sum += rally_confidence
            self.current_rally_confidence_count += 1
            self.current_rally_max_confidence = max(self.current_rally_max_confidence, rally_confidence)
    
    def _get_transition_reason(self, old_state: RallyState, new_state: RallyState, confidence: float) -> str:
        """Get human-readable reason for state transition."""
        if old_state == RallyState.IDLE and new_state == RallyState.POTENTIAL:
            return f"Confidence rising ({confidence:.3f})"
        elif old_state == RallyState.POTENTIAL and new_state == RallyState.ACTIVE:
            return f"Rally confirmed ({confidence:.3f})"
        elif old_state == RallyState.ACTIVE and new_state == RallyState.ENDING:
            return f"Rally ending ({confidence:.3f})"
        elif new_state == RallyState.IDLE:
            return f"Returning to idle ({confidence:.3f})"
        else:
            return f"State change ({confidence:.3f})"
    
    def get_current_rally_info(self) -> Optional[Dict]:
        """Get information about current rally if active."""
        if self.current_state != RallyState.ACTIVE:
            return None
        
        return {
            "start_time": self.current_rally_start,
            "duration": self.state_start_time - self.current_rally_start,
            "estimated_contacts": self.estimated_contacts,
            "max_confidence": self.current_rally_max_confidence,
            "avg_confidence": (self.current_rally_confidence_sum / self.current_rally_confidence_count 
                             if self.current_rally_confidence_count > 0 else 0.0)
        }
    
    def get_rally_statistics(self) -> Dict:
        """Get statistics about detected rallies."""
        if not self.completed_rallies:
            return {
                "total_rallies": 0,
                "total_rally_time": 0.0,
                "avg_rally_duration": 0.0,
                "avg_rally_quality": 0.0
            }
        
        total_time = sum(r.duration for r in self.completed_rallies)
        avg_duration = total_time / len(self.completed_rallies)
        avg_quality = sum(r.quality_score for r in self.completed_rallies) / len(self.completed_rallies)
        total_contacts = sum(r.estimated_contacts for r in self.completed_rallies)
        
        return {
            "total_rallies": len(self.completed_rallies),
            "total_rally_time": total_time,
            "avg_rally_duration": avg_duration,
            "avg_rally_quality": avg_quality,
            "total_contacts": total_contacts,
            "avg_contacts_per_rally": total_contacts / len(self.completed_rallies),
            "current_state": self.current_state.value
        }
    
    def reset(self):
        """Reset rally decider state."""
        self.current_state = RallyState.IDLE
        self.state_start_time = 0.0
        self.rally_confidence_history.clear()
        self.completed_rallies.clear()
        self.state_change_events.clear()
        self.estimated_contacts = 0


if __name__ == "__main__":
    # Test the rally decider
    from processor_config import ProcessorConfig
    from ballistics_gate import PhysicsValidation
    
    config = ProcessorConfig()
    rally_decider = RallyDecider(config)
    
    print("🧪 Testing Rally Decider:")
    
    # Simulate a rally scenario
    test_scenarios = [
        # Time, detection_conf, tracking_conf, velocity
        (0.0, 0.0, 0.0, 0.0),      # No activity
        (1.0, 0.4, 0.3, 10.0),     # Low confidence start
        (2.0, 0.6, 0.5, 25.0),     # Rising confidence
        (3.0, 0.8, 0.7, 40.0),     # High confidence - should trigger rally
        (4.0, 0.9, 0.8, 35.0),     # Rally continues
        (5.0, 0.7, 0.6, 30.0),     # Still in rally
        (6.0, 0.3, 0.4, 15.0),     # Confidence dropping
        (7.0, 0.1, 0.2, 5.0),      # Very low confidence
        (8.0, 0.0, 0.0, 0.0),      # No detection - should end rally
        (10.0, 0.0, 0.0, 0.0),     # Idle period
        (12.0, 0.9, 0.8, 45.0),    # New rally starts
    ]
    
    for time, det_conf, track_conf, velocity in test_scenarios:
        context = RallyContext(
            current_time=time,
            detection_confidence=det_conf,
            tracking_confidence=track_conf,
            physics_validation=None,
            velocity_magnitude=velocity,
            time_since_last_detection=0.1 if det_conf > 0 else 1.0,
            consecutive_detections=5 if det_conf > 0 else 0
        )
        
        state = rally_decider.update(context)
        
        if state == RallyState.ACTIVE:
            rally_info = rally_decider.get_current_rally_info()
            print(f"  Time {time:4.1f}s: {state.value:10s} (conf={det_conf:.1f}, duration={rally_info['duration']:.1f}s)")
        else:
            print(f"  Time {time:4.1f}s: {state.value:10s} (conf={det_conf:.1f})")
    
    # Final statistics
    stats = rally_decider.get_rally_statistics()
    print(f"\n📊 Final Rally Statistics:")
    print(f"   Total rallies: {stats['total_rallies']}")
    print(f"   Total rally time: {stats['total_rally_time']:.1f}s")
    print(f"   Average duration: {stats['avg_rally_duration']:.1f}s")
    print(f"   Average quality: {stats['avg_rally_quality']:.3f}")
    
    print("✅ Rally decider test completed!")