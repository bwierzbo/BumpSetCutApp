//
//  PlayerDetectors.swift
//  RallyLab
//
//  The people-and-pose detectors the player-feasibility research compares, behind one
//  interface, and the tiling that runs either of them on overlapping parts of a frame:
//
//   • VisionPlayerDetector — Apple Vision (the P0 baseline): human rectangles r2 (full body)
//     and body pose r1 on the same upright image, poses paired with boxes by joint containment.
//   • RTMPlayerDetector — OpenMMLab RTMDet-m (person) and RTMPose-m (COCO-17) converted to
//     Core ML by scripts/player_features/convert_rtm_coreml.py: the frame letterboxed to 640,
//     mmdet's NMS (IoU 0.6) over persons above `minScore`, then each person cropped as mmpose
//     does (box padded 1.25×, widened to 3:4, resized to 192×256) and posed top-down. Research
//     only: the official weights carry research-use training data (COCO + Objects365, AI
//     Challenger + COCO, ImageNet-1k backbone init); the models are read from the experiment
//     folder and are never bundled.
//
//  Every coordinate leaves here Vision-normalised (origin bottom-left) in the upright image
//  the detector was given. Nothing is a label; a joint a model did not report is null.
//

import Accelerate
import CoreML
import CoreVideo
import Foundation
import Vision

/// One frame's (or tile's) people.
struct PlayerDetections: Sendable {
    struct Person: Sendable {
        var box: PlayerFeatures.Box
        var conf: Double
        var pose: PlayerFeatures.Pose?
    }

    var persons: [Person] = []
    /// Poses no person box took (people the box detector may have missed).
    var unpairedPoses: [PlayerFeatures.Pose] = []
    var rectFailed = false
    var poseFailed = false
    var ms: [String: Double] = [:]

    /// Greedy pose → box pairing: a pose belongs to the box that holds the largest share (≥ `inside`) of its reported
    /// joints, the box widened by `margin`; ties by box then pose index. Returns the pose index for each box and the poses
    /// left over.
    static func associate(boxes: [PlayerFeatures.Box], poses: [PlayerFeatures.Pose], inside: Double = 0.6, margin: Double = 0.1)
        -> (byBox: [Int?], unmatched: [Int]) {
        var pairs: [(share: Double, b: Int, p: Int)] = []
        for (pi, pose) in poses.enumerated() {
            let pts = pose.joints.compactMap { $0 }
            guard !pts.isEmpty else { continue }
            for (bi, box) in boxes.enumerated() {
                let share = Double(pts.filter { box.contains($0.x, $0.y, margin: margin) }.count) / Double(pts.count)
                if share >= inside { pairs.append((share, bi, pi)) }
            }
        }
        pairs.sort { a, b in a.share != b.share ? a.share > b.share : (a.b != b.b ? a.b < b.b : a.p < b.p) }
        var byBox = [Int?](repeating: nil, count: boxes.count)
        var used = Set<Int>()
        for p in pairs where byBox[p.b] == nil && !used.contains(p.p) {
            byBox[p.b] = p.p
            used.insert(p.p)
        }
        return (byBox, poses.indices.filter { !used.contains($0) })
    }

    /// Greedy non-maximum suppression by score (ties by input order): a person is dropped when its IoU with a kept one
    /// exceeds `iou`, or — only when `containment` is given and `fromOtherSource` says the two came from different
    /// sources (tiles) — when their intersection covers more than `containment` of the smaller box (a person cut by a
    /// tile edge).
    static func suppress(_ persons: [Person], iou: Double, containment: Double? = nil,
                         fromOtherSource: (Int, Int) -> Bool = { _, _ in false }) -> [Int] {
        let order = persons.indices.sorted { a, b in persons[a].conf != persons[b].conf ? persons[a].conf > persons[b].conf : a < b }
        var kept: [Int] = []
        for i in order {
            let a = persons[i].box
            let clash = kept.contains { k in
                let b = persons[k].box
                if a.iou(b) > iou { return true }
                guard let containment, fromOtherSource(i, k) else { return false }
                let ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x)), iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
                return ix * iy > containment * min(a.area, b.area)
            }
            if !clash { kept.append(i) }
        }
        return kept
    }
}

