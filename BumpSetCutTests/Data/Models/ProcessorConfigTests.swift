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
        XCTAssertTrue(config.movementClassifierEnabled, "Movement classifier should be enabled by default")
        XCTAssertEqual(config.minClassificationConfidence, 0.7, accuracy: 0.001, "Default classification confidence should be 0.7")
        XCTAssertFalse(config.enableMetricsCollection, "Metrics collection should be disabled by default for production")
    }

    // MARK: - Validation Tests
    
    func testValidConfiguration() {
        XCTAssertNoThrow(try config.validate(), "Default configuration should be valid")
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
    
    // MARK: - Parameter Modification Tests
    
    func testWithModifications() {
        let modifications: [String: Any] = [
            "minClassificationConfidence": 0.8,
            "enableMetricsCollection": true,
            "unknownParameter": "ignored"  // Should be ignored
        ]

        let modifiedConfig = config.withModifications(modifications)

        XCTAssertEqual(modifiedConfig.minClassificationConfidence, 0.8, accuracy: 0.001, "Classification confidence should be modified")
        XCTAssertTrue(modifiedConfig.enableMetricsCollection, "Metrics collection should be enabled")

        // Original config should remain unchanged
        XCTAssertEqual(config.minClassificationConfidence, 0.7, accuracy: 0.001, "Original config should be unchanged")
        XCTAssertFalse(config.enableMetricsCollection, "Original config should be unchanged")
    }

    func testWithModificationsInvalidTypes() {
        let modifications: [String: Any] = [
            "minClassificationConfidence": "invalid_string",  // Wrong type
            "enableMetricsCollection": "not_boolean"  // Wrong type
        ]

        let modifiedConfig = config.withModifications(modifications)

        // Should fallback to original values for invalid types
        XCTAssertEqual(modifiedConfig.minClassificationConfidence, config.minClassificationConfidence, accuracy: 0.001, "Should fallback to original value")
        XCTAssertEqual(modifiedConfig.enableMetricsCollection, config.enableMetricsCollection, "Should fallback to original value")
    }

    // MARK: - Reset to Defaults Tests
    
    func testResetToDefaults() {
        // Modify config away from defaults
        config.minClassificationConfidence = 0.9
        config.enableMetricsCollection = true

        // Reset to defaults
        config.resetToDefaults()

        // Verify reset
        XCTAssertEqual(config.minClassificationConfidence, 0.7, accuracy: 0.001, "Should reset to default classification confidence")
        XCTAssertFalse(config.enableMetricsCollection, "Should reset to default metrics setting")
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
    }

    // MARK: - Integration Tests
    
    func testBackwardCompatibility() {
        // Ensure all original parameters still exist with expected defaults
        XCTAssertEqual(config.parabolaMinPoints, 4, "Original parameter should be preserved")
        XCTAssertEqual(config.parabolaMinR2, 0.80, accuracy: 0.001, "Original parameter should be preserved")
        XCTAssertEqual(config.projectileWindowSec, 0.7452, accuracy: 0.001, "Original parameter should be preserved")
        XCTAssertEqual(config.startBuffer, 0.1685, accuracy: 0.001, "Original parameter should be preserved")
        XCTAssertEqual(config.preroll, 2.0, accuracy: 0.001, "Original parameter should be preserved")
    }
    
    // MARK: - Performance Tests
    
    func testConfigurationPerformance() {
        measure {
            for _ in 0..<1000 {
                let testConfig = ProcessorConfig()
                _ = try? testConfig.validate()
                _ = testConfig.withModifications(["minClassificationConfidence": 0.9])
            }
        }
    }
}