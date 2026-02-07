//
//  ProcessorConfigTests.swift
//  BumpSetCutTests
//
//  Created for Configuration Enhancement - Issue #22
//

import XCTest
@testable import BumpSetCut

final class ProcessorConfigTests: XCTestCase {
    
    var config: ProcessorConfig!
    
    override func setUp() {
        super.setUp()
        config = ProcessorConfig()
    }
    
    override func tearDown() {
        config = nil
        super.tearDown()
    }
    
    // MARK: - Default Configuration Tests
    
    func testDefaultConfiguration() {
        XCTAssertFalse(config.enableEnhancedPhysics, "Enhanced physics should be disabled by default (temporarily disabled)")
        XCTAssertEqual(config.enhancedMinR2, 0.85, accuracy: 0.001, "Default enhanced R² threshold should be 0.85")
        XCTAssertTrue(config.movementClassifierEnabled, "Movement classifier should be enabled by default")
        XCTAssertEqual(config.minClassificationConfidence, 0.7, accuracy: 0.001, "Default classification confidence should be 0.7")
        XCTAssertFalse(config.enableMetricsCollection, "Metrics collection should be disabled by default for production")
        XCTAssertFalse(config.enableParameterOptimization, "Parameter optimization should be disabled by default")
    }
    
    func testDefaultQualityScoringWeights() {
        let weightSum = config.velocityConsistencyWeight + config.accelerationPatternWeight + 
                       config.smoothnessWeight + config.verticalMotionWeight
        XCTAssertEqual(weightSum, 1.0, accuracy: 0.001, "Quality scoring weights should sum to 1.0")
    }
    
    // MARK: - Validation Tests
    
    func testValidConfiguration() {
        XCTAssertNoThrow(try config.validate(), "Default configuration should be valid")
    }
    