protocol PlayerDetector: AnyObject, Sendable {
    /// Recorded in the run manifest's `detector`.
    var described: [String: String] { get }
    /// The people in an upright image, Vision-normalised to that image.
    func detect(_ image: CGImage) -> PlayerDetections
}

// MARK: - Apple Vision

final class VisionPlayerDetector: PlayerDetector {
    static let joints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar,
        .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .root, .leftHip, .rightHip,
        .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
    ]

    var described: [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ["name": "vision",
                "framework": "Apple Vision (system framework; no weights bundled or redistributed)",
                "os": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(ProcessInfo.processInfo.operatingSystemVersionString))",
                "rectangles": "VNDetectHumanRectanglesRequest revision \(VNDetectHumanRectanglesRequestRevision2), upperBodyOnly false",
                "pose": "VNDetectHumanBodyPoseRequest revision \(VNDetectHumanBodyPoseRequestRevision1), 19 joints, joints with confidence 0 written null",
                "pairing": "pose to box by joint containment (share >= 0.6, box widened 0.1)",
                "jointScore": "Vision recognized-point confidence, 0-1",
                "computeUnits": "Vision default (not pinned)",
                "license": "Apple SDK / macOS licence; models are not shipped with or extracted by this tool"]
    }

    private static func pose(_ o: VNHumanBodyPoseObservation) -> PlayerFeatures.Pose {
        let points = (try? o.recognizedPoints(.all)) ?? [:]
        let joints: [PlayerFeatures.Joint?] = joints.map { name in
            guard let p = points[name], p.confidence > 0 else { return nil }
            return PlayerFeatures.Joint(x: Double(p.location.x), y: Double(p.location.y), c: Double(p.confidence))
        }
        return PlayerFeatures.Pose(conf: Double(o.confidence), joints: joints)
    }

    func detect(_ image: CGImage) -> PlayerDetections {
        var out = PlayerDetections()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let rect = VNDetectHumanRectanglesRequest()
        rect.revision = VNDetectHumanRectanglesRequestRevision2
        rect.upperBodyOnly = false
        let r0 = DispatchTime.now().uptimeNanoseconds
        do { try handler.perform([rect]) } catch { out.rectFailed = true }
        out.ms["rect"] = Double(DispatchTime.now().uptimeNanoseconds - r0) / 1e6
        let boxes: [(PlayerFeatures.Box, Double)] = (rect.results ?? []).map { o in
            let b = o.boundingBox
            return (PlayerFeatures.Box(x: Double(b.minX), y: Double(b.minY), w: Double(b.width), h: Double(b.height)), Double(o.confidence))
        }
        let poseRequest = VNDetectHumanBodyPoseRequest()
        poseRequest.revision = VNDetectHumanBodyPoseRequestRevision1
        let p0 = DispatchTime.now().uptimeNanoseconds
        do { try handler.perform([poseRequest]) } catch { out.poseFailed = true }
        out.ms["pose"] = Double(DispatchTime.now().uptimeNanoseconds - p0) / 1e6
        let poses = (poseRequest.results ?? []).map(Self.pose)
        let (byBox, unmatched) = PlayerDetections.associate(boxes: boxes.map(\.0), poses: poses)
        out.persons = boxes.enumerated().map { i, b in PlayerDetections.Person(box: b.0, conf: b.1, pose: byBox[i].map { poses[$0] }) }
        out.unpairedPoses = unmatched.map { poses[$0] }
        return out
    }
}

// MARK: - RTMDet + RTMPose (Core ML, research only)

final class RTMPlayerDetector: PlayerDetector, @unchecked Sendable {
    static let detectorPackage = "rtmdet_m_person.mlpackage"
    static let posePackage = "rtmpose_m_coco17.mlpackage"
    static let detSize = 640
    static let poseW = 192, poseH = 256
    static let letterboxGray: CGFloat = 114.0 / 255.0
    /// COCO-17 keypoint → slot in `PlayerFeatures.jointNames` (neck and root are not produced: null).
    static let cocoToSlot: [Int] = ["nose", "left_eye", "right_eye", "left_ear", "right_ear", "left_shoulder", "right_shoulder",
                                    "left_elbow", "right_elbow", "left_wrist", "right_wrist", "left_hip", "right_hip", "left_knee",
                                    "right_knee", "left_ankle", "right_ankle"].map(PlayerFeatures.joint)

