"""
Ballistics Gate - Python equivalent of BumpSetCut's BallisticsGate.swift

Physics-based trajectory validation using quadratic fitting and ballistics constraints.
Validates that ball trajectories follow realistic physics patterns.
"""

import numpy as np
import math
from typing import List, Tuple, Optional, Dict
from dataclasses import dataclass
from processor_config import ProcessorConfig


@dataclass
class TrajectoryPoint:
    """A point in a ball trajectory."""
    x: float
    y: float
    time: float
    confidence: float
    

@dataclass
class QuadraticFit:
    """Results of quadratic trajectory fitting."""
    # Coefficients for y = a*x² + b*x + c
    a: float  # Quadratic coefficient (curvature)
    b: float  # Linear coefficient (slope)
    c: float  # Y-intercept
    
    # Fit quality metrics
    r_squared: float      # Coefficient of determination
    residual_error: float # RMS error in pixels
    point_count: int      # Number of points used in fit
    
    # Physics metrics
    vertex_x: float       # X coordinate of trajectory peak
    vertex_y: float       # Y coordinate of trajectory peak
    opens_downward: bool  # True if parabola opens downward (normal ball trajectory)
    

@dataclass
class PhysicsValidation:
    """Results of physics-based trajectory validation."""
    is_valid: bool
    physics_score: float      # Overall physics plausibility [0-1]
    
    # Component scores
    trajectory_score: float   # Quadratic fit quality [0-1]
    velocity_score: float     # Velocity constraint satisfaction [0-1] 
    gravity_score: float      # Gravity/acceleration consistency [0-1]
    smoothness_score: float   # Trajectory smoothness [0-1]
    
    # Detailed metrics
    quadratic_fit: Optional[QuadraticFit]
    max_velocity: float       # Maximum velocity in trajectory
    gravity_consistency: float # How well trajectory matches gravity
    trajectory_length: float  # Physical length of trajectory
    

