//
//  CalibrationNetSource.swift
//  BumpSetCut
//
//  The net a person confirmed for a video, as the pipeline's net: the box round its four
//  corners, which is what the net rules read. Only a confirmation counts, only for the
//  file it was made on, and only when one camera view covers the whole video — the rules
//  take one net for a run. Anything else is "unavailable" with its reason, and the rules
//  that need a net are skipped. The video's screen asks the same question before a run
//  (usableNet), so what it warns of is what the run will do.
//

import AVFoundation
import Foundation
import ImageIO

final class CalibrationNetSource: NetGeometrySource {
    /// Why a video has no net the rules can run on.
    enum Unavailable: Equatable {
        case videoUnreadable
        case noCalibration
        /// On file for another version of the video.
        case stale(String)
        case unreadable(String)
        /// More than one camera view: the rules take one net for a whole run.
        case severalViews
        case notStableView
        case netNotConfirmed
        /// The run reads rotated frames as stored; the calibration is in the upright frame.
        case storedFrames

        /// For the run's record and log.
        var reason: String {
            switch self {
            case .videoUnreadable: return "the video can't be read for its calibration"
            case .noCalibration: return "no court and net calibration"
            case .stale(let why): return "the calibration is for another version of the video (\(why))"
            case .unreadable(let why): return "the calibration can't be read (\(why))"
            case .severalViews: return "the camera view changes during the video"
            case .notStableView: return "the video is not marked as a stable court view"
            case .netNotConfirmed: return "the net is not confirmed"
            case .storedFrames: return "the run reads frames as stored and the calibration is in the upright frame"
            }
        }
    }

    private let store: CourtNetCalibrationStore
    private let recordingId: String

    init(store: CourtNetCalibrationStore, videoId: UUID) {
        self.store = store
        recordingId = videoId.uuidString
    }

    func netGeometry(forVideoAt url: URL, asset: AVAsset, durationSec: Double, config: ProcessorConfig) async -> NetGeometry {
        switch await usableNet(forVideoAt: url, config: config) {
        case .success(let net): return .confirmed(net)
        case .failure(let why): return .unavailable(reason: why.reason)
        }
    }

    /// The net a run over this video would use with config, or why it would have none.
    func usableNet(forVideoAt url: URL, config: ProcessorConfig) async -> Result<DetectedNet, Unavailable> {
        guard let video = try? await CalibrationVideo.load(recordingId: recordingId, url: url) else { return .failure(.videoUnreadable) }
        return Self.usableNet(from: store.lookup(for: video.binding), config: config)
    }

    static func usableNet(from lookup: CourtNetCalibrationStore.Lookup, config: ProcessorConfig) -> Result<DetectedNet, Unavailable> {
        switch lookup {
        case .none:
            return .failure(.noCalibration)
        case .stale(_, let reason):
            return .failure(.stale(reason))
        case .unreadable(let why):
            return .failure(.unreadable(why))
        case .usable(let file):
            guard file.segments.count == 1, let view = file.segments.first else { return .failure(.severalViews) }
            guard view.view == .stable else { return .failure(.notStableView) }
            guard let net = file.confirmed(\.net, at: view.validFromSec)?.geometry else { return .failure(.netNotConfirmed) }
            // The calibration is in the upright frame: usable only by a run that detects there.
            guard config.applyVideoRotation || file.orientation == CGImagePropertyOrientation.up.rawValue else { return .failure(.storedFrames) }
            return .success(DetectedNet(box: net.bounds, confidence: 1))
        }
    }
}

extension CalibrationNetSource.Unavailable: Error {}
