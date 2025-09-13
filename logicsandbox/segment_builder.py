"""
SegmentBuilder - Python equivalent of BumpSetCut's SegmentBuilder.swift

Builds time segments from rally periods with pre/post-roll padding,
gap merging, and minimum length filtering for video export.
"""

from typing import List, Tuple, Optional
from dataclasses import dataclass
from processor_config import ProcessorConfig
from rally_decider import RallyPeriod


@dataclass
class TimeRange:
    """Represents a time range with start and end times."""
    start: float
    end: float
    
    @property
    def duration(self) -> float:
        """Duration of the time range."""
        return self.end - self.start
    
    def __repr__(self) -> str:
        return f"TimeRange({self.start:.2f}s-{self.end:.2f}s, {self.duration:.2f}s)"


class SegmentBuilder:
    """
    Builds keep-time segments with pre/post-roll, gap merge, and min-length filtering.
    Mirrors BumpSetCut's SegmentBuilder.swift functionality.
    """
    
    def __init__(self, config: ProcessorConfig):
        self.config = config
        self.current_start: Optional[float] = None
        self.ranges: List[TimeRange] = []
        
        # Cap pre-roll for short segments to avoid long lead-in on false starts
        self.short_segment_threshold = 2.5   # seconds; if raw rally < threshold, cap pre-roll
        self.max_preroll_for_short = 0.5     # seconds; max pre-roll applied to short rallies
        
        print(f"📹 SegmentBuilder initialized with padding: start={config.rally_start_padding}s, end={config.rally_end_padding}s")
    
    def reset(self):
        """Reset the segment builder state."""
        self.current_start = None
        self.ranges.clear()
    
    def append_padded(self, start: float, end: float):
        """
        Append a segment that is **already padded** (e.g., from RallyDecider).
        This will not apply additional pre/post roll; padding/merging/filtering happens in finalize().
        """
        self.ranges.append(TimeRange(start=start, end=end))
    
    def append_raw(self, start: float, end: float):
        """
        Append a **raw** segment that needs pre/post roll applied according to config.
        This uses the same internal path as when we close segments from observations.
        """
        self._close_segment(start=start, end=end)
    
    def append_rally_period(self, rally: RallyPeriod):
        """Append a rally period as a raw segment."""
        self.append_raw(rally.start_time, rally.end_time)
    
    def observe(self, is_active: bool, time: float):
        """
        Observe rally activity state at a given time.
        Builds segments by tracking active periods.
        """
        if is_active:
            if self.current_start is None:
                self.current_start = time
        else:
            if self.current_start is not None:
                self._close_segment(start=self.current_start, end=time)
            self.current_start = None
    
    def finalize(self, video_duration: float) -> List[TimeRange]:
        """
        Finalize segment building and return processed time ranges.
        
        Args:
            video_duration: Total duration of the video
            
        Returns:
            List of final time ranges for video export
        """
        # Close any open segment
        if self.current_start is not None:
            self._close_segment(start=self.current_start, end=video_duration)
            self.current_start = None
        
        # Clamp each range to [0, video_duration] and drop invalid/empty
        clamped_ranges = []
        for r in self.ranges:
            start = max(0.0, r.start)
            end = min(video_duration, r.end)
            if end > start:  # Valid range
                clamped_ranges.append(TimeRange(start=start, end=end))
        
        # Sort ranges by start time
        clamped_ranges.sort(key=lambda r: r.start)
        
        # Merge small gaps
        merged_ranges = []
        for r in clamped_ranges:
            if merged_ranges and self._gap_between(merged_ranges[-1], r) <= self.config.max_segment_gap:
                # Merge with previous range
                last = merged_ranges.pop()
                merged_start = last.start
                merged_end = max(last.end, r.end)
                merged_ranges.append(TimeRange(start=merged_start, end=merged_end))
            else:
                merged_ranges.append(r)
        
        # Drop segments that are too short
        final_ranges = [r for r in merged_ranges if r.duration >= self.config.min_segment_duration]
        
        total_export_time = sum(r.duration for r in final_ranges)
        print(f"📹 SegmentBuilder finalized: {len(self.ranges)} → {len(final_ranges)} segments, {total_export_time:.1f}s total")
        
        return final_ranges
    
    def _close_segment(self, start: float, end: float):
        """Close a segment by applying padding and adding to ranges."""
        # Use a smaller pre-roll for short raw rallies to avoid pulling start back too far
        raw_duration = end - start
        if raw_duration < self.short_segment_threshold:
            effective_preroll = min(self.config.rally_start_padding, self.max_preroll_for_short)
        else:
            effective_preroll = self.config.rally_start_padding
        
        # Apply padding
        padded_start = max(0.0, start - effective_preroll)
        padded_end = end + self.config.rally_end_padding
        
        self.ranges.append(TimeRange(start=padded_start, end=padded_end))
    
    def _gap_between(self, range1: TimeRange, range2: TimeRange) -> float:
        """Calculate gap between two time ranges."""
        return max(0.0, range2.start - range1.end)
    
    def get_statistics(self) -> dict:
        """Get statistics about current segments."""
        if not self.ranges:
            return {
                "total_segments": 0,
                "total_duration": 0.0,
                "avg_segment_duration": 0.0,
                "longest_segment": 0.0,
                "shortest_segment": 0.0
            }
        
        durations = [r.duration for r in self.ranges]
        total_duration = sum(durations)
        
        return {
            "total_segments": len(self.ranges),
            "total_duration": total_duration,
            "avg_segment_duration": total_duration / len(self.ranges),
            "longest_segment": max(durations),
            "shortest_segment": min(durations),
            "segments": [{"start": r.start, "end": r.end, "duration": r.duration} for r in self.ranges]
        }
    
    def create_segments_from_rallies(self, rallies: List[RallyPeriod]) -> List[TimeRange]:
        """
        Create segments directly from a list of rally periods.
        
        Args:
            rallies: List of detected rally periods
            
        Returns:
            List of time ranges for video export
        """
        # Reset and add all rallies
        self.reset()
        
        for rally in rallies:
            # Only include rallies that meet quality threshold
            if rally.quality_score >= self.config.segment_quality_threshold:
                self.append_rally_period(rally)
        
        # Use a reasonable video duration estimate
        if rallies:
            video_duration = max(rally.end_time for rally in rallies) + 10.0  # Add buffer
        else:
            video_duration = 60.0  # Default fallback
        
        return self.finalize(video_duration)