class BallisticsGate:
    """
    Physics-based trajectory validation system.
    Mirrors BumpSetCut's BallisticsGate.swift functionality.
    """
    
    def __init__(self, config: ProcessorConfig):
        self.config = config
        self.trajectory_history: List[TrajectoryPoint] = []
        self.validation_cache: Dict[str, PhysicsValidation] = {}
        
        print(f"⚖️  Ballistics Gate initialized with physics validation: {'✅ Enabled' if config.enable_enhanced_physics else '❌ Disabled'}")
    
    def validate_trajectory(self, points: List[TrajectoryPoint], 
                          pixels_per_meter: float = 100.0) -> PhysicsValidation:
        """
        Validate a trajectory using physics constraints.
        
        Args:
            points: List of trajectory points
            pixels_per_meter: Conversion factor for pixel to real-world coordinates
            
        Returns:
            Physics validation results
        """
        if not self.config.enable_enhanced_physics:
            return PhysicsValidation(
                is_valid=True, physics_score=1.0,
                trajectory_score=1.0, velocity_score=1.0,
                gravity_score=1.0, smoothness_score=1.0,
                quadratic_fit=None, max_velocity=0.0,
                gravity_consistency=1.0, trajectory_length=0.0
            )
        
        if len(points) < self.config.min_points_for_fit:
            return self._create_invalid_result("Insufficient points for trajectory fitting")
        
        # 1. Fit quadratic trajectory
        quad_fit = self._fit_quadratic_trajectory(points)
        
        # 2. Validate physics constraints
        velocity_score = self._validate_velocity_constraints(points, pixels_per_meter)
        gravity_score = self._validate_gravity_consistency(points, quad_fit, pixels_per_meter)
        smoothness_score = self._calculate_smoothness_score(points)
        trajectory_score = self._evaluate_trajectory_fit(quad_fit)
        
        # 3. Compute overall physics score
        physics_score = (
            self.config.trajectory_score_weight * trajectory_score +
            self.config.physics_score_weight * (velocity_score + gravity_score) / 2.0 +
            self.config.smoothness_score_weight * smoothness_score
        )
        
        # 4. Determine validity
        is_valid = (
            physics_score >= self.config.min_physics_score and
            quad_fit is not None and
            quad_fit.residual_error <= self.config.max_trajectory_error
        )
        
        return PhysicsValidation(
            is_valid=is_valid,
            physics_score=physics_score,
            trajectory_score=trajectory_score,
            velocity_score=velocity_score,
            gravity_score=gravity_score,
            smoothness_score=smoothness_score,
            quadratic_fit=quad_fit,
            max_velocity=self._calculate_max_velocity(points),
            gravity_consistency=gravity_score,
            trajectory_length=self._calculate_trajectory_length(points, pixels_per_meter)
        )
    
    def _fit_quadratic_trajectory(self, points: List[TrajectoryPoint]) -> Optional[QuadraticFit]:
        """Fit a quadratic curve to trajectory points."""
        if len(points) < 3:
            return None
        
        try:
            # Extract coordinates
            x_coords = np.array([p.x for p in points])
            y_coords = np.array([p.y for p in points])
            
            # Fit quadratic: y = a*x² + b*x + c
            coeffs = np.polyfit(x_coords, y_coords, 2)
            a, b, c = coeffs
            
            # Calculate fit quality
            y_pred = np.polyval(coeffs, x_coords)
            ss_res = np.sum((y_coords - y_pred) ** 2)
            ss_tot = np.sum((y_coords - np.mean(y_coords)) ** 2)
            r_squared = 1 - (ss_res / ss_tot) if ss_tot > 0 else 0
            
            residual_error = np.sqrt(np.mean((y_coords - y_pred) ** 2))
            
            # Calculate vertex (peak of parabola)
            vertex_x = -b / (2 * a) if a != 0 else 0
            vertex_y = a * vertex_x**2 + b * vertex_x + c
            opens_downward = a < 0
            
            return QuadraticFit(
                a=a, b=b, c=c,
                r_squared=r_squared,
                residual_error=residual_error,
                point_count=len(points),
                vertex_x=vertex_x,
                vertex_y=vertex_y,
                opens_downward=opens_downward
            )
            
        except (np.linalg.LinAlgError, ValueError) as e:
            return None
    
    def _validate_velocity_constraints(self, points: List[TrajectoryPoint], 
                                     pixels_per_meter: float) -> float:
        """Validate velocity constraints against physics."""
        if len(points) < 2:
            return 1.0
        
        max_vel_pixels_per_frame = 0.0
        valid_velocities = 0
        total_velocities = 0
        
        for i in range(1, len(points)):
            dt = points[i].time - points[i-1].time
            if dt <= 0:
                continue
            
            dx = points[i].x - points[i-1].x
            dy = points[i].y - points[i-1].y
            
            # Velocity in pixels per second
            vel_x_pps = dx / dt
            vel_y_pps = dy / dt
            
            # Convert to m/s
            vel_x_mps = vel_x_pps / pixels_per_meter
            vel_y_mps = vel_y_pps / pixels_per_meter
            
            vel_magnitude = math.sqrt(vel_x_mps**2 + vel_y_mps**2)
            max_vel_pixels_per_frame = max(max_vel_pixels_per_frame, 
                                         math.sqrt(vel_x_pps**2 + vel_y_pps**2))
            
            # Check against constraints
            total_velocities += 1
            if (abs(vel_x_mps) <= self.config.max_horizontal_velocity and 
                abs(vel_y_mps) <= self.config.max_vertical_velocity):
                valid_velocities += 1
        
        return valid_velocities / total_velocities if total_velocities > 0 else 1.0
    
    def _validate_gravity_consistency(self, points: List[TrajectoryPoint],
                                    quad_fit: Optional[QuadraticFit],
                                    pixels_per_meter: float) -> float:
        """Validate trajectory consistency with gravity."""
        if not quad_fit or len(points) < 3:
            return 0.5  # Neutral score
        
        # For a projectile under gravity: y = y0 + v0y*t - 0.5*g*t²
        # The quadratic coefficient should relate to gravity
        
        # Expected gravity acceleration in pixels/second²
        gravity_pixels_per_sec2 = self.config.gravity_acceleration * pixels_per_meter
        
        # For parabola y = a*x² + b*x + c, if we parameterize by time,
        # we expect 'a' to be related to -0.5*g
        # This is a simplified check - real implementation would be more sophisticated
        
        expected_curvature_sign = -1  # Ball trajectories should curve downward
        actual_curvature_sign = -1 if quad_fit.a < 0 else 1
        
        # Score based on curvature direction and magnitude plausibility
        direction_score = 1.0 if actual_curvature_sign == expected_curvature_sign else 0.0
        
        # Magnitude plausibility (simplified)
        curvature_magnitude = abs(quad_fit.a)
        reasonable_curvature_range = (0.0001, 0.01)  # Empirical range for volleyball
        
        if reasonable_curvature_range[0] <= curvature_magnitude <= reasonable_curvature_range[1]:
            magnitude_score = 1.0
        else:
            # Score decreases as we move away from reasonable range
            if curvature_magnitude < reasonable_curvature_range[0]:
                magnitude_score = curvature_magnitude / reasonable_curvature_range[0]
            else:
                magnitude_score = reasonable_curvature_range[1] / curvature_magnitude
            magnitude_score = max(0.0, min(1.0, magnitude_score))
        
        return (direction_score + magnitude_score) / 2.0
    
    def _calculate_smoothness_score(self, points: List[TrajectoryPoint]) -> float:
        """Calculate trajectory smoothness score."""
        if len(points) < 3:
            return 1.0
        
        # Calculate second derivatives (acceleration changes)
        accelerations = []
        
        for i in range(1, len(points) - 1):
            dt1 = points[i].time - points[i-1].time
            dt2 = points[i+1].time - points[i].time
            
            if dt1 <= 0 or dt2 <= 0:
                continue
            
            # Velocities
            vel1_x = (points[i].x - points[i-1].x) / dt1
            vel1_y = (points[i].y - points[i-1].y) / dt1
            
            vel2_x = (points[i+1].x - points[i].x) / dt2
            vel2_y = (points[i+1].y - points[i].y) / dt2
            
            # Accelerations
            acc_x = (vel2_x - vel1_x) / ((dt1 + dt2) / 2)
            acc_y = (vel2_y - vel1_y) / ((dt1 + dt2) / 2)
            
            acc_magnitude = math.sqrt(acc_x**2 + acc_y**2)
            accelerations.append(acc_magnitude)
        
        if not accelerations:
            return 1.0
        
        # Smoothness is inversely related to acceleration variance
        acc_variance = np.var(accelerations)
        
        # Convert variance to smoothness score (0-1)
        # Lower variance = higher smoothness
        max_reasonable_variance = 10000  # Empirical threshold
        smoothness = max(0.0, 1.0 - (acc_variance / max_reasonable_variance))
        
        return min(1.0, smoothness)
    
    def _evaluate_trajectory_fit(self, quad_fit: Optional[QuadraticFit]) -> float:
        """Evaluate the quality of the quadratic trajectory fit."""
        if not quad_fit:
            return 0.0
        
        # R-squared score (coefficient of determination)
        r_squared_score = max(0.0, quad_fit.r_squared)
        
        # Residual error score (lower error = higher score)
        error_score = max(0.0, 1.0 - (quad_fit.residual_error / self.config.max_trajectory_error))
        
        # Point count score (more points = more reliable)
        min_points = self.config.min_points_for_fit
        ideal_points = min_points * 2
        point_score = min(1.0, (quad_fit.point_count - min_points) / (ideal_points - min_points)) if ideal_points > min_points else 1.0
        
        # Combine scores
        trajectory_score = (r_squared_score * 0.5 + error_score * 0.3 + point_score * 0.2)
        
        return max(0.0, min(1.0, trajectory_score))
    
    def _calculate_max_velocity(self, points: List[TrajectoryPoint]) -> float:
        """Calculate maximum velocity in the trajectory."""
        max_vel = 0.0
        
        for i in range(1, len(points)):
            dt = points[i].time - points[i-1].time
            if dt <= 0:
                continue
            
            dx = points[i].x - points[i-1].x
            dy = points[i].y - points[i-1].y
            
            velocity = math.sqrt(dx**2 + dy**2) / dt
            max_vel = max(max_vel, velocity)
        
        return max_vel
    
    def _calculate_trajectory_length(self, points: List[TrajectoryPoint], 
                                   pixels_per_meter: float) -> float:
        """Calculate total trajectory length in meters."""
        total_length = 0.0
        
        for i in range(1, len(points)):
            dx = points[i].x - points[i-1].x
            dy = points[i].y - points[i-1].y
            segment_length = math.sqrt(dx**2 + dy**2) / pixels_per_meter
            total_length += segment_length
        
        return total_length
    
    def _create_invalid_result(self, reason: str) -> PhysicsValidation:
        """Create a result indicating invalid physics."""
        return PhysicsValidation(
            is_valid=False, physics_score=0.0,
            trajectory_score=0.0, velocity_score=0.0,
            gravity_score=0.0, smoothness_score=0.0,
            quadratic_fit=None, max_velocity=0.0,
            gravity_consistency=0.0, trajectory_length=0.0
        )
    
    def add_trajectory_point(self, x: float, y: float, time: float, confidence: float):
        """Add a point to the trajectory history."""
        point = TrajectoryPoint(x, y, time, confidence)
        self.trajectory_history.append(point)
        
        # Limit history size for memory management
        if len(self.trajectory_history) > self.config.max_trajectory_history:
            self.trajectory_history.pop(0)
    
    def validate_recent_trajectory(self, window_size: int = 10) -> Optional[PhysicsValidation]:
        """Validate the most recent trajectory points."""
        if len(self.trajectory_history) < self.config.min_points_for_fit:
            return None
        
        recent_points = self.trajectory_history[-window_size:]
        return self.validate_trajectory(recent_points)
    
    def clear_trajectory_history(self):
        """Clear trajectory history."""
        self.trajectory_history.clear()
        self.validation_cache.clear()
    
    def get_trajectory_statistics(self) -> Dict:
        """Get statistics about current trajectory state."""
        if not self.trajectory_history:
            return {"points": 0, "time_span": 0.0}
        
        time_span = self.trajectory_history[-1].time - self.trajectory_history[0].time
        avg_confidence = sum(p.confidence for p in self.trajectory_history) / len(self.trajectory_history)
        
        return {
            "points": len(self.trajectory_history),
            "time_span": time_span,
            "avg_confidence": avg_confidence,
            "start_time": self.trajectory_history[0].time,
            "end_time": self.trajectory_history[-1].time
        }