    func testInvalidR2Threshold() {
        config.enhancedMinR2 = 1.5  // Invalid - greater than 1.0
        
        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigurationError.invalidParameter(let message) = error else {
                XCTFail("Expected invalidParameter error")
                return
            }
            XCTAssertTrue(message.contains("enhancedMinR2"), "Error should mention enhancedMinR2")
        }
    }
    
    func testInvalidClassificationConfidence() {
        config.minClassificationConfidence = -0.1  // Invalid - negative
        
        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigurationError.invalidParameter(let message) = error else {
                XCTFail("Expected invalidParameter error")
                return
            }
            XCTAssertTrue(message.contains("minClassificationConfidence"), "Error should mention minClassificationConfidence")
        }
    }
    
    func testInvalidQualityScoringWeights() {
        config.velocityConsistencyWeight = 0.5
        config.accelerationPatternWeight = 0.5
        config.smoothnessWeight = 0.5  // Total = 1.5, invalid
        config.verticalMotionWeight = 0.0
        
        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigurationError.invalidParameter(let message) = error else {
                XCTFail("Expected invalidParameter error")
                return
            }
            XCTAssertTrue(message.contains("Quality scoring weights"), "Error should mention quality scoring weights")
        }
    }
    
    func testInvalidSamplingRate() {
        config.metricsCollectionSamplingRate = 1.5  // Invalid - greater than 1.0
        
        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigurationError.invalidParameter(let message) = error else {
                XCTFail("Expected invalidParameter error")
                return
            }
            XCTAssertTrue(message.contains("metricsCollectionSamplingRate"), "Error should mention sampling rate")
        }
    }
    
    func testInvalidPerformanceThreshold() {
        config.maxProcessingOverheadPercent = 150  // Invalid - greater than 100
        
        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigurationError.invalidParameter(let message) = error else {
                XCTFail("Expected invalidParameter error")
                return
            }
            XCTAssertTrue(message.contains("maxProcessingOverheadPercent"), "Error should mention performance threshold")
        }
    }
    
    // MARK: - Parameter Modification Tests
    
    func testWithModifications() {
        let modifications: [String: Any] = [
            "enhancedMinR2": 0.9,
            "minClassificationConfidence": 0.8,
            "enableEnhancedPhysics": true,
            "enableMetricsCollection": true,
            "unknownParameter": "ignored"  // Should be ignored
        ]

        let modifiedConfig = config.withModifications(modifications)

        XCTAssertEqual(modifiedConfig.enhancedMinR2, 0.9, accuracy: 0.001, "R² threshold should be modified")
        XCTAssertEqual(modifiedConfig.minClassificationConfidence, 0.8, accuracy: 0.001, "Classification confidence should be modified")
        XCTAssertTrue(modifiedConfig.enableEnhancedPhysics, "Enhanced physics should be enabled")
        XCTAssertTrue(modifiedConfig.enableMetricsCollection, "Metrics collection should be enabled")

        // Original config should remain unchanged
        XCTAssertEqual(config.enhancedMinR2, 0.85, accuracy: 0.001, "Original config should be unchanged")
        XCTAssertFalse(config.enableEnhancedPhysics, "Original config should be unchanged")
    }
    
    func testWithModificationsInvalidTypes() {
        let modifications: [String: Any] = [
            "enhancedMinR2": "invalid_string",  // Wrong type
            "enableEnhancedPhysics": "not_boolean"  // Wrong type
        ]
        
        let modifiedConfig = config.withModifications(modifications)
        
        // Should fallback to original values for invalid types
        XCTAssertEqual(modifiedConfig.enhancedMinR2, config.enhancedMinR2, accuracy: 0.001, "Should fallback to original value")
        XCTAssertEqual(modifiedConfig.enableEnhancedPhysics, config.enableEnhancedPhysics, "Should fallback to original value")
    }
    
    // MARK: - Reset to Defaults Tests
    
    func testResetToDefaults() {
        // Modify config away from defaults
        config.enhancedMinR2 = 0.9
        config.enableEnhancedPhysics = true
        config.enableMetricsCollection = true

        // Reset to defaults
        config.resetToDefaults()

        // Verify reset
        XCTAssertEqual(config.enhancedMinR2, 0.85, accuracy: 0.001, "Should reset to default R² threshold")
        XCTAssertFalse(config.enableEnhancedPhysics, "Should reset to default enhanced physics setting")
        XCTAssertFalse(config.enableMetricsCollection, "Should reset to default metrics setting")
    }
    
    // MARK: - Physics Parameters Tests
    
    func testPhysicsValidationParameters() {
        XCTAssertTrue(config.enablePhysicsConstraints, "Physics constraints should be enabled by default")
        XCTAssertEqual(config.maxAccelerationDeviation, 2.0, accuracy: 0.001, "Default acceleration deviation should be 2.0")
        XCTAssertEqual(config.velocityConsistencyThreshold, 0.5, accuracy: 0.001, "Default velocity consistency should be 0.5")
        XCTAssertEqual(config.trajectorySmoothnessThreshold, 0.6, accuracy: 0.001, "Default smoothness threshold should be 0.6")
    }
    
    func testMovementClassificationParameters() {
        // Airborne parameters
        XCTAssertEqual(config.airbornePhysicsThreshold, 0.7, accuracy: 0.001, "Default airborne threshold should be 0.7")
        XCTAssertEqual(config.minAccelerationPattern, 0.6, accuracy: 0.001, "Default acceleration pattern threshold should be 0.6")
        XCTAssertEqual(config.minSmoothnessForAirborne, 0.6, accuracy: 0.001, "Default airborne smoothness should be 0.6")
        
        // Rolling parameters
        XCTAssertEqual(config.maxVerticalMotionForRolling, 0.3, accuracy: 0.001, "Default rolling vertical motion should be 0.3")
        XCTAssertEqual(config.minSmoothnessForRolling, 0.7, accuracy: 0.001, "Default rolling smoothness should be 0.7")
        
        // Carried parameters
        XCTAssertEqual(config.minInconsistencyForCarried, 0.6, accuracy: 0.001, "Default carried inconsistency should be 0.6")
        XCTAssertEqual(config.maxSmoothnessForCarried, 0.4, accuracy: 0.001, "Default carried smoothness should be 0.4")
    }
    
    // MARK: - Metrics Collection Parameters Tests
    
    func testMetricsCollectionParameters() {
        XCTAssertFalse(config.enableMetricsCollection, "Metrics collection should be disabled by default")
        XCTAssertEqual(config.metricsCollectionSamplingRate, 0.1, accuracy: 0.001, "Default sampling rate should be 10%")
        XCTAssertFalse(config.enableAccuracyMetrics, "Accuracy metrics should be disabled by default")
        XCTAssertTrue(config.enablePerformanceMetrics, "Performance metrics should be enabled by default")
        
        XCTAssertEqual(config.maxProcessingOverheadPercent, 5.0, accuracy: 0.001, "Default overhead threshold should be 5%")
        XCTAssertEqual(config.performanceAlertThreshold, 10.0, accuracy: 0.001, "Default alert threshold should be 10%")
    }
    
    // MARK: - Optimization Parameters Tests
    
    func testOptimizationParameters() {
        XCTAssertFalse(config.enableParameterOptimization, "Parameter optimization should be disabled by default")
        XCTAssertEqual(config.optimizationMode, "disabled", "Default optimization mode should be disabled")
        XCTAssertEqual(config.maxOptimizationTimeHours, 24.0, accuracy: 0.001, "Default optimization time limit should be 24 hours")
        
        // A/B testing parameters
        XCTAssertFalse(config.enableABTesting, "A/B testing should be disabled by default")
        XCTAssertEqual(config.abTestingSplitRatio, 0.5, accuracy: 0.001, "Default A/B split should be 50/50")
        XCTAssertEqual(config.statisticalSignificanceLevel, 0.05, accuracy: 0.001, "Default significance level should be 0.05")
        XCTAssertEqual(config.minimumSampleSize, 30, "Default minimum sample size should be 30")
    }
    
    // MARK: - Integration Tests
    
    func testBackwardCompatibility() {
        // Ensure all original parameters still exist with expected defaults
        XCTAssertEqual(config.parabolaMinPoints, 8, "Original parameter should be preserved")
        XCTAssertEqual(config.parabolaMinR2, 0.85, accuracy: 0.001, "Original parameter should be preserved")
        XCTAssertEqual(config.projectileWindowSec, 0.45, accuracy: 0.001, "Original parameter should be preserved")
        XCTAssertEqual(config.trackGateRadius, 0.05, accuracy: 0.001, "Original parameter should be preserved")
        XCTAssertEqual(config.startBuffer, 0.3, accuracy: 0.001, "Original parameter should be preserved")
        XCTAssertEqual(config.preroll, 2.0, accuracy: 0.001, "Original parameter should be preserved")
    }
    
    func testOptimizationModeValidValues() {
        let validModes = ["disabled", "grid", "random", "bayesian"]
        
        for mode in validModes {
            let modifiedConfig = config.withModifications(["optimizationMode": mode])
            // Note: We don't validate optimization mode in the current implementation
            // This test documents the expected valid values
            XCTAssertNotNil(modifiedConfig, "Should create config with valid optimization mode: \(mode)")
        }
    }
    
    // MARK: - Performance Tests
    
    func testConfigurationPerformance() {
        measure {
            for _ in 0..<1000 {
                let testConfig = ProcessorConfig()
                _ = try? testConfig.validate()
                _ = testConfig.withModifications(["enhancedMinR2": 0.9])
            }
        }
    }
}