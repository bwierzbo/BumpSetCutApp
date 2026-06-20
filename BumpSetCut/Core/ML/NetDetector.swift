//
//  NetDetector.swift
//  BumpSetCut
//
//  Runs the single-class "net" CoreML model (net.mlpackage) on a frame and returns
//  net bounding boxes. Deliberately leaner than YOLODetector: the net is STATIONARY,
//  so there is NO static-object suppression (which would erase it). Shares the
//  raw-tensor decode with the ball detector via decodeYOLORaw.
//

import CoreGraphics
import CoreML
import Vision

final class NetDetector {
    private var model: VNCoreMLModel?
    private var modelInputWidth: CGFloat = 640
    private var modelInputHeight: CGFloat = 640

    /// Minimum confidence to keep a net detection.
    var minConfidence: Float = 0.5
    /// Letterbox frames into the model (`.scaleFit`) instead of stretching
    /// (`.scaleFill`). Default false (stretch) — the net model was trained on
    /// stretched inputs, which yields a tight box; letterbox inflates it vertically.
    var useScaleFitLetterbox: Bool = false

    init(modelName: String = "net") {
        loadModel(modelName)
    }

    private func loadModel(_ modelName: String) {
        for ext in ["mlpackage", "mlmodelc"] {
            guard let url = Bundle.main.url(forResource: modelName, withExtension: ext) else { continue }
            do {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .all
                let mlModel = try MLModel(contentsOf: url, configuration: cfg)
                self.model = try VNCoreMLModel(for: mlModel)
                if let c = mlModel.modelDescription.inputDescriptionsByName.values
                    .first(where: { $0.type == .image })?.imageConstraint {
                    self.modelInputWidth = CGFloat(c.pixelsWide)
                    self.modelInputHeight = CGFloat(c.pixelsHigh)
                }
                print("✅ Loaded net model: \(modelName).\(ext) [input=\(Int(modelInputWidth))x\(Int(modelInputHeight))]")
                return
            } catch {
                print("⚠️ Failed to load net model \(modelName).\(ext): \(error)")
            }
        }
        print("⚠️ Net model '\(modelName)' not found in bundle.")
    }

    var isLoaded: Bool { model != nil }

    /// Detect nets in an upright CGImage. Returns Vision-normalized boxes (origin
    /// bottom-left, [0,1]) sorted by descending confidence, deduped with NMS.
    func detect(in cgImage: CGImage) -> [(rect: CGRect, confidence: Float)] {
        guard let model = model else { return [] }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = useScaleFitLetterbox ? .scaleFit : .scaleFill
        let srcSize = CGSize(width: cgImage.width, height: cgImage.height)

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("⚠️ Net Vision perform failed: \(error)")
            return []
        }

        let decoded: [(rect: CGRect, confidence: Float)]
        if let recognized = request.results as? [VNRecognizedObjectObservation], !recognized.isEmpty {
            decoded = recognized.compactMap { obs in
                guard let top = obs.labels.first, top.confidence >= minConfidence else { return nil }
                return (rect: obs.boundingBox, confidence: obs.confidence)
            }
        } else if let feature = request.results?
                    .first(where: { $0 is VNCoreMLFeatureValueObservation }) as? VNCoreMLFeatureValueObservation,
                  let array = feature.featureValue.multiArrayValue {
            decoded = decodeYOLORaw(array,
                                    inputSize: CGSize(width: modelInputWidth, height: modelInputHeight),
                                    srcSize: srcSize, letterbox: useScaleFitLetterbox,
                                    minConfidence: minConfidence)
        } else {
            decoded = []
        }

        return nonMaxSuppress(decoded)
    }

    /// Greedy NMS by IoU — collapses the raw model's overlapping anchors into
    /// distinct net boxes, highest confidence first.
    private func nonMaxSuppress(_ dets: [(rect: CGRect, confidence: Float)],
                                iouThreshold: CGFloat = 0.45) -> [(rect: CGRect, confidence: Float)] {
        let sorted = dets.sorted { $0.confidence > $1.confidence }
        var kept: [(rect: CGRect, confidence: Float)] = []
        for d in sorted where kept.allSatisfy({ iou($0.rect, d.rect) < iouThreshold }) {
            kept.append(d)
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
