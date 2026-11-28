//
//  SavedBallsFixture.swift
//  BumpSetCutTests
//
//  A saved-balls log written by hand, for tests that decide rallies from one: no model found these.
//

import AVFoundation
@testable import BumpSetCut

extension BallDetectionLog {
    /// Thirty frames a second for 14 s of `file`. From 1 s to 9 s one ball goes over the middle of the frame and
    /// back in one-second arcs; before and after there is none.
    static func writtenArcs(of file: URL, upright: Bool = ProcessorConfig().applyVideoRotation) -> BallDetectionLog {
        let frames: [BallDetectionLog.Frame] = (0..<420).map { i in
            let t = Double(i) / 30
            guard t >= 1, t < 9 else { return .init(time: CMTime(value: Int64(i) * 20, timescale: 600), detections: [], singleFrameCount: 0) }
            let arc = Int(t - 1), u = (t - 1) - Double(arc)
            let across = arc % 2 == 0 ? u : 1 - u
            let box = CGRect(x: 0.3 + 0.4 * across - 0.015, y: 0.45 + 1.4 * u * (1 - u) - 0.015, width: 0.03, height: 0.03)
            return .init(time: CMTime(value: Int64(i) * 20, timescale: 600), detections: [.init(bbox: box, confidence: 0.9)], singleFrameCount: 0)
        }
        return BallDetectionLog(header: .init(sourceFingerprint: FileFingerprint.read(atPath: file.path), durationSec: 14, upright: upright,
                                              finder: "written by the test", decodedFrameCount: 840, skippedFrameCount: 420, resumedAtSec: []),
                                frames: frames)
    }
}