def merge_overlapping_segments(segments: List[TimeRange]) -> List[TimeRange]:
    """
    Merge overlapping time segments into consolidated ranges.
    
    Args:
        segments: List of time ranges that may overlap
        
    Returns:
        List of non-overlapping merged segments
    """
    if not segments:
        return []
    
    # Sort by start time
    sorted_segments = sorted(segments, key=lambda s: s.start)
    merged = [sorted_segments[0]]
    
    for current in sorted_segments[1:]:
        last = merged[-1]
        
        # Check if segments overlap or are adjacent
        if current.start <= last.end:
            # Merge segments
            merged_start = last.start
            merged_end = max(last.end, current.end)
            merged[-1] = TimeRange(start=merged_start, end=merged_end)
        else:
            # Add non-overlapping segment
            merged.append(current)
    
    return merged


def calculate_export_statistics(segments: List[TimeRange], total_video_duration: float) -> dict:
    """
    Calculate statistics about video export segments.
    
    Args:
        segments: List of time ranges to export
        total_video_duration: Total duration of original video
        
    Returns:
        Dictionary with export statistics
    """
    if not segments:
        return {
            "segments_count": 0,
            "export_duration": 0.0,
            "coverage_percentage": 0.0,
            "compression_ratio": 0.0,
            "longest_segment": 0.0,
            "shortest_segment": 0.0,
            "avg_segment_duration": 0.0
        }
    
    export_duration = sum(s.duration for s in segments)
    durations = [s.duration for s in segments]
    
    return {
        "segments_count": len(segments),
        "export_duration": export_duration,
        "coverage_percentage": (export_duration / total_video_duration) * 100 if total_video_duration > 0 else 0,
        "compression_ratio": total_video_duration / export_duration if export_duration > 0 else 0,
        "longest_segment": max(durations),
        "shortest_segment": min(durations),
        "avg_segment_duration": export_duration / len(segments)
    }


if __name__ == "__main__":
    # Test the segment builder
    from processor_config import ProcessorConfig
    
    config = ProcessorConfig()
    builder = SegmentBuilder(config)
    
    print("🧪 Testing SegmentBuilder:")
    
    # Test scenario: simulate rally activity observations
    test_observations = [
        # (time, is_active)
        (0.0, False),   # Idle
        (2.0, True),    # Rally starts
        (5.0, True),    # Rally continues  
        (8.0, False),   # Rally ends
        (10.0, False),  # Gap
        (15.0, True),   # New rally
        (18.0, True),   # Continues
        (20.5, False),  # Short rally ends
        (25.0, True),   # Another rally
        (30.0, False),  # End
    ]
    
    # Process observations
    for time, is_active in test_observations:
        builder.observe(is_active, time)
        print(f"  Time {time:4.1f}s: {'Active' if is_active else 'Idle'}")
    
    # Finalize with video duration
    video_duration = 35.0
    segments = builder.finalize(video_duration)
    
    print(f"\n📹 Final segments:")
    for i, segment in enumerate(segments):
        print(f"  Segment {i+1}: {segment.start:.2f}s - {segment.end:.2f}s ({segment.duration:.2f}s)")
    
    # Statistics
    stats = calculate_export_statistics(segments, video_duration)
    print(f"\n📊 Export Statistics:")
    print(f"   Segments: {stats['segments_count']}")
    print(f"   Export duration: {stats['export_duration']:.1f}s")
    print(f"   Coverage: {stats['coverage_percentage']:.1f}%")
    print(f"   Compression: {stats['compression_ratio']:.1f}x")
    print(f"   Avg segment: {stats['avg_segment_duration']:.1f}s")
    
    # Test rally-based segment creation
    print(f"\n🏐 Testing rally-based segmentation:")
    
    # Create mock rallies
    mock_rallies = [
        RallyPeriod(start_time=3.0, end_time=7.0, duration=4.0, max_confidence=0.9, 
                   avg_confidence=0.8, estimated_contacts=5, quality_score=0.85),
        RallyPeriod(start_time=15.0, end_time=19.0, duration=4.0, max_confidence=0.7, 
                   avg_confidence=0.6, estimated_contacts=3, quality_score=0.65),
        RallyPeriod(start_time=25.0, end_time=29.0, duration=4.0, max_confidence=0.95, 
                   avg_confidence=0.9, estimated_contacts=8, quality_score=0.9)
    ]
    
    rally_segments = builder.create_segments_from_rallies(mock_rallies)
    
    print(f"Rally-based segments:")
    for i, segment in enumerate(rally_segments):
        print(f"  Rally segment {i+1}: {segment.start:.2f}s - {segment.end:.2f}s ({segment.duration:.2f}s)")
    
    print("✅ SegmentBuilder test completed!")