    enum LoadError: LocalizedError {
        case missing(URL)
        var errorDescription: String? {
            if case .missing(let url) = self { return "\(url.path) is missing: convert the models with scripts/player_features/convert_rtm_coreml.py first." }
            return nil
        }
    }

    let minScore: Double
    let maxPersons: Int
    private let detector: MLModel
    private let pose: MLModel
    private let compiled: [URL]
    private let identity: [String: String]

    /// Loads (compiles) both packages from `models`.
    init(models: URL, minScore: Double, maxPersons: Int = 40) async throws {
        let fm = FileManager.default
        let detURL = models.appendingPathComponent(Self.detectorPackage), poseURL = models.appendingPathComponent(Self.posePackage)
        for url in [detURL, poseURL] where !fm.fileExists(atPath: url.path) { throw LoadError.missing(url) }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let cDet = try await MLModel.compileModel(at: detURL)
        let cPose = try await MLModel.compileModel(at: poseURL)
        compiled = [cDet, cPose]
        detector = try MLModel(contentsOf: cDet, configuration: config)
        pose = try MLModel(contentsOf: cPose, configuration: config)
        self.minScore = minScore
        self.maxPersons = maxPersons
        func meta(_ m: MLModel, _ k: String) -> String {
            (m.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?[k] ?? "?"
        }
        identity = ["detectorPackageDigest": DatasetSplitManifest.canonicalDigest(ofDirectory: detURL) ?? "?",
                    "posePackageDigest": DatasetSplitManifest.canonicalDigest(ofDirectory: poseURL) ?? "?",
                    "detectorCheckpointSha256": meta(detector, "checkpointSha256"), "poseCheckpointSha256": meta(pose, "checkpointSha256"),
                    "detectorTrainingData": meta(detector, "trainingData"), "poseTrainingData": meta(pose, "trainingData")]
    }

    deinit { for url in compiled { try? FileManager.default.removeItem(at: url) } }

    var described: [String: String] {
        identity.merging([
            "name": "rtm",
            "detector": "RTMDet-m person (OpenMMLab, rtmdet_m_8xb32-100e_coco-obj365-person) as Core ML fp16, 640x640 letterbox (top-left, pad 114)",
            "pose": "RTMPose-m COCO-17 (OpenMMLab, rtmpose-m_simcc-aic-coco) as Core ML fp32 (fp16 collapses its scores), top-down crops 192x256, box padded 1.25 and widened to 3:4",
            "nms": "IoU 0.6 (mmdet test_cfg), score > \(minScore), at most \(maxPersons) persons posed",
            "jointSlots": "COCO-17 written into the 19 Vision slots; neck and root are not produced (null)",
            "jointScore": "raw SimCC score (min of the x/y maxima): not a probability, can exceed 1; <= 0 written null",
            "personScore": "sigmoid person score",
            "computeUnits": "all",
            "license": "code Apache-2.0 (OpenMMLab); weights carry research-use training data: RallyLab research only, never in the iOS app",
        ]) { a, _ in a }
    }

    /// A 32BGRA pixel buffer of `w`×`h`, filled with `gray`, with `draw` applied in a CG context (origin bottom-left).
    private static func buffer(_ w: Int, _ h: Int, gray: CGFloat, draw: (CGContext) -> Void) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        draw(ctx)
        return pb
    }

