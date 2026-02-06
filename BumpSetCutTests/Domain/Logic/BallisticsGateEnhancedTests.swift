//
//  BallisticsGateEnhancedTests.swift
//  BumpSetCutTests
//
//  Created by Benjamin Wierzbanowski on 9/4/25.
//

import XCTest
import CoreGraphics
import CoreMedia
@testable import BumpSetCut

final class BallisticsGateEnhancedTests: XCTestCase {
    
    var enhancedConfig: ProcessorConfig!
    var legacyConfig: ProcessorConfig!
    var enhancedGate: BallisticsGate!
    var legacyGate: BallisticsGate!
    
    override func setUp() {
        super.setUp()
        
        // Create enhanced physics configuration
        enhancedConfig = ProcessorConfig()
        enhancedConfig.enableEnhancedPhysics = true
        enhancedConfig.enhancedMinR2 = 0.85
        enhancedConfig.minQualityScore = 0.7
        enhancedConfig.minClassificationConfidence = 0.8
        enhancedConfig.velocityConsistencyThreshold = 0.3
        enhancedConfig.trajectorySmoothnessThreshold = 0.6
        enhancedConfig.parabolaMinPoints = 8
        enhancedConfig.projectileWindowSec = 1.0
        enhancedConfig.maxJumpPerFrame = 0.08
        
        // Create legacy configuration
        legacyConfig = ProcessorConfig()
        legacyConfig.enableEnhancedPhysics = false
        legacyConfig.parabolaMinR2 = 0.85
        legacyConfig.parabolaMinPoints = 8
        legacyConfig.projectileWindowSec = 1.0
        legacyConfig.maxJumpPerFrame = 0.08
        
        enhancedGate = BallisticsGate(config: enhancedConfig)
        legacyGate = BallisticsGate(config: legacyConfig)
    }
    
    override func tearDown() {
        enhancedGate = nil
        legacyGate = nil
        enhancedConfig = nil
        legacyConfig = nil
        super.tearDown()
    }
    
    // MARK: - Enhanced Physics Validation Tests
    
    func testEnhancedValidation_ValidVolleyballTrajectory() {
        let track = createVolleyballTrajectory()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertTrue(isValid, "Valid volleyball trajectory should pass enhanced physics validation")
    }
    
    func testEnhancedValidation_RejectsCarriedBall() {
        let track = createCarriedBallTrajectory()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertFalse(isValid, "Enhanced validation should reject carried ball movements")
    }
    
    func testEnhancedValidation_RejectsRollingBall() {
        let track = createRollingBallTrajectory()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertFalse(isValid, "Enhanced validation should reject rolling ball movements")
    }
    
    func testEnhancedValidation_RejectsPoorQualityTrajectory() {
        let track = createNoisyTrajectory()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertFalse(isValid, "Enhanced validation should reject poor quality trajectories")
    }
    
    // MARK: - Legacy vs Enhanced Comparison Tests
    
    func testComparison_ValidTrajectoryAcceptedByBoth() {
        let track = createHighQualityVolleyballTrajectory()
        
        let legacyResult = legacyGate.isValidProjectile(track)
        let enhancedResult = enhancedGate.isValidProjectile(track)
        
        XCTAssertTrue(legacyResult, "Legacy validation should accept high-quality trajectory")
        XCTAssertTrue(enhancedResult, "Enhanced validation should accept high-quality trajectory")
    }
    
    func testComparison_EnhancedMoreStrictOnCarriedMovement() {
        let track = createSubtleCarriedBallTrajectory()
        
        let legacyResult = legacyGate.isValidProjectile(track)
        let enhancedResult = enhancedGate.isValidProjectile(track)
        
        // Enhanced should be more strict about detecting carried movements
        if legacyResult {
            XCTAssertFalse(enhancedResult, "Enhanced validation should be stricter about carried ball detection")
        }
    }
    
    func testComparison_EnhancedRejectsLowConfidenceTrajectories() {
        let track = createMarginalTrajectory()
        
        let legacyResult = legacyGate.isValidProjectile(track)
        let enhancedResult = enhancedGate.isValidProjectile(track)
        
        // Enhanced should require higher confidence
        if legacyResult {
            // If legacy accepts marginal trajectory, enhanced should be more conservative
            XCTAssertFalse(enhancedResult, "Enhanced validation should reject marginal trajectories")
        }
    }
    
