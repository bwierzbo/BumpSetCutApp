//
//  CalibrationNetSource.swift
//  BumpSetCut
//
//  The net a person confirmed for a video, as the pipeline's net: the box round its four
//  corners, which is what the net rules read. Only a confirmation counts, only for the
//  file it was made on, and only when one camera view covers the whole video — the rules
//  take one net for a run. Anything else is "unavailable" with its reason, and the rules
//  that need a net are skipped.
//

import AVFoundation
import Foundation
import ImageIO

final class CalibrationNetSource: NetGeometrySource {
    private let store: CourtNetCalibrationStore
    private let recordingId: String

    init(store: CourtNetCalibrationStore, videoId: UUID) {
        self.store = store
        recordingId = videoId.uuidString
    }

    func netGeometry(forVideoAt url: URL, asset: AVAsset, durationSec: Double, config: ProcessorConfig) async -> NetGeometry {
        guard let video = try? await CalibrationVideo.load(recordingId: recordingId, url: url) else {
            return .unavailable(reason: "the video can't be read for its calibration")
        }
        return Self.geometry(from: store.lookup(for: video.binding), config: config)
    }

    static func geometry(from lookup: CourtNetCalibrationStore.Lookup, config: ProcessorConfig) -> NetGeometry {
        switch lookup {
        case .none:
            return .unavailable(reason: "no court and net calibration")
        case .stale(_, let reason):
            return .unavailable(reason: "the calibration is for another version of the video (\(reason))")
        case .unreadable(let why):
            return .unavailable(reason: "the calibration can't be read (\(why))")
        case .usable(let file):
            guard file.segments.count == 1, let view = file.segments.first else {
                return .unavailable(reason: "the camera view changes during the video")
            }
            guard view.view == .stable else { return .unavailable(reason: "the video is not marked as a stable court view") }
            guard let net = file.confirmed(\.net, at: view.validFromSec)?.geometry else {
                return .unavailable(reason: "the net is not confirmed")
            }
            // The calibration is in the upright frame: usable only by a run that detects there.
            guard config.applyVideoRotation || file.orientation == CGImagePropertyOrientation.up.rawValue else {
                return .unavailable(reason: "the run reads frames as stored and the calibration is in the upright frame")
            }
            return .confirmed(DetectedNet(box: net.bounds, confidence: 1))
        }
    }
}
