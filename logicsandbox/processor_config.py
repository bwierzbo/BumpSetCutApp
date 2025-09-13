"""
Processor Configuration - Mirrors BumpSetCut's ProcessorConfig.swift

Comprehensive configuration system for all volleyball processing parameters.
This allows parameter tuning that can be ported back to BumpSetCut iOS app.
"""

import json
from dataclasses import dataclass, asdict
from typing import Dict, Any, Optional


@dataclass
class ProcessorConfig:
    """
    Complete configuration matching BumpSetCut's ProcessorConfig.swift
    All parameters are tunable for experimentation.
    """
    
    # === CORE ML DETECTION ===
    confidence_threshold: float = 0.3
    ml_model_name: str = "bestv2"
    enable_ml_detection: bool = True
    
    # === KALMAN BALL TRACKER ===
    # Motion model parameters
    process_noise_position: float = 1.0
    process_noise_velocity: float = 0.5
    measurement_noise: float = 10.0
    
    # Association gating
    association_gate_threshold: float = 50.0  # pixels
    max_missed_frames: int = 15
    initial_velocity_threshold: float = 5.0   # pixels per frame
    
    # Tracking confidence
    min_tracking_confidence: float = 0.3
    confidence_decay_rate: float = 0.95
    confidence_boost_on_detection: float = 0.1
    
    # === BALLISTICS GATE (PHYSICS VALIDATION) ===
    enable_enhanced_physics: bool = True
    
    # Quadratic trajectory fitting
    min_points_for_fit: int = 5
    max_trajectory_error: float = 50.0  # pixels
    trajectory_confidence_threshold: float = 0.6
    
    # Physics constraints
    gravity_acceleration: float = 9.81  # m/s²
    max_horizontal_velocity: float = 30.0  # m/s
    max_vertical_velocity: float = 20.0   # m/s
    min_flight_time: float = 0.2  # seconds
    
    # Trajectory validation scoring
    physics_score_weight: float = 0.4
    smoothness_score_weight: float = 0.3
    continuity_score_weight: float = 0.3
    min_physics_score: float = 0.5
    
    # === RALLY DECIDER (HYSTERESIS STATE MACHINE) ===
    # Rally detection thresholds
    rally_start_threshold: float = 0.7      # confidence to start rally
    rally_end_threshold: float = 0.3        # confidence to end rally
    rally_hysteresis_time: float = 2.0      # seconds
    
    # State timing
    min_rally_duration: float = 1.5         # minimum rally length
    max_gap_in_rally: float = 1.0          # max gap before ending rally
    rally_cooldown_period: float = 0.5     # time between rallies
    
    # Contact estimation
    contact_detection_threshold: float = 0.8
    min_contact_separation: float = 0.3    # seconds between contacts
    velocity_change_threshold: float = 15.0 # pixels/frame for contact
    
    # === SEGMENT BUILDER ===
    # Time padding
    rally_start_padding: float = 0.5       # seconds before rally
    rally_end_padding: float = 0.3         # seconds after rally
    
    # Segment validation
    min_segment_duration: float = 2.0      # minimum exportable segment
    max_segment_gap: float = 1.5           # merge segments within this gap
    min_detections_per_second: float = 3.0 # minimum detection density
    
    # Quality scoring
    segment_quality_threshold: float = 0.6
    detection_consistency_weight: float = 0.4
    physics_consistency_weight: float = 0.6
    
    # === DEBUG AND VISUALIZATION ===
    enable_debug_output: bool = True
    debug_frame_stride: int = 3           # process every Nth frame in debug
    save_trajectory_data: bool = True
    enable_physics_visualization: bool = True
    
    # Annotation settings
    detection_circle_radius: int = 20
    trajectory_trail_length: int = 30
    confidence_text_size: float = 0.6
    
    # Colors (RGB tuples)
    detection_color: tuple = (0, 255, 0)     # Green
    trajectory_color: tuple = (255, 0, 0)     # Blue  
    rally_active_color: tuple = (0, 255, 255) # Yellow
    physics_valid_color: tuple = (0, 255, 0)  # Green
    physics_invalid_color: tuple = (0, 0, 255) # Red
    
    # === PERFORMANCE TUNING ===
    max_processing_fps: float = 30.0       # limit for heavy processing
    enable_frame_skipping: bool = False    # skip frames if behind
    parallel_processing: bool = True       # enable multi-threading
    
    # Memory management
    max_trajectory_history: int = 300      # frames to keep in memory
    cleanup_old_tracks: bool = True
    track_cleanup_interval: int = 100      # frames
    
    def validate(self) -> bool:
        """Validate configuration parameters are within reasonable bounds."""
        try:
            # Confidence thresholds
            assert 0.0 <= self.confidence_threshold <= 1.0
            assert 0.0 <= self.rally_start_threshold <= 1.0
            assert 0.0 <= self.rally_end_threshold <= 1.0
            assert self.rally_end_threshold < self.rally_start_threshold
            
            # Time parameters
            assert self.min_rally_duration > 0
            assert self.rally_hysteresis_time > 0
            assert self.rally_start_padding >= 0
            assert self.rally_end_padding >= 0
            
            # Physics parameters
            assert self.gravity_acceleration > 0
            assert self.max_horizontal_velocity > 0
            assert self.max_vertical_velocity > 0
            
            # Kalman tracker parameters
            assert self.process_noise_position > 0
            assert self.process_noise_velocity > 0
            assert self.measurement_noise > 0
            assert self.max_missed_frames > 0
            
            return True
            
        except AssertionError as e:
            print(f"❌ Configuration validation failed: {e}")
            return False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'ProcessorConfig':
        """Create config from dictionary."""
        return cls(**data)
    
    def save_to_file(self, filepath: str) -> bool:
        """Save configuration to JSON file."""
        try:
            with open(filepath, 'w') as f:
                json.dump(self.to_dict(), f, indent=2)
            print(f"✅ Configuration saved to {filepath}")
            return True
        except Exception as e:
            print(f"❌ Failed to save configuration: {e}")
            return False
    
    @classmethod
    def load_from_file(cls, filepath: str) -> Optional['ProcessorConfig']:
        """Load configuration from JSON file."""
        try:
            with open(filepath, 'r') as f:
                data = json.load(f)
            config = cls.from_dict(data)
            if config.validate():
                print(f"✅ Configuration loaded from {filepath}")
                return config
            else:
                print(f"❌ Invalid configuration in {filepath}")
                return None
        except Exception as e:
            print(f"❌ Failed to load configuration: {e}")
            return None
    
    def copy_with_overrides(self, **overrides) -> 'ProcessorConfig':
        """Create a copy with specific parameters overridden."""
        data = self.to_dict()
        data.update(overrides)
        return self.from_dict(data)
    
    def print_summary(self):
        """Print a formatted summary of key parameters."""
        print("🎾 Volleyball Processing Configuration Summary")
        print(f"   ML Confidence Threshold: {self.confidence_threshold}")
        print(f"   Rally Start/End Thresholds: {self.rally_start_threshold}/{self.rally_end_threshold}")
        print(f"   Physics Validation: {'✅ Enabled' if self.enable_enhanced_physics else '❌ Disabled'}")
        print(f"   Kalman Tracking: Gate={self.association_gate_threshold}px, MaxMissed={self.max_missed_frames}")
        print(f"   Segment Padding: Start={self.rally_start_padding}s, End={self.rally_end_padding}s")
        print(f"   Min Rally Duration: {self.min_rally_duration}s")