    /// A multi-array's values as Float, whatever its element type (fp16 read through Accelerate).
    static func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        switch a.dataType {
        case .float32:
            return a.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(n)) }
        case .double:
            return a.withUnsafeBufferPointer(ofType: Double.self) { $0.prefix(n).map(Float.init) }
        case .float16:
            var out = [Float](repeating: 0, count: n)
            a.withUnsafeBytes { raw in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                out.withUnsafeMutableBytes { dst in
                    var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&src, &d, 0)
                }
            }
            return out
        default:
            return (0..<n).map { a[$0].floatValue }
        }
    }

    private static func output(_ p: MLFeatureProvider, _ name: String) -> [Float] {
        p.featureValue(for: name)?.multiArrayValue.map(floats) ?? []
    }

    func detect(_ image: CGImage) -> PlayerDetections {
        var out = PlayerDetections()
        let W = Double(image.width), H = Double(image.height)
        let n = Double(Self.detSize)
        let s = n / max(W, H)
        let d0 = DispatchTime.now().uptimeNanoseconds
        let input = Self.buffer(Self.detSize, Self.detSize, gray: Self.letterboxGray) { ctx in
            // Top-left aligned: the image's top edge at the canvas top (CG's origin is bottom-left).
            ctx.draw(image, in: CGRect(x: 0, y: n - H * s, width: W * s, height: H * s))
        }
        guard let input, let result = try? detector.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])) else {
            out.rectFailed = true
            return out
        }
        let scores = Self.output(result, "scores"), boxes = Self.output(result, "boxes")
        var candidates: [PlayerDetections.Person] = []
        var pixelBoxes: [(Double, Double, Double, Double)] = []  // x1, y1, x2, y2 in the image's pixels, top-left origin
        for i in scores.indices where Double(scores[i]) > minScore && boxes.count >= 4 * (i + 1) {
            let x1 = max(0, Double(boxes[4 * i]) / s), y1 = max(0, Double(boxes[4 * i + 1]) / s)
            let x2 = min(W, Double(boxes[4 * i + 2]) / s), y2 = min(H, Double(boxes[4 * i + 3]) / s)
            guard x2 > x1, y2 > y1 else { continue }
            candidates.append(.init(box: PlayerFeatures.Box(x: x1 / W, y: 1 - y2 / H, w: (x2 - x1) / W, h: (y2 - y1) / H), conf: Double(scores[i]), pose: nil))
            pixelBoxes.append((x1, y1, x2, y2))
        }
        let kept = Array(PlayerDetections.suppress(candidates, iou: 0.6).prefix(100))
        out.ms["rect"] = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6

        let p0 = DispatchTime.now().uptimeNanoseconds
        for (rank, i) in kept.enumerated() {
            var person = candidates[i]
            if rank < maxPersons { person.pose = posed(image, box: pixelBoxes[i], W: W, H: H, failed: &out.poseFailed) }
            out.persons.append(person)
        }
        out.ms["pose"] = Double(DispatchTime.now().uptimeNanoseconds - p0) / 1e6
        return out
    }

    /// mmpose's GetBBoxCenterScale (padding 1.25) and TopdownAffine (aspect 3:4, no rotation, border 0), then RTMPose.
    private func posed(_ image: CGImage, box: (Double, Double, Double, Double), W: Double, H: Double, failed: inout Bool) -> PlayerFeatures.Pose? {
        let (x1, y1, x2, y2) = box
        let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2
        var w = (x2 - x1) * 1.25, h = (y2 - y1) * 1.25
        let aspect = Double(Self.poseW) / Double(Self.poseH)
        if w > h * aspect { h = w / aspect } else { w = h * aspect }
        let ox = cx - w / 2, oy = cy - h / 2, k = Double(Self.poseW) / w
        let ph = Double(Self.poseH)
        guard let crop = Self.buffer(Self.poseW, Self.poseH, gray: 0, draw: { ctx in
            ctx.draw(image, in: CGRect(x: -ox * k, y: ph - (H - oy) * k, width: W * k, height: H * k))
        }), let r = try? pose.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: crop)])) else {
            failed = true
            return nil
        }
        let kp = Self.output(r, "keypoints"), sc = Self.output(r, "scores")
        guard kp.count >= 34, sc.count >= 17 else { failed = true; return nil }
        var joints = [PlayerFeatures.Joint?](repeating: nil, count: PlayerFeatures.jointNames.count)
        for j in 0..<17 where sc[j] > 0 {
            let px = ox + Double(kp[2 * j]) / k, py = oy + Double(kp[2 * j + 1]) / k
            joints[Self.cocoToSlot[j]] = PlayerFeatures.Joint(x: px / W, y: 1 - py / H, c: Double(sc[j]))
        }
        let reported = joints.compactMap { $0 }
        return PlayerFeatures.Pose(conf: reported.isEmpty ? 0 : reported.map(\.c).reduce(0, +) / Double(reported.count), joints: joints)
    }
}

