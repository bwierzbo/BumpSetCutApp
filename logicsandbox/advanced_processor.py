"""
Advanced Video Processor - Complete BumpSetCut pipeline implementation

Integrates all components:
- MLModelTracker (CoreML detection)  
- KalmanBallTracker (advanced tracking)
- BallisticsGate (physics validation)
- RallyDecider (hysteresis state machine)
- SegmentBuilder (advanced segmentation)
- Enhanced debug visualization

This provides BumpSetCut parity for parameter experimentation.
"""

import cv2
import numpy as np
import time
from typing import List, Dict, Tuple, Optional
from dataclasses import dataclass

# Import all our sophisticated components
from processor_config import ProcessorConfig
from ml_integration import MLModelTracker
from kalman_ball_tracker import KalmanBallTracker, TrackingState
from ballistics_gate import BallisticsGate, PhysicsValidation
from rally_decider import RallyDecider, RallyState, RallyContext
from segment_builder import SegmentBuilder, TimeRange
from debug_annotator import DebugAnnotator, FrameDebugInfo


@dataclass
class ProcessingStats:
    """Statistics from the complete processing pipeline."""
    total_frames: int
    processed_frames: int
    total_detections: int
    total_tracks: int
    total_rallies: int
    total_segments: int
    processing_time: float
    
    # Detailed stats
    avg_detection_confidence: float
    avg_tracking_confidence: float
    avg_rally_quality: float
    physics_valid_percentage: float


