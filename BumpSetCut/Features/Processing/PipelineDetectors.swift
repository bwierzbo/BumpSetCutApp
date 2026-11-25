//
//  PipelineDetectors.swift
//  BumpSetCut
//
//  What the pipeline asks of a build beyond the multi-frame ball model: a detector that
//  reads one frame at a time, and where the net is. Neither is part of the pipeline; each
//  build says what it has (PipelineDefaults). The apps that ship have no single-frame
//  detector, and know the net only where a person confirmed it. RallyLab on the Mac has
//  its research detectors. Compiled into RallyLab and RallyLab on the iPhone too.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO

/// A detector that finds the ball in one frame at a time.
protocol SingleFrameBallDetector: AnyObject {
    var modelName: String { get }
    /// The balls in a frame, Vision-normalised in the frame turned upright by orientation.
    func detect(in pixelBuffer: CVPixelBuffer, at time: CMTime, orientation: CGImagePropertyOrientation) -> [DetectionResult]
}

/// What a run knows of the net, and from where. The net-dependent rules (under-net, off-court, above-net) run only
/// on a net that is here; with none they are skipped and the run says so — no net is never read as "the ball is in
/// the court" or "above the net", and no net is made up.
enum NetGeometry {
    /// A person placed and confirmed it (court and net calibration).
    case confirmed(DetectedNet)
    /// An automatic method found it; nobody confirmed it.
    case detected(DetectedNet, method: String)
    case unavailable(reason: String)

    static let personConfirmed = "person_confirmed"
    static let unavailable = "unavailable"

    var net: DetectedNet? {
        switch self {
        case .confirmed(let net), .detected(let net, _): return net
        case .unavailable: return nil
        }
    }

    /// "person_confirmed", the automatic method's name, or "unavailable".
    var origin: String {
        switch self {
        case .confirmed: return Self.personConfirmed
        case .detected(_, let method): return method
        case .unavailable: return Self.unavailable
        }
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// A net kept with its origin (a resume checkpoint).
    init(net: DetectedNet, origin: String) {
        self = origin == Self.personConfirmed ? .confirmed(net) : .detected(net, method: origin)
    }
}

/// Where a run's net comes from.
protocol NetGeometrySource: AnyObject {
    /// The net for the whole of the video at url, in the frame space config detects in (upright when
    /// applyVideoRotation is on).
    func netGeometry(forVideoAt url: URL, asset: AVAsset, durationSec: Double, config: ProcessorConfig) async -> NetGeometry
}

/// A build, or a caller, with nothing that knows where the net is.
final class NoNetGeometrySource: NetGeometrySource {
    func netGeometry(forVideoAt url: URL, asset: AVAsset, durationSec: Double, config: ProcessorConfig) async -> NetGeometry {
        .unavailable(reason: "nothing in this build knows where the net is")
    }
}
