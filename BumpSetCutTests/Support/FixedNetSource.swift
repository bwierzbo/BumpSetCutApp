//
//  FixedNetSource.swift
//  BumpSetCutTests
//
//  A net source for tests: it answers what it is told to, and counts how often it is asked.
//

import AVFoundation
@testable import BumpSetCut

final class FixedNetSource: NetGeometrySource {
    let answer: NetGeometry
    private(set) var asked = 0

    init(_ answer: NetGeometry) { self.answer = answer }

    func netGeometry(forVideoAt url: URL, asset: AVAsset, durationSec: Double, config: ProcessorConfig) async -> NetGeometry {
        asked += 1
        return answer
    }
}
