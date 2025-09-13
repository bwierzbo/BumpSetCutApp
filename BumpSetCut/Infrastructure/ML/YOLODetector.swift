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

    private struct StaticCell {
        var lastPoint: CGPoint
        var lastTimeSec: Double
        var streak: Int
        var cooldownUntilSec: Double
    }
    private var staticCells: [Int: StaticCell] = [:]

    init() {
        loadModel()
    }
    
    private func loadModel() {
        // Prefer mlpackage; fall back to mlmodelc if present
        let candidates: [(String, String)] = [
            ("bestv2", "mlpackage"),
            ("bestv2", "mlmodelc")
        ]
        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                do {
                    let cfg = MLModelConfiguration()
                    cfg.computeUnits = .all   // Use ANE/GPU if available
                    let mlModel = try MLModel(contentsOf: url, configuration: cfg)
                    let vnModel = try VNCoreMLModel(for: mlModel)
                    // Let VNCoreMLModel auto-detect the image input feature
                    self.model = vnModel
                    print("✅ Loaded CoreML model: \(name).\(ext) [computeUnits=.all]")
                    return
                } catch {
                    print("⚠️ Failed to load \(name).\(ext): \(error)")
                }
            }
        }
        print("❌ No CoreML model found in bundle (expected bestv2.mlpackage or bestv2.mlmodelc)")
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
        
        // Vision request completed successfully
        
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
        
        #if DEBUG
        if !didLogLabels {
            let labels = Set(results.compactMap { $0.labels.first?.identifier.lowercased() })
            if !labels.isEmpty {
                print("🔎 YOLO unique labels seen: \(labels)")
                didLogLabels = true
            }
        }
        #endif
        
        // Strict label + confidence filter
        let base: [DetectionResult] = results.compactMap { (obs) -> DetectionResult? in
            guard let top = obs.labels.first else { return nil }
            let ident = top.identifier.lowercased()
            let minConfidence: VNConfidence = 0.70
            guard ident == "volleyball", top.confidence >= minConfidence else { return nil }
            return DetectionResult(bbox: obs.boundingBox, confidence: top.confidence, timestamp: time)
        }
        
        if base.isEmpty { return [] }
        
        // 1) Same-frame de-duplication: cluster by center distance and keep highest confidence
        let deduped = dedupeByCenter(base, radius: nmsMergeRadius)
        
        // 2) Static-object suppression: drop cells that have repeated "no-motion" hits
        let nowSec = time.seconds
        let filtered = suppressStatic(deduped, nowSec: nowSec)
        
        return filtered
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

            if dist < staticEps {
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
