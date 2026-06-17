//
//  YOLODetector.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import Vision
import CoreMedia
import CoreML
import CoreGraphics

/// Runs the CoreML model and applies same-frame de-duplication + static-object suppression
/// so stationary "ball-like" objects don't hijack tracking.
final class YOLODetector {
    private var model: VNCoreMLModel?
    private var didLogLabels = false

    // --- Same-frame de-dupe & static suppressor tunables (normalized units) ---
    // Keep these local to avoid changing other files; we can move to ProcessorConfig if needed.
    private let nmsMergeRadius: CGFloat = 0.02      // cluster detections within 2% of frame
    private let staticEps: CGFloat = 0.01           // consider "same place" within 1% of frame
    private let staticMinStreak: Int = 8            // consecutive frames before muting a cell
    private let staticCooldownSec: Double = 10.0    // suppress that cell for this long
    private let grid: Int = 96                      // quantization grid for static map

    private let modelName: String

    /// Minimum confidence for a "volleyball" detection. Defaults to the
    /// historical hard-coded value; VideoProcessor overrides it from
    /// ProcessorConfig.detectionConfidence so it can be tuned per run.
    var minConfidence: VNConfidence = 0.70

    private struct StaticCell {
        var lastPoint: CGPoint
        var lastTimeSec: Double
        var streak: Int
        var cooldownUntilSec: Double
    }
    private var staticCells: [Int: StaticCell] = [:]

    /// Model input pixel size, read at load. Used to normalize raw-tensor boxes
    /// that come back in input-pixel coordinates.
    private var modelInputWidth: CGFloat = 960
    private var modelInputHeight: CGFloat = 960

    init(modelName: String = "bestv3") {
        self.modelName = modelName
        loadModel()
    }