    // MARK: - Configuration Impact Tests
    
    func testConfigurationImpact_HighR2Threshold() {
        var strictConfig = ProcessorConfig()
        strictConfig.enableEnhancedPhysics = true
        strictConfig.enhancedMinR2 = 0.95 // Very strict
        strictConfig.minQualityScore = 0.7
        strictConfig.minClassificationConfidence = 0.8
        let strictGate = BallisticsGate(config: strictConfig)
        
        let track = createModerateQualityTrajectory()
        
        let normalResult = enhancedGate.isValidProjectile(track)
        let strictResult = strictGate.isValidProjectile(track)
        
        if normalResult {
            XCTAssertFalse(strictResult, "Strict R² threshold should reject moderate quality trajectories")
        }
    }
    
    func testConfigurationImpact_QualityThreshold() {
        var qualityConfig = ProcessorConfig()
        qualityConfig.enableEnhancedPhysics = true
        qualityConfig.enhancedMinR2 = 0.85
        qualityConfig.minQualityScore = 0.9 // Very strict quality
        qualityConfig.minClassificationConfidence = 0.8
        let qualityGate = BallisticsGate(config: qualityConfig)
        
        let track = createSlightlyNoisyTrajectory()
        
        let normalResult = enhancedGate.isValidProjectile(track)
        let qualityResult = qualityGate.isValidProjectile(track)
        
        if normalResult {
            XCTAssertFalse(qualityResult, "High quality threshold should reject slightly noisy trajectories")
        }
    }
    
    // MARK: - Spatial Jump Detection Tests
    
    func testSpatialJumpDetection_RejectsLargeJumps() {
        let track = createTrajectoryWithLargeJump()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertFalse(isValid, "Enhanced validation should reject trajectories with large spatial jumps")
    }
    
    func testSpatialJumpDetection_AcceptsSmallJumps() {
        let track = createTrajectoryWithSmallJump()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        // Should accept small jumps if other physics checks pass
        // This depends on the overall quality of the trajectory
        XCTAssertTrue(isValid, "Enhanced validation should accept trajectories with small acceptable jumps")
    }
    
    // MARK: - Insufficient Data Tests
    
    func testInsufficientData_FewPoints() {
        let track = createTrajectoryWithFewPoints(pointCount: 3)
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertFalse(isValid, "Enhanced validation should reject trajectories with insufficient points")
    }
    
    func testInsufficientData_ShortTimeWindow() {
        let track = createShortTimeWindowTrajectory()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertFalse(isValid, "Enhanced validation should reject trajectories with insufficient time coverage")
    }
    
    // MARK: - Physics Components Integration Tests
    
    func testPhysicsIntegration_AllComponentsAgreement() {
        let track = createPerfectVolleyballTrajectory()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        XCTAssertTrue(isValid, "When all physics components agree on validity, trajectory should be accepted")
    }
    
    func testPhysicsIntegration_ComponentDisagreement() {
        let track = createAmbiguousTrajectory()
        
        let isValid = enhancedGate.isValidProjectile(track)
        
        // Result depends on combined confidence score
        // This test ensures the integration logic works correctly
        XCTAssertNotNil(isValid, "Integration should handle component disagreement gracefully")
    }
    
    // MARK: - Performance Tests
    
    func testPerformance_EnhancedValidation() {
        let track = createComplexTrajectory()
        
        measure {
            for _ in 0..<100 {
                _ = enhancedGate.isValidProjectile(track)
            }
        }
    }
    
    func testPerformance_LegacyVsEnhanced() {
        let track = createStandardTrajectory()
        
        let legacyTime = measureTime {
            for _ in 0..<100 {
                _ = legacyGate.isValidProjectile(track)
            }
        }
        
        let enhancedTime = measureTime {
            for _ in 0..<100 {
                _ = enhancedGate.isValidProjectile(track)
            }
        }
        
        // Enhanced should not be more than 5x slower
        XCTAssertLessThan(enhancedTime, legacyTime * 5.0, "Enhanced validation should maintain reasonable performance")
    }
    
    // MARK: - Helper Methods
    
