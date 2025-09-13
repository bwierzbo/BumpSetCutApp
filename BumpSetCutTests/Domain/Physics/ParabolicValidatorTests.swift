//
//  ParabolicValidatorTests.swift
//  BumpSetCutTests
//
//  Created by Benjamin Wierzbanowski on 9/4/25.
//

import XCTest
import CoreGraphics
import CoreMedia
@testable import BumpSetCut

final class ParabolicValidatorTests: XCTestCase {
    
    var validator: ParabolicValidator!
    
    override func setUp() {
        super.setUp()
        validator = ParabolicValidator(config: .default)
    }
    
    override func tearDown() {
        validator = nil
        super.tearDown()
    }
    
    // MARK: - Trajectory Validation Tests
    
    func testValidTrajectory_PerfectParabola() {
        let positions = createParabolicTrajectory(
            initialVelocity: CGVector(dx: 5.0, dy: -8.0),
            gravity: 9.8,
            timeStep: 0.1,
            steps: 10
        )
        
        let result = validator.validateTrajectory(positions)
        
        XCTAssertTrue(result.isValid, "Perfect parabolic trajectory should be valid")
        XCTAssertGreaterThan(result.r2Correlation, 0.95, "R² should be very high for perfect parabola")
        XCTAssertEqual(result.curvatureDirection, .upward, "Downward gravity should create upward-opening parabola")
        XCTAssertGreaterThan(result.velocityConsistency, 0.3, "Velocity should have reasonable consistency")
        XCTAssertNotNil(result.parabolicCoefficients, "Should have parabolic coefficients")
    }
    
    func testInvalidTrajectory_InsufficientPoints() {
        let positions = [
            (CGPoint(x: 0, y: 0), CMTime.zero),
            (CGPoint(x: 1, y: 1), CMTimeMakeWithSeconds(0.1, preferredTimescale: 600))
        ]
        
        let result = validator.validateTrajectory(positions)
        
        XCTAssertFalse(result.isValid, "Trajectory with insufficient points should be invalid")
        XCTAssertEqual(result.r2Correlation, 0.0, "R² should be 0 for insufficient data")
        XCTAssertEqual(result.curvatureDirection, .invalid, "Curvature should be invalid")
        XCTAssertNil(result.parabolicCoefficients, "Should not have coefficients for insufficient data")
    }
    
    func testInvalidTrajectory_LinearMovement() {
        let positions = createLinearTrajectory(
            start: CGPoint(x: 0, y: 0),
            velocity: CGVector(dx: 2.0, dy: 1.0),
            timeStep: 0.1,
            steps: 15
        )
        
        let result = validator.validateTrajectory(positions)
        
        XCTAssertFalse(result.isValid, "Linear trajectory should be invalid for projectile motion")
        XCTAssertLessThan(result.r2Correlation, 0.7, "Linear movement should have poor parabolic correlation")
        XCTAssertEqual(result.curvatureDirection, .invalid, "Linear movement should have invalid curvature")
    }
    
    func testInvalidTrajectory_ErraticMovement() {
        let positions = createErraticTrajectory(steps: 12)
        
        let result = validator.validateTrajectory(positions)
        
        XCTAssertFalse(result.isValid, "Erratic movement should be invalid")
        XCTAssertLessThan(result.r2Correlation, 0.5, "Erratic movement should have poor correlation")
        XCTAssertLessThan(result.velocityConsistency, 0.3, "Erratic movement should have poor velocity consistency")
    }
    
    // MARK: - Configuration Tests
    
    func testValidation_CustomR2Threshold() {
        let config = ParabolicValidator.Config(
            minR2Threshold: 0.95,
            minPoints: 5,
            gravityDirection: .down,
            maxVelocityChange: 0.2,
            minParabolicCurvature: 0.01
        )
        let strictValidator = ParabolicValidator(config: config)
        
        let positions = createNoisyParabolicTrajectory(
            initialVelocity: CGVector(dx: 3.0, dy: -6.0),
            gravity: 9.8,
            noiseLevel: 0.1,
            timeStep: 0.1,
            steps: 10
        )
        
        let defaultResult = validator.validateTrajectory(positions)
        let strictResult = strictValidator.validateTrajectory(positions)
        
        // Default validator might accept noisy data, strict validator should reject
        if defaultResult.isValid && strictResult.r2Correlation < 0.95 {
            XCTAssertFalse(strictResult.isValid, "Strict validator should reject noisy trajectories")
        }
    }
    
    func testValidation_GravityDirection() {
        let upGravityConfig = ParabolicValidator.Config(
            minR2Threshold: 0.85,
            minPoints: 8,
            gravityDirection: .up,
            maxVelocityChange: 0.3,
            minParabolicCurvature: 0.001
        )
        let upValidator = ParabolicValidator(config: upGravityConfig)
        
        let positions = createParabolicTrajectory(
            initialVelocity: CGVector(dx: 5.0, dy: 8.0), // Upward initial velocity
            gravity: -9.8, // Upward gravity
            timeStep: 0.1,
            steps: 10
        )
        
        let downResult = validator.validateTrajectory(positions)
        let upResult = upValidator.validateTrajectory(positions)
        
        XCTAssertFalse(downResult.isValid || downResult.curvatureDirection == .upward, 
                      "Down gravity validator should reject upward gravity trajectory")
        XCTAssertTrue(upResult.isValid, "Up gravity validator should accept upward gravity trajectory")
        XCTAssertEqual(upResult.curvatureDirection, .downward, "Up gravity should create downward-opening parabola")
    }
    
    // MARK: - R² Correlation Tests
    
