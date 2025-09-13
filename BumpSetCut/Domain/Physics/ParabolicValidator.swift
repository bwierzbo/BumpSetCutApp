//
//  ParabolicValidator.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/4/25.
//

import CoreGraphics
import CoreMedia

/// Validates trajectory physics using parabolic curve fitting and correlation analysis
struct ParabolicValidator {
    
    /// Configuration for parabolic validation
    struct Config {
        let minR2Threshold: Double
        let minPoints: Int
        let gravityDirection: GravityDirection
        let maxVelocityChange: CGFloat
        let minParabolicCurvature: CGFloat
        
        enum GravityDirection {
            case down
            case up
        }
        
        static let `default` = Config(
            minR2Threshold: 0.85,
            minPoints: 8,
            gravityDirection: .down,
            maxVelocityChange: 0.3,
            minParabolicCurvature: 0.001
        )
    }
    
    /// Result of parabolic validation
    struct ValidationResult {
        let isValid: Bool
        let r2Correlation: Double
        let curvatureDirection: CurvatureDirection
        let velocityConsistency: Double
        let parabolicCoefficients: (a: CGFloat, b: CGFloat, c: CGFloat)?
        
        enum CurvatureDirection {
            case upward
            case downward
            case invalid
        }
    }
    
    private let config: Config
    
    init(config: Config = .default) {
        self.config = config
    }
    
    /// Validates trajectory using parabolic fitting and physics constraints
    func validateTrajectory(_ positions: [(CGPoint, CMTime)]) -> ValidationResult {
        guard positions.count >= config.minPoints else {
            return ValidationResult(
                isValid: false,
                r2Correlation: 0.0,
                curvatureDirection: .invalid,
                velocityConsistency: 0.0,
                parabolicCoefficients: nil
            )
        }
        
        let points = positions.map { $0.0 }
        
        guard let fitResult = fitQuadratic(points: points) else {
            return ValidationResult(
                isValid: false,
                r2Correlation: 0.0,
                curvatureDirection: .invalid,
                velocityConsistency: 0.0,
                parabolicCoefficients: nil
            )
        }
        
        let curvatureDirection = determineCurvatureDirection(coefficient: fitResult.a)
        let velocityConsistency = calculateVelocityConsistency(positions)
        let isPhysicallyValid = validatePhysicsConstraints(fitResult, curvatureDirection)
        
        let isValid = fitResult.r2 >= config.minR2Threshold && 
                     isPhysicallyValid && 
                     velocityConsistency >= 0.5
        
        return ValidationResult(
            isValid: isValid,
            r2Correlation: fitResult.r2,
            curvatureDirection: curvatureDirection,
            velocityConsistency: velocityConsistency,
            parabolicCoefficients: (fitResult.a, fitResult.b, fitResult.c)
        )
    }
    
    /// Calculates R² correlation for a given trajectory against parabolic model
    func calculateR2Correlation(_ positions: [(CGPoint, CMTime)]) -> Double {
        let points = positions.map { $0.0 }
        return fitQuadratic(points: points)?.r2 ?? 0.0
    }
    
    /// Determines if trajectory exhibits parabolic behavior consistent with projectile motion
    func isParabolicTrajectory(_ positions: [(CGPoint, CMTime)]) -> Bool {
        let result = validateTrajectory(positions)
        return result.isValid
    }
    
    // MARK: - Private Methods
    
    private func determineCurvatureDirection(coefficient a: CGFloat) -> ValidationResult.CurvatureDirection {
        if abs(a) < config.minParabolicCurvature {
            return .invalid
        }
        
        switch config.gravityDirection {
        case .down:
            return a > 0 ? .upward : .downward
        case .up:
            return a > 0 ? .downward : .upward
        }
    }
    
    private func validatePhysicsConstraints(_ fitResult: QuadraticFitResult, _ curvatureDirection: ValidationResult.CurvatureDirection) -> Bool {
        // Check if curvature direction matches expected gravity direction
        let expectedCurvature: ValidationResult.CurvatureDirection = (config.gravityDirection == .down) ? .upward : .downward
        guard curvatureDirection == expectedCurvature else { return false }
        
        // Validate parabolic coefficient magnitude (reasonable curvature)
        guard abs(fitResult.a) >= config.minParabolicCurvature else { return false }
        
        return true
    }
    
    private func calculateVelocityConsistency(_ positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 3 else { return 0.0 }
        
        var velocities: [CGFloat] = []
        
        for i in 1..<positions.count {
            let p1 = positions[i-1]
            let p2 = positions[i]
            
            let dx = p2.0.x - p1.0.x
            let dy = p2.0.y - p1.0.y
            let dt = CMTimeGetSeconds(CMTimeSubtract(p2.1, p1.1))
            
            guard dt > 0 else { continue }
            
            let velocity = sqrt(dx*dx + dy*dy) / CGFloat(dt)
            velocities.append(velocity)
        }
        
        guard velocities.count >= 2 else { return 0.0 }
        
        let mean = velocities.reduce(0, +) / CGFloat(velocities.count)
        let variance = velocities.reduce(CGFloat(0)) { result, velocity in
            result + pow(velocity - mean, 2)
        } / CGFloat(velocities.count)
        
        let standardDeviation = sqrt(variance)
        let coefficientOfVariation = mean > 0 ? standardDeviation / mean : CGFloat.greatestFiniteMagnitude
        
        // Convert coefficient of variation to consistency score (0-1)
        // Lower CV = higher consistency
        return Double(max(0, min(1, 1 - coefficientOfVariation)))
    }
}