# Predefined configuration presets for different use cases
class ConfigPresets:
    """Predefined configuration presets for different scenarios."""
    
    @staticmethod
    def conservative() -> ProcessorConfig:
        """Conservative settings - fewer false positives, may miss some rallies."""
        return ProcessorConfig(
            confidence_threshold=0.5,
            rally_start_threshold=0.8,
            rally_end_threshold=0.4,
            min_rally_duration=2.0,
            enable_enhanced_physics=True,
            min_physics_score=0.7
        )
    
    @staticmethod 
    def aggressive() -> ProcessorConfig:
        """Aggressive settings - catch more rallies, may have false positives."""
        return ProcessorConfig(
            confidence_threshold=0.2,
            rally_start_threshold=0.5,
            rally_end_threshold=0.2,
            min_rally_duration=1.0,
            enable_enhanced_physics=True,
            min_physics_score=0.3
        )
    
    @staticmethod
    def high_precision() -> ProcessorConfig:
        """High precision - best quality rallies only."""
        return ProcessorConfig(
            confidence_threshold=0.6,
            rally_start_threshold=0.9,
            rally_end_threshold=0.5,
            min_rally_duration=3.0,
            enable_enhanced_physics=True,
            min_physics_score=0.8,
            segment_quality_threshold=0.8
        )
    
    @staticmethod
    def debug_mode() -> ProcessorConfig:
        """Debug configuration - verbose output, all features enabled."""
        return ProcessorConfig(
            confidence_threshold=0.3,
            enable_debug_output=True,
            save_trajectory_data=True,
            enable_physics_visualization=True,
            debug_frame_stride=1  # Process every frame for debugging
        )


if __name__ == "__main__":
    # Test configuration system
    config = ProcessorConfig()
    config.print_summary()
    
    # Test validation
    assert config.validate(), "Default configuration should be valid"
    
    # Test presets
    conservative = ConfigPresets.conservative()
    print("\n🔒 Conservative preset:")
    conservative.print_summary()
    
    aggressive = ConfigPresets.aggressive() 
    print("\n🚀 Aggressive preset:")
    aggressive.print_summary()
    
    print("\n✅ Configuration system test passed!")