//
//  TrackedBallTestHelper.swift
//  BumpSetCutTests
//
//  Test helper to create TrackedBall from a list of positions.
//

import CoreGraphics
import CoreMedia
@testable import BumpSetCut

extension KalmanBallTracker.TrackedBall {
    /// Convenience initializer for tests that creates a TrackedBall from pre-built positions.
    init(positions: [(CGPoint, CMTime)]) {
        let config = ProcessorConfig()
        guard let first = positions.first else {
            self.init(position: .zero, timestamp: .zero, config: config)
            return
        }
        self.init(position: first.0, timestamp: first.1, config: config)
        for pos in positions.dropFirst() {
            self.update(measurement: pos.0, timestamp: pos.1, config: config)
        }
    }
}
