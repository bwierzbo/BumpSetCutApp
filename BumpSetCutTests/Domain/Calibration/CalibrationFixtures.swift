//
//  CalibrationFixtures.swift
//  BumpSetCutTests
//
//  Shapes the calibration tests share: a court seen in perspective from behind an end
//  line, and a net across it.
//

import Foundation
@testable import BumpSetCut

enum CalibrationFixtures {
    static func point(_ x: Double, _ y: Double, _ status: CourtPoint.Status = .seen) -> CourtPoint { CourtPoint(x: x, y: y, status: status) }

    /// A trapezoid narrowing with distance: nothing about it is a rectangle on screen.
    static let court = CourtLayout(nearLeft: point(0.10, 0.10), nearRight: point(0.90, 0.10), netRight: point(0.75, 0.45),
                                   netLeft: point(0.25, 0.45), farLeft: point(0.33, 0.62), farRight: point(0.67, 0.62))

    static let net = NetQuad(topLeft: .init(x: 0.24, y: 0.60), topRight: .init(x: 0.76, y: 0.61),
                             bottomRight: .init(x: 0.76, y: 0.50), bottomLeft: .init(x: 0.24, y: 0.49))

    static let binding = CourtNetCalibrationFile.Binding(recordingId: "5D1F0C0E-0000-4000-8000-000000000001", sourceFingerprint: "file:abc",
                                                         frameWidth: 1920, frameHeight: 1080, orientation: 1, durationSec: 120)

    static let day = Date(timeIntervalSince1970: 1_795_000_000)
}
