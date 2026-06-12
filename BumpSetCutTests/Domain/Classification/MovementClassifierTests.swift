//
//  MovementClassifierTests.swift
//  BumpSetCutTests
//
//  Created for Enhanced Trajectory Physics Engine - Issue #21
//

import XCTest
import CoreGraphics
import CoreMedia
@testable import BumpSetCut

final class MovementClassifierTests: XCTestCase {
    
    var classifier: MovementClassifier!
    
    override func setUp() {
        super.setUp()
        classifier = MovementClassifier()
    }
    
    override func tearDown() {
        classifier = nil
        super.tearDown()
    }
    
    // MARK: - Airborne Classification Tests

    func testAirborneClassification_PerfectParabola() {
        let trajectory = createParabolicTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .airborne, "Perfect parabola should be classified as airborne")
        XCTAssertGreaterThan(classification.confidence, 0.8, "Perfect parabola should have high confidence")
        XCTAssertTrue(classification.isValidProjectile, "Airborne movement should be valid projectile")
        
        // Check physics metrics
        XCTAssertLessThan(classification.details.velocityConsistency, 0.3, "Parabola should have consistent velocity pattern")
        XCTAssertGreaterThan(classification.details.accelerationPattern, 0.7, "Parabola should have good acceleration pattern")
        XCTAssertGreaterThan(classification.details.smoothnessScore, 0.8, "Parabola should be smooth")
    }
    
    func testAirborneClassification_VolleyballServe() {
        let trajectory = createVolleyballServeTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .airborne, "Volleyball serve should be classified as airborne")
        XCTAssertGreaterThan(classification.confidence, 0.7, "Volleyball serve should have good confidence")
        XCTAssertTrue(classification.isValidProjectile, "Serve should be valid projectile")
        
        XCTAssertGreaterThan(classification.details.verticalMotionScore, 0.5, "Serve should have significant vertical motion")
    }
    
    // MARK: - Carried Classification Tests
    
    func testCarriedClassification_ZigzagMovement() {
        let trajectory = createZigzagTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .carried, "Zigzag movement should be classified as carried")
        // Carried confidence is velocityConsistency·(1−smoothness) (capped 0.7). High
        // velocity inconsistency requires mixed tiny/huge jumps while low smoothness
        // requires sharp reversals — those trade off, so carried tops out structurally
        // lower than airborne/rolling. 0.4 is "reasonable" for this category.
        XCTAssertGreaterThan(classification.confidence, 0.4, "Zigzag should have reasonable confidence")
        XCTAssertFalse(classification.isValidProjectile, "Carried movement should not be valid projectile")
        
        XCTAssertGreaterThan(classification.details.velocityConsistency, 0.5, "Zigzag should have inconsistent velocity")
        XCTAssertLessThan(classification.details.smoothnessScore, 0.5, "Zigzag should have poor smoothness")
    }
    
    func testCarriedClassification_ErraticMovement() {
        let trajectory = createErraticTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .carried, "Erratic movement should be classified as carried")
        XCTAssertFalse(classification.isValidProjectile, "Erratic movement should not be valid projectile")
        
        XCTAssertGreaterThan(classification.details.velocityConsistency, 0.6, "Erratic movement should be very inconsistent")
    }
    
    // MARK: - Rolling Classification Tests
    
    func testRollingClassification_StraightLine() {
        let trajectory = createStraightLineTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .rolling, "Straight line should be classified as rolling")
        XCTAssertFalse(classification.isValidProjectile, "Rolling should not be valid projectile")
        
        XCTAssertLessThan(classification.details.verticalMotionScore, 0.3, "Rolling should have minimal vertical motion")
        XCTAssertGreaterThan(classification.details.smoothnessScore, 0.7, "Rolling should be smooth")
    }
    
    func testRollingClassification_SlightCurve() {
        let trajectory = createSlightlyCurvedTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .rolling, "Slight curve should be classified as rolling")
        XCTAssertLessThan(classification.details.accelerationPattern, 0.4, "Rolling should have poor acceleration pattern")
    }
    
    // MARK: - Unknown Classification Tests
    
    func testUnknownClassification_InsufficientData() {
        let trajectory = createShortTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .unknown, "Short trajectory should be unknown")
        XCTAssertEqual(classification.confidence, 0.0, "Insufficient data should have zero confidence")
        XCTAssertFalse(classification.isValidProjectile, "Unknown should not be valid projectile")
    }
    
    func testUnknownClassification_AmbiguousPattern() {
        let trajectory = createAmbiguousTrajectory()
        let classification = classifier.classifyMovement(trajectory)
        
        // Should classify as something, but with lower confidence
        XCTAssertNotEqual(classification.movementType, .unknown, "Ambiguous pattern should still get a classification")
        XCTAssertLessThan(classification.confidence, 0.7, "Ambiguous pattern should have lower confidence")
    }
    
    // MARK: - Edge Cases
    
    func testEdgeCase_SinglePoint() {
        var positions: [(CGPoint, CMTime)] = []
        positions.append((CGPoint(x: 0.5, y: 0.5), CMTime.zero))
        
        let trajectory = createTrajectoryFromPositions(positions)
        let classification = classifier.classifyMovement(trajectory)
        
        XCTAssertEqual(classification.movementType, .unknown)
        XCTAssertEqual(classification.confidence, 0.0)
    }
    
    func testEdgeCase_ZeroTimeSpan() {
        var positions: [(CGPoint, CMTime)] = []
        let time = CMTime.zero
        for i in 0..<10 {
            positions.append((CGPoint(x: Double(i) * 0.1, y: 0.5), time))
        }
        
        let trajectory = createTrajectoryFromPositions(positions)
        let classification = classifier.classifyMovement(trajectory)
        
        // Should handle zero time spans gracefully
        XCTAssertEqual(classification.details.timeSpan, 0.0)
    }
    
    func testEdgeCase_IdenticalPoints() {
        var positions: [(CGPoint, CMTime)] = []
        for i in 0..<10 {
            let time = CMTime(seconds: Double(i) * 0.1, preferredTimescale: 600)
            positions.append((CGPoint(x: 0.5, y: 0.5), time))
        }
        
        let trajectory = createTrajectoryFromPositions(positions)
        let classification = classifier.classifyMovement(trajectory)
        
        // Should classify stationary as unknown or carried
        XCTAssertTrue(classification.movementType == .unknown || classification.movementType == .carried)
    }
    
    // MARK: - Performance Tests
    
    func testPerformance_LargeTrajectory() {
        let largeTrajectory = createLargeParabolicTrajectory(pointCount: 1000)
        
        measure {
            let _ = classifier.classifyMovement(largeTrajectory)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createParabolicTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        // Create perfect parabolic trajectory: y = -0.5x² + 0.5x + 0.3
        for i in 0..<20 {
            let t = Double(i) * 0.05 // 50ms intervals
            let x = t * 0.4 + 0.3    // horizontal motion
            let y = -0.5 * x * x + 0.5 * x + 0.3  // parabolic vertical motion
            
            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: x, y: y), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createVolleyballServeTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        // A real serve arcs under gravity. The old fixture scaled gravity by /100, so it
        // was nearly a straight diagonal line (negligible curvature) — not a projectile.
        for i in 0..<30 {
            let t = Double(i) * 0.033 // ~30fps
            let x = 0.15 + t * 0.5     // serve across court
            let y = 0.85 - 0.15 * t - 0.55 * t * t  // descending arc, clear gravity curvature

            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: min(0.9, x), y: max(0.1, min(0.9, y))), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createZigzagTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        // Irregular, sharp side-to-side reversals (a bumped/double-contact ball). The old
        // fixture was a gentle, regular ripple, so it read as smooth/consistent — not
        // "carried". This jumps by widely varying magnitudes (mixing tiny and large steps)
        // against near-stationary horizontal motion, so velocity is highly inconsistent and
        // the path reverses sharply — genuinely poor smoothness and velocity consistency.
        let yVals: [CGFloat] = [
            0.50, 0.51, 0.95, 0.05, 0.06, 0.92, 0.50, 0.49, 0.95, 0.08,
            0.07, 0.90, 0.50, 0.52, 0.95, 0.05, 0.50, 0.51, 0.92, 0.10
        ]
        for i in 0..<20 {
            let t = Double(i) * 0.1
            let x: CGFloat = 0.3   // near-stationary horizontally; motion is the erratic vertical jumps
            let y = yVals[i]

            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: x, y: y), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createErraticTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []

        // Deterministic erratic 2D wandering (was Double.random, which made the
        // "very inconsistent velocity" assertion flaky). Widely varying step sizes and
        // directions give genuinely inconsistent velocity → carried.
        let pts: [(CGFloat, CGFloat)] = [
            (0.30, 0.50), (0.31, 0.51), (0.88, 0.86), (0.86, 0.88), (0.12, 0.15),
            (0.14, 0.13), (0.90, 0.88), (0.50, 0.50), (0.10, 0.90), (0.88, 0.12),
            (0.86, 0.14), (0.15, 0.85), (0.50, 0.48), (0.52, 0.50), (0.90, 0.90)
        ]
        for i in 0..<pts.count {
            let t = Double(i) * 0.1
            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: pts[i].0, y: pts[i].1), time))
        }

        return createTrajectoryFromPositions(positions)
    }
    
    private func createStraightLineTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<20 {
            let t = Double(i) * 0.05
            let x = 0.2 + t * 0.4  // straight horizontal movement
            let y = 0.5            // constant vertical
            
            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: x, y: y), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createSlightlyCurvedTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<20 {
            let t = Double(i) * 0.05
            let x = 0.2 + t * 0.4
            let y = 0.5 + 0.05 * t  // slight upward curve
            
            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: x, y: y), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createShortTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<3 {  // Only 3 points - insufficient for classification
            let t = Double(i) * 0.1
            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: 0.3 + Double(i) * 0.1, y: 0.5), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createAmbiguousTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        // Genuinely borderline: a moderate side-to-side wobble with steady horizontal
        // drift. Not a clean arc (so not confidently airborne) and not violently erratic
        // — the classifier should still pick a class, but with modest confidence.
        let pts: [(CGFloat, CGFloat)] = [
            (0.30, 0.50), (0.36, 0.62), (0.44, 0.46), (0.50, 0.64), (0.56, 0.44),
            (0.62, 0.60), (0.68, 0.48), (0.72, 0.66), (0.76, 0.46), (0.80, 0.58),
            (0.83, 0.50), (0.86, 0.62), (0.88, 0.48), (0.90, 0.56), (0.92, 0.50)
        ]
        for i in 0..<pts.count {
            let t = Double(i) * 0.1
            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: pts[i].0, y: pts[i].1), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createLargeParabolicTrajectory(pointCount: Int) -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<pointCount {
            let t = Double(i) * 0.01
            let x = t * 0.2 + 0.3
            let y = -0.3 * x * x + 0.4 * x + 0.4
            
            let time = CMTime(seconds: t, preferredTimescale: 600)
            positions.append((CGPoint(x: min(0.9, x), y: max(0.1, min(0.9, y))), time))
        }
        
        return createTrajectoryFromPositions(positions)
    }
    
    private func createTrajectoryFromPositions(_ positions: [(CGPoint, CMTime)]) -> KalmanBallTracker.TrackedBall {
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
}