    private func loadModel() {
        // Prefer mlpackage; fall back to mlmodelc if present.
        // Try the requested model first, then fall back to known bundled models.
        var candidates: [(String, String)] = [
            (modelName, "mlpackage"),
            (modelName, "mlmodelc")
        ]
        for fallback in ["bestv3", "bestv2"] where modelName != fallback {
            candidates.append((fallback, "mlpackage"))
            candidates.append((fallback, "mlmodelc"))
        }
        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                do {
                    let cfg = MLModelConfiguration()
                    cfg.computeUnits = .all   // Use ANE/GPU if available
                    let mlModel = try MLModel(contentsOf: url, configuration: cfg)
                    let vnModel = try VNCoreMLModel(for: mlModel)
                    // Let VNCoreMLModel auto-detect the image input feature
                    self.model = vnModel
                    if let imgConstraint = mlModel.modelDescription.inputDescriptionsByName.values
                        .first(where: { $0.type == .image })?.imageConstraint {
                        self.modelInputWidth = CGFloat(imgConstraint.pixelsWide)
                        self.modelInputHeight = CGFloat(imgConstraint.pixelsHigh)
                    }
                    print("✅ Loaded CoreML model: \(name).\(ext) [computeUnits=.all, input=\(Int(modelInputWidth))x\(Int(modelInputHeight))]")
                    return
                } catch {
                    print("⚠️ Failed to load \(name).\(ext): \(error)")
                }
            }
        }
        print("❌ No CoreML model found in bundle (tried \(modelName), fallback bestv2)")
        print("ℹ️  AI video processing will be disabled. To enable:")
        print("   1. Add bestv2.mlpackage or bestv2.mlmodelc to the Xcode project bundle")
        print("   2. Ensure the model is included in the target and bundle resources") 
        print("   3. The model should be a YOLO volleyball detection model")
    }
    
    /// Returns only "volleyball" detections from the model, after de-dupe and static suppression.
    func detect(in pixelBuffer: CVPixelBuffer, at time: CMTime) -> [DetectionResult] {
        guard let model = model else { return [] }
        
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        request.preferBackgroundProcessing = false
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("⚠️ Vision perform failed: \(error)")
            return []
        }
        
        // Two output formats:
        //  • bestv2/best export the Vision-native object-detection pipeline
        //    (confidence + coordinates outputs) → VNRecognizedObjectObservation.
        //  • bestv3 (YOLOv26) exports a single raw tensor (1×N×6, no NMS pipeline)
        //    → VNCoreMLFeatureValueObservation, which we decode by hand.
        let base: [DetectionResult]
        if let recognized = request.results as? [VNRecognizedObjectObservation], !recognized.isEmpty {
            base = recognizedDetections(recognized, time: time)
        } else if let feature = request.results?
                    .first(where: { $0 is VNCoreMLFeatureValueObservation }) as? VNCoreMLFeatureValueObservation,
                  let array = feature.featureValue.multiArrayValue {
            base = decodeRawDetections(array, time: time)
        } else {
            return []
        }

        if base.isEmpty { return [] }
        
        // 1) Same-frame de-duplication: cluster by center distance and keep highest confidence
        let deduped = dedupeByCenter(base, radius: nmsMergeRadius)
        
        // 2) Static-object suppression: drop cells that have repeated "no-motion" hits
        let nowSec = time.seconds
        let filtered = suppressStatic(deduped, nowSec: nowSec)
        
        return filtered
    }

    // MARK: - Output decoding

    /// Vision-native object-detection results (bestv2/best). The kept value is the
    /// observation's detection confidence (objectness); the class confidence
    /// saturates near 1.0 on a single-class model. Accepts either label name.
    private func recognizedDetections(_ results: [VNRecognizedObjectObservation], time: CMTime) -> [DetectionResult] {
        #if DEBUG
        if !didLogLabels {
            let labels = Set(results.compactMap { $0.labels.first?.identifier.lowercased() })
            if !labels.isEmpty { print("🔎 YOLO labels (Vision): \(labels)"); didLogLabels = true }
        }
        #endif
        let ballLabels: Set<String> = ["volleyball", "ball"]
        return results.compactMap { obs in
            guard let top = obs.labels.first, ballLabels.contains(top.identifier.lowercased()),
                  top.confidence >= minConfidence else { return nil }
            return DetectionResult(bbox: obs.boundingBox, confidence: obs.confidence, timestamp: time)
        }
    }

    /// Decode a raw YOLO tensor output (bestv3 / YOLOv26, no NMS pipeline).
    /// Expected shape [1, N, 6] with each row [x1, y1, x2, y2, confidence, class]
    /// in the model's input pixel space, top-left origin. Converts to
    /// Vision-normalized bottom-left bboxes so the rest of the pipeline is unchanged.
    private func decodeRawDetections(_ array: MLMultiArray, time: CMTime) -> [DetectionResult] {
        guard array.dataType == .float32, array.shape.count == 3 else { return [] }
        let n = array.shape[1].intValue
        let cols = array.shape[2].intValue
        guard cols >= 6, n > 0 else { return [] }
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)

        var out: [DetectionResult] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let b = i * cols
            let x1 = ptr[b + 0], y1 = ptr[b + 1], x2 = ptr[b + 2], y2 = ptr[b + 3]
            let conf = ptr[b + 4]
            guard conf >= minConfidence, x2 > x1, y2 > y1 else { continue }
            // Coords may be normalized [0,1] or in input pixels — detect by scale.
            let isNormalized = max(max(x1, y1), max(x2, y2)) <= 1.5
            let sx = isNormalized ? 1 : Float(modelInputWidth)
            let sy = isNormalized ? 1 : Float(modelInputHeight)
            let nx1 = x1 / sx, nx2 = x2 / sx, ny1 = y1 / sy, ny2 = y2 / sy
            // YOLO top-left (y down) → Vision bottom-left (y up).
            let rect = CGRect(x: CGFloat(nx1), y: CGFloat(1 - ny2),
                              width: CGFloat(nx2 - nx1), height: CGFloat(ny2 - ny1))
            out.append(DetectionResult(bbox: rect, confidence: conf, timestamp: time))
        }
        #if DEBUG
        if !didLogLabels {
            let sample = (0..<min(n, 1)).map { i -> String in
                let b = i * cols
                return (0..<cols).map { String(format: "%.3f", ptr[b + $0]) }.joined(separator: ",")
            }.joined()
            print("🔎 Raw YOLO decode: shape=\(array.shape), kept=\(out.count); row0=[\(sample)]")
            didLogLabels = true
        }
        #endif
        return out
    }

    // MARK: - Helpers

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func dedupeByCenter(_ dets: [DetectionResult], radius: CGFloat) -> [DetectionResult] {
        var kept: [DetectionResult] = []
        // highest confidence first
        let sorted = dets.sorted { $0.confidence > $1.confidence }
        for d in sorted {
            let c = center(of: d.bbox)
            var tooClose = false
            for k in kept {
                if distance(center(of: k.bbox), c) <= radius {
                    tooClose = true
                    break
                }
            }
            if !tooClose { kept.append(d) }
        }
        return kept
    }

    private func cellKey(for p: CGPoint) -> Int {
        let gx = max(0, min(grid - 1, Int((p.x * CGFloat(grid)).rounded(.down))))
        let gy = max(0, min(grid - 1, Int((p.y * CGFloat(grid)).rounded(.down))))
        return gy * grid + gx
    }

    private func suppressStatic(_ dets: [DetectionResult], nowSec: Double) -> [DetectionResult] {
        var out: [DetectionResult] = []
        for d in dets {
            let c = center(of: d.bbox)
            let key = cellKey(for: c)
            var cell = staticCells[key] ?? StaticCell(lastPoint: c, lastTimeSec: nowSec, streak: 0, cooldownUntilSec: 0)

            // If this cell is under cooldown, suppress
            if nowSec < cell.cooldownUntilSec {
                // Update last seen info and continue suppressing
                cell.lastPoint = c
                cell.lastTimeSec = nowSec
                staticCells[key] = cell
                continue
            }

            // Measure motion vs the last time we saw this cell
            let dist = distance(cell.lastPoint, c)
            let timeDelta = nowSec - cell.lastTimeSec
            let velocity = timeDelta > 0 ? Double(dist) / timeDelta : 0

            // Only count as static if BOTH low distance AND low velocity
            // A fast-moving ball passing through shouldn't be suppressed
            let velocityThreshold: Double = 0.05  // normalized units per second
            if dist < staticEps && velocity < velocityThreshold {
                cell.streak += 1
            } else {
                cell.streak = 0
            }

            cell.lastPoint = c
            cell.lastTimeSec = nowSec

            if cell.streak >= staticMinStreak {
                // Enter cooldown: treat this location as static for a while
                cell.cooldownUntilSec = nowSec + staticCooldownSec
                staticCells[key] = cell
                continue // suppress current detection too
            }

            staticCells[key] = cell
            out.append(d)
        }
        return out
    }
}