if __name__ == "__main__":
    # Test the ballistics gate
    from processor_config import ProcessorConfig
    
    config = ProcessorConfig()
    ballistics = BallisticsGate(config)
    
    print("🧪 Testing Ballistics Gate:")
    
    # Create a realistic parabolic trajectory (volleyball arc)
    test_points = []
    for i in range(20):
        t = i * 0.1  # 0.1 second intervals
        x = 100 + 50 * t  # Moving horizontally
        y = 200 + 30 * t - 5 * t**2  # Parabolic arc with gravity
        confidence = 0.8 + 0.1 * math.sin(i)  # Varying confidence
        
        test_points.append(TrajectoryPoint(x, y, t, confidence))
    
    # Validate the trajectory
    validation = ballistics.validate_trajectory(test_points, pixels_per_meter=100.0)
    
    print(f"Physics validation results:")
    print(f"  Valid: {'✅ Yes' if validation.is_valid else '❌ No'}")
    print(f"  Overall score: {validation.physics_score:.3f}")
    print(f"  Trajectory score: {validation.trajectory_score:.3f}")
    print(f"  Velocity score: {validation.velocity_score:.3f}")
    print(f"  Gravity score: {validation.gravity_score:.3f}")
    print(f"  Smoothness score: {validation.smoothness_score:.3f}")
    
    if validation.quadratic_fit:
        fit = validation.quadratic_fit
        print(f"  Quadratic fit: y = {fit.a:.6f}x² + {fit.b:.3f}x + {fit.c:.1f}")
        print(f"  R-squared: {fit.r_squared:.3f}")
        print(f"  Residual error: {fit.residual_error:.1f}px")
        print(f"  Opens downward: {'✅ Yes' if fit.opens_downward else '❌ No'}")
    
    print("✅ Ballistics gate test completed!")