class AdvancedVideoProcessor:
    """
    Complete volleyball processing pipeline with BumpSetCut parity.
    Allows parameter experimentation and optimization.
    """
    
    def __init__(self, config: ProcessorConfig):
        self.config = config
        
        # Initialize all processing components
        self.ml_tracker = MLModelTracker()
        self.kalman_tracker = KalmanBallTracker(config)
        self.ballistics_gate = BallisticsGate(config)
        self.rally_decider = RallyDecider(config)
        self.segment_builder = SegmentBuilder(config)
        
        # Processing state
        self.frame_debug_info: List[FrameDebugInfo] = []
        self.processing_stats = None
        
        print(f"🚀 AdvancedVideoProcessor initialized with BumpSetCut parity")
        config.print_summary()
    
    def process_video(self, video_path: str, output_debug_video: bool = True) -> ProcessingStats:
        """
        Process video through complete pipeline.
        
        Args:
            video_path: Path to input video
            output_debug_video: Whether to create debug visualization
            
        Returns:
            Processing statistics and results
        """
        print(f"🎾 Processing {video_path} with advanced pipeline...")
        start_time = time.time()
        
        # Reset all components
        self._reset_pipeline()
        
        # Open video
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise ValueError(f"Could not open video: {video_path}")
        
        # Get video properties
        fps = cap.get(cv2.CAP_PROP_FPS)
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        duration = total_frames / fps
        
        print(f"📹 Video: {total_frames} frames @ {fps:.1f}fps ({duration:.1f}s)")
        
        # Processing counters
        frame_idx = 0
        processed_count = 0
        detection_count = 0
        
        # Process each frame
        while True:
            ret, frame = cap.read()
            if not ret:
                break
            
            timestamp = frame_idx / fps
            
            # Process frame (respecting stride for performance)
            if frame_idx % self.config.debug_frame_stride == 0:
                debug_info = self._process_frame(frame, frame_idx, timestamp)
                self.frame_debug_info.append(debug_info)
                
                if debug_info.detections:
                    detection_count += len(debug_info.detections)
                
                processed_count += 1
                
                # Progress indicator
                if frame_idx % 300 == 0:  # Every 10 seconds at 30fps
                    progress = (frame_idx / total_frames) * 100
                    print(f"   Progress: {progress:.1f}% - Rally: {debug_info.rally_state.value}")
            
            frame_idx += 1
        
        cap.release()
        
        # Finalize processing
        segments = self.segment_builder.finalize(duration)
        rally_stats = self.rally_decider.get_rally_statistics()
        tracking_stats = self.kalman_tracker.get_track_statistics()
        
        # Calculate statistics
        processing_time = time.time() - start_time
        self.processing_stats = self._calculate_stats(
            total_frames, processed_count, detection_count, 
            rally_stats, segments, processing_time
        )
        
        # Create debug video if requested
        if output_debug_video and self.frame_debug_info:
            # Generate debug video path (avoid double "_debug")
            import os
            base_name = os.path.splitext(video_path)[0]
            debug_path = f"{base_name}_debug.mp4"
            self._create_debug_video(video_path, debug_path)
        
        # Print comprehensive results
        self._print_results()
        
        return self.processing_stats
    
    def _process_frame(self, frame: np.ndarray, frame_idx: int, timestamp: float) -> FrameDebugInfo:
        """Process a single frame through the complete pipeline."""
        
        # 1. ML Detection
        detection = self.ml_tracker.track_ball_ml(frame)
        detections = [detection] if detection else []
        
        # 2. Kalman Tracking
        tracking_detections = [(x, y, conf) for x, y, conf in detections]
        tracking_states = self.kalman_tracker.update(tracking_detections, timestamp)
        
        # 3. Physics Validation
        physics_validation = None
        if tracking_states and self.config.enable_enhanced_physics:
            best_track = self.kalman_tracker.get_best_track()
            if best_track and best_track.age >= self.config.min_points_for_fit:
                # Build trajectory from track history (simplified)
                trajectory_points = [(timestamp, best_track.state[0], best_track.state[1])]
                physics_validation = self.ballistics_gate.validate_trajectory(trajectory_points)
        
        # 4. Rally Decision
        rally_context = self._build_rally_context(
            timestamp, detections, tracking_states, physics_validation
        )
        rally_state = self.rally_decider.update(rally_context)
        rally_info = self.rally_decider.get_current_rally_info()
        
        # 5. Segment Building (observe rally activity)
        self.segment_builder.observe(rally_state == RallyState.ACTIVE, timestamp)
        
        # Create debug info for this frame
        return FrameDebugInfo(
            frame_idx=frame_idx,
            timestamp=timestamp,
            detections=detections,
            tracking_states=tracking_states,
            rally_state=rally_state,
            rally_confidence=rally_context.detection_confidence,  # Simplified
            physics_validation=physics_validation,
            rally_info=rally_info
        )
    
    def _build_rally_context(self, timestamp: float, detections: List[Tuple[float, float, float]], 
                           tracking_states: List[TrackingState], 
                           physics_validation: Optional[PhysicsValidation]) -> RallyContext:
        """Build rally context from current frame information."""
        
        # Detection confidence (max of current detections)
        detection_conf = max([conf for _, _, conf in detections], default=0.0)
        
        # Tracking confidence (best track)
        tracking_conf = 0.0
        velocity_magnitude = 0.0
        if tracking_states:
            best_track = max(tracking_states, key=lambda t: t.confidence)
            tracking_conf = best_track.confidence
            velocity_magnitude = np.sqrt(best_track.state[2]**2 + best_track.state[3]**2)
        
        # Time since last detection (simplified)
        time_since_last = 0.0 if detections else 0.5
        
        # Consecutive detections (simplified)
        consecutive_detections = len(detections)
        
        return RallyContext(
            current_time=timestamp,
            detection_confidence=detection_conf,
            tracking_confidence=tracking_conf,
            physics_validation=physics_validation,
            velocity_magnitude=velocity_magnitude,
            time_since_last_detection=time_since_last,
            consecutive_detections=consecutive_detections
        )
    
    def _reset_pipeline(self):
        """Reset all pipeline components for new processing."""
        self.kalman_tracker.reset()
        self.rally_decider.reset()
        self.segment_builder.reset()
        self.frame_debug_info.clear()
        
        if hasattr(self.ballistics_gate, 'reset'):
            self.ballistics_gate.reset()
    
    def _calculate_stats(self, total_frames: int, processed_frames: int, detection_count: int,
                        rally_stats: Dict, segments: List[TimeRange], processing_time: float) -> ProcessingStats:
        """Calculate comprehensive processing statistics."""
        
        # Calculate averages from debug info
        if self.frame_debug_info:
            all_confidences = []
            tracking_confidences = []
            physics_valid_count = 0
            physics_total_count = 0
            
            for debug_info in self.frame_debug_info:
                # Detection confidences
                for _, _, conf in debug_info.detections:
                    all_confidences.append(conf)
                
                # Tracking confidences
                for track in debug_info.tracking_states:
                    tracking_confidences.append(track.confidence)
                
                # Physics validation
                if debug_info.physics_validation:
                    physics_total_count += 1
                    if debug_info.physics_validation.is_valid:
                        physics_valid_count += 1
            
            avg_detection_conf = np.mean(all_confidences) if all_confidences else 0.0
            avg_tracking_conf = np.mean(tracking_confidences) if tracking_confidences else 0.0
            physics_valid_pct = (physics_valid_count / physics_total_count * 100) if physics_total_count > 0 else 0.0
        else:
            avg_detection_conf = avg_tracking_conf = physics_valid_pct = 0.0
        
        return ProcessingStats(
            total_frames=total_frames,
            processed_frames=processed_frames,
            total_detections=detection_count,
            total_tracks=len(self.kalman_tracker.tracks) if hasattr(self.kalman_tracker, 'tracks') else 0,
            total_rallies=rally_stats.get('total_rallies', 0),
            total_segments=len(segments),
            processing_time=processing_time,
            avg_detection_confidence=avg_detection_conf,
            avg_tracking_confidence=avg_tracking_conf,
            avg_rally_quality=rally_stats.get('avg_rally_quality', 0.0),
            physics_valid_percentage=physics_valid_pct
        )
    
    def _create_debug_video(self, input_path: str, debug_path: str):
        """Create enhanced debug video with all overlays."""
        print(f"🐛 Creating enhanced debug video: {debug_path}")
        
        annotator = DebugAnnotator(input_path, debug_path, self.config.debug_frame_stride)
        success = annotator.create_enhanced_debug_video(self.frame_debug_info)
        
        if success:
            print(f"✅ Debug video created: {debug_path}")
        else:
            print(f"❌ Failed to create debug video")
    
    def _print_results(self):
        """Print comprehensive processing results."""
        stats = self.processing_stats
        if not stats:
            return
        
        print(f"\n🏆 Advanced Processing Results:")
        print(f"   📊 Frames: {stats.processed_frames}/{stats.total_frames} processed")
        print(f"   🎯 Detections: {stats.total_detections} (avg conf: {stats.avg_detection_confidence:.3f})")
        print(f"   🎯 Tracks: {stats.total_tracks} (avg conf: {stats.avg_tracking_confidence:.3f})")
        print(f"   ⚡ Physics: {stats.physics_valid_percentage:.1f}% valid")
        print(f"   🏐 Rallies: {stats.total_rallies} (avg quality: {stats.avg_rally_quality:.3f})")
        print(f"   📹 Segments: {stats.total_segments}")
        print(f"   ⏱️  Time: {stats.processing_time:.1f}s")
        
        # Additional detailed stats
        rally_stats = self.rally_decider.get_rally_statistics()
        if rally_stats['total_rallies'] > 0:
            print(f"   📈 Rally Details:")
            print(f"      Total rally time: {rally_stats['total_rally_time']:.1f}s")
            print(f"      Avg rally duration: {rally_stats['avg_rally_duration']:.1f}s")
            print(f"      Total contacts: {rally_stats.get('total_contacts', 0)}")
        
        # Segment statistics
        segment_stats = self.segment_builder.get_statistics()
        if segment_stats['total_segments'] > 0:
            print(f"   🎬 Segment Details:")
            print(f"      Total export time: {segment_stats['total_duration']:.1f}s")
            print(f"      Avg segment: {segment_stats['avg_segment_duration']:.1f}s")
        
        print("🚀 Advanced processing complete with BumpSetCut parity!")


def test_advanced_processor():
    """Test the advanced processor with user's video."""
    
    # Use default config (can be customized for experimentation)
    config = ProcessorConfig()
    
    # User's test video
    video_path = "testvideos/trainingshort2.mov"
    
    print("🧪 Testing Advanced Video Processor")
    print("=" * 60)
    
    try:
        processor = AdvancedVideoProcessor(config)
        stats = processor.process_video(video_path, output_debug_video=True)
        
        print("\n✅ Advanced processing test completed successfully!")
        return True
        
    except Exception as e:
        print(f"❌ Advanced processing test failed: {e}")
        import traceback
        traceback.print_exc()
        return False


if __name__ == "__main__":
    success = test_advanced_processor()
    exit(0 if success else 1)