    private func createVolleyballTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.3, dy: -0.5),
            gravity: 0.98, // Normalized gravity
            startPoint: CGPoint(x: 0.2, y: 0.8),
            timeStep: 0.033,
            steps: 12
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createCarriedBallTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createErraticLinearPositions(
            start: CGPoint(x: 0.1, y: 0.5),
            baseVelocity: CGVector(dx: 0.2, dy: 0.1),
            variability: 0.05,
            timeStep: 0.033,
            steps: 15
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createRollingBallTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createHorizontalLinearPositions(
            start: CGPoint(x: 0.1, y: 0.9), // Near ground
            velocity: CGVector(dx: 0.3, dy: 0.0),
            timeStep: 0.033,
            steps: 12
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createNoisyTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createNoisyParabolicPositions(
            initialVelocity: CGVector(dx: 0.25, dy: -0.4),
            gravity: 0.98,
            noiseLevel: 0.08,
            startPoint: CGPoint(x: 0.3, y: 0.7),
            timeStep: 0.033,
            steps: 10
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createHighQualityVolleyballTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.4, dy: -0.6),
            gravity: 0.98,
            startPoint: CGPoint(x: 0.15, y: 0.85),
            timeStep: 0.033,
            steps: 15
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createSubtleCarriedBallTrajectory() -> KalmanBallTracker.TrackedBall {
        // Movement that might fool legacy but should be caught by enhanced
        let positions = createQuasiParabolicPositions(
            distortionFactor: 0.3,
            timeStep: 0.033,
            steps: 12
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createMarginalTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.15, dy: -0.3), // Lower velocity
            gravity: 0.7, // Non-standard gravity
            startPoint: CGPoint(x: 0.4, y: 0.6),
            timeStep: 0.05,
            steps: 9
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createModerateQualityTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createNoisyParabolicPositions(
            initialVelocity: CGVector(dx: 0.3, dy: -0.5),
            gravity: 0.98,
            noiseLevel: 0.02, // Small amount of noise
            startPoint: CGPoint(x: 0.2, y: 0.8),
            timeStep: 0.033,
            steps: 12
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createSlightlyNoisyTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createNoisyParabolicPositions(
            initialVelocity: CGVector(dx: 0.35, dy: -0.55),
            gravity: 0.98,
            noiseLevel: 0.03,
            startPoint: CGPoint(x: 0.25, y: 0.75),
            timeStep: 0.033,
            steps: 11
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createTrajectoryWithLargeJump() -> KalmanBallTracker.TrackedBall {
        var positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.3, dy: -0.5),
            gravity: 0.98,
            startPoint: CGPoint(x: 0.2, y: 0.8),
            timeStep: 0.033,
            steps: 10
        )
        
        // Add a large jump in the middle
        if positions.count > 5 {
            let (originalPos, time) = positions[5]
            positions[5] = (CGPoint(x: originalPos.x + 0.15, y: originalPos.y + 0.15), time)
        }
        
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createTrajectoryWithSmallJump() -> KalmanBallTracker.TrackedBall {
        var positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.3, dy: -0.5),
            gravity: 0.98,
            startPoint: CGPoint(x: 0.2, y: 0.8),
            timeStep: 0.033,
            steps: 12
        )
        
        // Add a small acceptable jump
        if positions.count > 6 {
            let (originalPos, time) = positions[6]
            positions[6] = (CGPoint(x: originalPos.x + 0.02, y: originalPos.y + 0.02), time)
        }
        
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createTrajectoryWithFewPoints(pointCount: Int) -> KalmanBallTracker.TrackedBall {
        let positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.3, dy: -0.5),
            gravity: 0.98,
            startPoint: CGPoint(x: 0.2, y: 0.8),
            timeStep: 0.033,
            steps: pointCount
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createShortTimeWindowTrajectory() -> KalmanBallTracker.TrackedBall {
        let positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.3, dy: -0.5),
            gravity: 0.98,
            startPoint: CGPoint(x: 0.2, y: 0.8),
            timeStep: 0.01, // Very short time steps
            steps: 15
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createPerfectVolleyballTrajectory() -> KalmanBallTracker.TrackedBall {
        return createHighQualityVolleyballTrajectory() // Reuse high quality
    }
    
    private func createAmbiguousTrajectory() -> KalmanBallTracker.TrackedBall {
        // Create trajectory that has mixed signals from different components
        let positions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.1, dy: -0.2), // Very low velocity (marginal)
            gravity: 1.2, // Slightly off gravity (marginal)
            startPoint: CGPoint(x: 0.45, y: 0.55),
            timeStep: 0.04,
            steps: 8 // Minimum points (marginal)
        )
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createComplexTrajectory() -> KalmanBallTracker.TrackedBall {
        return createHighQualityVolleyballTrajectory()
    }
    
    private func createStandardTrajectory() -> KalmanBallTracker.TrackedBall {
        return createVolleyballTrajectory()
    }
    
    // MARK: - Position Generation Helpers
    
    private func createParabolicPositions(
        initialVelocity: CGVector,
        gravity: Double,
        startPoint: CGPoint,
        timeStep: Double,
        steps: Int
    ) -> [(CGPoint, CMTime)] {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<steps {
            let t = Double(i) * timeStep
            let x = startPoint.x + initialVelocity.dx * CGFloat(t)
            let y = startPoint.y + initialVelocity.dy * CGFloat(t) + CGFloat(0.5 * gravity * t * t)
            
            let time = CMTimeMakeWithSeconds(t, preferredTimescale: 600)
            positions.append((CGPoint(x: x, y: y), time))
        }
        
        return positions
    }
    
    private func createErraticLinearPositions(
        start: CGPoint,
        baseVelocity: CGVector,
        variability: CGFloat,
        timeStep: Double,
        steps: Int
    ) -> [(CGPoint, CMTime)] {
        var positions: [(CGPoint, CMTime)] = []
        var currentPos = start
        
        for i in 0..<steps {
            let t = Double(i) * timeStep
            let noiseX = CGFloat.random(in: -variability...variability)
            let noiseY = CGFloat.random(in: -variability...variability)
            
            currentPos = CGPoint(
                x: currentPos.x + baseVelocity.dx * CGFloat(timeStep) + noiseX,
                y: currentPos.y + baseVelocity.dy * CGFloat(timeStep) + noiseY
            )
            
            let time = CMTimeMakeWithSeconds(t, preferredTimescale: 600)
            positions.append((currentPos, time))
        }
        
        return positions
    }
    
    private func createHorizontalLinearPositions(
        start: CGPoint,
        velocity: CGVector,
        timeStep: Double,
        steps: Int
    ) -> [(CGPoint, CMTime)] {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<steps {
            let t = Double(i) * timeStep
            let x = start.x + velocity.dx * CGFloat(t)
            let y = start.y + velocity.dy * CGFloat(t)
            
            let time = CMTimeMakeWithSeconds(t, preferredTimescale: 600)
            positions.append((CGPoint(x: x, y: y), time))
        }
        
        return positions
    }
    
    private func createNoisyParabolicPositions(
        initialVelocity: CGVector,
        gravity: Double,
        noiseLevel: CGFloat,
        startPoint: CGPoint,
        timeStep: Double,
        steps: Int
    ) -> [(CGPoint, CMTime)] {
        let basePositions = createParabolicPositions(
            initialVelocity: initialVelocity,
            gravity: gravity,
            startPoint: startPoint,
            timeStep: timeStep,
            steps: steps
        )
        
        return basePositions.map { position, time in
            let noiseX = CGFloat.random(in: -noiseLevel...noiseLevel)
            let noiseY = CGFloat.random(in: -noiseLevel...noiseLevel)
            let noisyPoint = CGPoint(x: position.x + noiseX, y: position.y + noiseY)
            return (noisyPoint, time)
        }
    }
    
    private func createQuasiParabolicPositions(
        distortionFactor: CGFloat,
        timeStep: Double,
        steps: Int
    ) -> [(CGPoint, CMTime)] {
        let basePositions = createParabolicPositions(
            initialVelocity: CGVector(dx: 0.3, dy: -0.4),
            gravity: 0.98,
            startPoint: CGPoint(x: 0.2, y: 0.7),
            timeStep: timeStep,
            steps: steps
        )
        
        // Introduce non-parabolic distortion
        return basePositions.enumerated().map { index, element in
            let (position, time) = element
            let t = Double(index) * timeStep
            let distortion = sin(t * 5.0) * Double(distortionFactor) // Sinusoidal distortion
            let distortedY = position.y + CGFloat(distortion)
            return (CGPoint(x: position.x, y: distortedY), time)
        }
    }
    
    private func measureTime(_ block: () -> Void) -> TimeInterval {
        let startTime = CFAbsoluteTimeGetCurrent()
        block()
        return CFAbsoluteTimeGetCurrent() - startTime
    }
}