// MARK: - Tiling

/// Runs a detector on `cols`×`rows` overlapping tiles of the upright frame (each tile is enlarged to the detector's
/// input, so small people get more pixels) and merges the results back into frame coordinates: NMS at IoU 0.6, and a
/// person seen by two tiles is kept once (intersection over 80 % of the smaller box). 1×1 is the whole frame, unchanged.
struct PlayerTiling: Equatable, Sendable {
    var cols = 1
    var rows = 1
    var overlap = 0.15

    var described: [String: String] {
        ["tiles": "\(cols)x\(rows)", "overlap": "\(overlap)",
         "merge": cols * rows == 1 ? "none" : "IoU 0.6, and across tiles intersection > 0.8 of the smaller box; unpaired poses deduplicated by bounds IoU 0.5"]
    }

    /// The tile rectangles in pixels, top-left origin.
    func tiles(width: Int, height: Int) -> [CGRect] {
        func spans(_ total: Double, _ n: Int) -> [(Double, Double)] {
            guard n > 1 else { return [(0, total)] }
            let size = total / (Double(n) - Double(n - 1) * overlap)
            let step = size * (1 - overlap)
            return (0..<n).map { i in (min(Double(i) * step, total - size), size) }
        }
        return spans(Double(height), rows).flatMap { y in spans(Double(width), cols).map { x in
            CGRect(x: x.0, y: y.0, width: x.1, height: y.1).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        } }
    }

    func detect(_ image: CGImage, with detector: PlayerDetector) -> PlayerDetections {
        guard cols * rows > 1 else { return detector.detect(image) }
        let W = Double(image.width), H = Double(image.height)
        var all: [PlayerDetections.Person] = [], source: [Int] = [], poses: [PlayerFeatures.Pose] = []
        var merged = PlayerDetections()
        for (t, rect) in tiles(width: image.width, height: image.height).enumerated() {
            guard let tile = image.cropping(to: rect) else { continue }
            let d = detector.detect(tile)
            merged.rectFailed = merged.rectFailed || d.rectFailed
            merged.poseFailed = merged.poseFailed || d.poseFailed
            for (k, v) in d.ms { merged.ms[k, default: 0] += v }
            // Tile-normalised (bottom-left origin) → frame-normalised.
            let tx = Double(rect.minX), tyBottom = H - Double(rect.maxY), tw = Double(rect.width), th = Double(rect.height)
            func box(_ b: PlayerFeatures.Box) -> PlayerFeatures.Box {
                PlayerFeatures.Box(x: (tx + b.x * tw) / W, y: (tyBottom + b.y * th) / H, w: b.w * tw / W, h: b.h * th / H)
            }
            func pose(_ p: PlayerFeatures.Pose) -> PlayerFeatures.Pose {
                PlayerFeatures.Pose(conf: p.conf, joints: p.joints.map { $0.map { PlayerFeatures.Joint(x: (tx + $0.x * tw) / W, y: (tyBottom + $0.y * th) / H, c: $0.c) } })
            }
            for p in d.persons {
                all.append(.init(box: box(p.box), conf: p.conf, pose: p.pose.map(pose)))
                source.append(t)
            }
            poses += d.unpairedPoses.map(pose)
        }
        let kept = PlayerDetections.suppress(all, iou: 0.6, containment: 0.8, fromOtherSource: { source[$0] != source[$1] })
        merged.persons = kept.map { all[$0] }
        let taken = merged.persons.compactMap { $0.pose?.bounds }
        var free: [PlayerFeatures.Pose] = []
        for p in poses.sorted(by: { $0.conf > $1.conf }) {
            guard let b = p.bounds else { continue }
            if taken.contains(where: { $0.iou(b) > 0.5 }) || free.contains(where: { ($0.bounds?.iou(b) ?? 0) > 0.5 }) { continue }
            free.append(p)
        }
        merged.unpairedPoses = free
        return merged
    }
}