    func testR2Calculation_PerfectFit() {
        let positions = createParabolicTrajectory(
            initialVelocity: CGVector(dx: 4.0, dy: -7.0),
            gravity: 9.8,
            timeStep: 0.1,
            steps: 12
        )
        
        let r2 = validator.calculateR2Correlation(positions)
        
        XCTAssertGreaterThan(r2, 0.98, "Perfect parabolic trajectory should have R² > 0.98")
    }
    
    func testR2Calculation_PoorFit() {
        let positions = createErraticTrajectory(steps: 10)
        
        let r2 = validator.calculateR2Correlation(positions)
        
        XCTAssertLessThan(r2, 0.5, "Erratic trajectory should have R² < 0.5")
    }
    
    // MARK: - Parabolic Trajectory Detection Tests
    
    func testIsParabolicTrajectory_ValidProjectile() {
        let positions = createParabolicTrajectory(
            initialVelocity: CGVector(dx: 6.0, dy: -10.0),
            gravity: 9.8,
            timeStep: 0.08,
            steps: 15
        )
        
        let isParabolic = validator.isParabolicTrajectory(positions)
        
        XCTAssertTrue(isParabolic, "Valid projectile trajectory should be detected as parabolic")
    }
    
    func testIsParabolicTrajectory_NonProjectile() {
        let positions = createLinearTrajectory(
            start: CGPoint(x: 2, y: 3),
            velocity: CGVector(dx: 1.5, dy: 0.5),
            timeStep: 0.1,
            steps: 12
        )
        
        let isParabolic = validator.isParabolicTrajectory(positions)
        
        XCTAssertFalse(isParabolic, "Linear trajectory should not be detected as parabolic")
    }
    
    // MARK: - Velocity Consistency Tests
    
    func testVelocityConsistency_SmoothTrajectory() {
        let positions = createParabolicTrajectory(
            initialVelocity: CGVector(dx: 3.0, dy: -5.0),
            gravity: 9.8,
            timeStep: 0.1,
            steps: 10
        )
        
        let result = validator.validateTrajectory(positions)
        
        XCTAssertGreaterThan(result.velocityConsistency, 0.4, "Smooth parabolic trajectory should have good velocity consistency")
    }
    
    func testVelocityConsistency_ErraticMovement() {
        let positions = createErraticTrajectory(steps: 10)
        
        let result = validator.validateTrajectory(positions)
        
        XCTAssertLessThan(result.velocityConsistency, 0.3, "Erratic movement should have poor velocity consistency")
    }
    
    // MARK: - Edge Cases
    
    func testValidation_ZeroVelocity() {
        let positions = Array(repeating: (CGPoint(x: 5, y: 5), CMTime.zero), count: 10)
        
        let result = validator.validateTrajectory(positions)
        
        XCTAssertFalse(result.isValid, "Zero velocity trajectory should be invalid")
        XCTAssertEqual(result.curvatureDirection, .invalid, "Zero velocity should have invalid curvature")
    }
    
    func testValidation_NearVerticalTrajectory() {
        let positions = createParabolicTrajectory(
            initialVelocity: CGVector(dx: 0.1, dy: -10.0), // Nearly vertical
            gravity: 9.8,
            timeStep: 0.1,
            steps: 8
        )
        
        let result = validator.validateTrajectory(positions)
        
        // Should still be valid if it follows parabolic physics
        XCTAssertTrue(result.r2Correlation > 0.8, "Near-vertical parabolic trajectory should have good R²")
    }
    
    // MARK: - Helper Methods
    
    private func createParabolicTrajectory(
        initialVelocity: CGVector,
        gravity: Double,
        timeStep: Double,
        steps: Int
    ) -> [(CGPoint, CMTime)] {
        var positions: [(CGPoint, CMTime)] = []
        let startPoint = CGPoint(x: 0, y: 10) // Start above ground
        
        for i in 0..<steps {
            let t = Double(i) * timeStep
            let x = startPoint.x + initialVelocity.dx * CGFloat(t)
            let y = startPoint.y + initialVelocity.dy * CGFloat(t) + CGFloat(0.5 * gravity * t * t)
            
            let time = CMTimeMakeWithSeconds(t, preferredTimescale: 600)
            positions.append((CGPoint(x: x, y: y), time))
        }
        
        return positions
    }
    
    private func createLinearTrajectory(
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
    
    private func createNoisyParabolicTrajectory(
        initialVelocity: CGVector,
        gravity: Double,
        noiseLevel: Double,
        timeStep: Double,
        steps: Int
    ) -> [(CGPoint, CMTime)] {
        let baseTrajectory = createParabolicTrajectory(
            initialVelocity: initialVelocity,
            gravity: gravity,
            timeStep: timeStep,
            steps: steps
        )
        
        return baseTrajectory.map { position, time in
            let noiseX = CGFloat.random(in: -noiseLevel...noiseLevel)
            let noiseY = CGFloat.random(in: -noiseLevel...noiseLevel)
            let noisyPoint = CGPoint(x: position.x + noiseX, y: position.y + noiseY)
            return (noisyPoint, time)
        }
    }
    
    private func createErraticTrajectory(steps: Int) -> [(CGPoint, CMTime)] {
        var positions: [(CGPoint, CMTime)] = []
        var currentPoint = CGPoint(x: 0, y: 5)
        
        for i in 0..<steps {
            let randomDx = CGFloat.random(in: -2...2)
            let randomDy = CGFloat.random(in: -2...2)
            currentPoint = CGPoint(x: currentPoint.x + randomDx, y: currentPoint.y + randomDy)
            
            let time = CMTimeMakeWithSeconds(Double(i) * 0.1, preferredTimescale: 600)
            positions.append((currentPoint, time))
        }
        
        return positions
    }
}