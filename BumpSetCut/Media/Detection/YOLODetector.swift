//
//  YOLODetector.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import Vision
import CoreMedia
import CoreML

final class YOLODetector {
    private var model: VNCoreMLModel?
    private var didLogLabels = false
    
    init() {
        loadModel()
    }
    
    private func loadModel() {
        // Prefer .mlpackage; fall back to .mlmodelc if present
        let candidates: [(String, String)] = [
            ("best", "mlpackage"),
            ("best", "mlmodelc")
        ]
        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                do {
                    let cfg = MLModelConfiguration()
                    cfg.computeUnits = .all   // Use ANE/GPU if available
                    let mlModel = try MLModel(contentsOf: url, configuration: cfg)
                    let vnModel = try VNCoreMLModel(for: mlModel)
                    vnModel.inputImageFeatureName = vnModel.inputImageFeatureName // no-op to silence unused warnings if needed
                    self.model = vnModel
                    print("✅ Loaded CoreML model: \(name).\(ext) [computeUnits=.all]")
                    return
                } catch {
                    print("⚠️ Failed to load \(name).\(ext): \(error)")
                }
            }
        }
        print("❌ No CoreML model found in bundle (expected best.mlpackage or best.mlmodelc)")
    }
    
    /// Returns only "volleyball" detections from the model.
    func detect(in pixelBuffer: CVPixelBuffer, at time: CMTime) -> [DetectionResult] {
        guard let model = model else { return [] }
        
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        request.preferBackgroundProcessing = true
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("⚠️ Vision perform failed: \(error)")
            return []
        }
        
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
        
        // Strict filter: keep only the volleyball class
        return results.compactMap { (obs) -> DetectionResult? in
            guard let top = obs.labels.first else { return nil }
            let ident = top.identifier.lowercased()
            let minConfidence: VNConfidence = 0.70
            guard ident == "volleyball", top.confidence >= minConfidence else { return nil }
            return DetectionResult(
                bbox: obs.boundingBox,
                confidence: top.confidence,
                timestamp: time
            )
        }
    }
}
