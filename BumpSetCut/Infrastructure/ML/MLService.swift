//
//  MLService.swift
//  BumpSetCut
//
//  Created by Infrastructure Layer on 9/1/25.
//

import Foundation
import Vision
import CoreML
import CoreMedia
import CoreGraphics

/// Infrastructure layer wrapper for machine learning functionality
/// Isolates CoreML/Vision framework usage from the domain layer
final class MLService {
    
    /// Configuration for ML model
    struct ModelConfig {
        let computeUnits: MLComputeUnits
        let confidence: Float
        let targetLabel: String
        
        static let defaultVolleyball = ModelConfig(
            computeUnits: .all,
            confidence: 0.70,
            targetLabel: "volleyball"
        )
    }
    
    /// Detection result from ML model
    struct DetectionResult {
        let bbox: CGRect
        let confidence: Float
        let timestamp: CMTime
        let label: String
    }
    
    private var model: VNCoreMLModel?
    private var config: ModelConfig
    private var didLogLabels = false
    
    init(config: ModelConfig = .defaultVolleyball) {
        self.config = config
        loadModel()
    }
    
    /// Load CoreML model from bundle
    private func loadModel() {
        // Prefer mlpackage; fall back to mlmodelc if present
        let candidates: [(String, String)] = [
            ("bestv2", "mlpackage"),
            ("bestv2", "mlmodelc")
        ]
        
        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                do {
                    let mlConfig = MLModelConfiguration()
                    mlConfig.computeUnits = config.computeUnits
                    let mlModel = try MLModel(contentsOf: url, configuration: mlConfig)
                    let vnModel = try VNCoreMLModel(for: mlModel)
                    self.model = vnModel
                    print("✅ Loaded CoreML model: \(name).\(ext) [computeUnits=\(config.computeUnits)]")
                    return
                } catch {
                    print("⚠️ Failed to load \(name).\(ext): \(error)")
                }
            }
        }
        print("❌ No CoreML model found in bundle (expected best*.mlpackage or *.mlmodelc)")
    }
    
    /// Perform object detection on pixel buffer
    func detectObjects(in pixelBuffer: CVPixelBuffer, at time: CMTime) -> [DetectionResult] {
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
                print("🔎 ML unique labels seen: \(labels)")
                didLogLabels = true
            }
        }
        #endif
        
        // Filter by label and confidence
        let filtered: [DetectionResult] = results.compactMap { (obs) -> DetectionResult? in
            guard let top = obs.labels.first else { return nil }
            let ident = top.identifier.lowercased()
            guard ident == config.targetLabel.lowercased(),
                  top.confidence >= config.confidence else { return nil }
            
            return DetectionResult(
                bbox: obs.boundingBox,
                confidence: top.confidence,
                timestamp: time,
                label: ident
            )
        }
        
        return filtered
    }
    
    /// Update model configuration
    func updateConfig(_ newConfig: ModelConfig) {
        self.config = newConfig
        // Reload model if compute units changed
        loadModel()
    }
}

/// ML-related errors
enum MLServiceError: Error {
    case modelLoadFailed
    case detectionFailed
    case invalidConfiguration
}