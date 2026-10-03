//
//  HeatmapBallDetector.swift
//  BumpSetCut
//
//  The multi-frame ball detector: a heatmap model (VballNetV4c, trained in
//  RallyLab) that sees 9 consecutive grayscale frames and marks where the
//  ball is in each — by its motion as well as its look, so it finds blurred
//  and far balls a single frame can't, and ignores balls sitting still.
//  Complements YOLODetector, which sees one frame at a time.
//
//  Feed it frames in order with `grayscale(_:)`; ask for the peaks on one
//  frame of a 9-frame window. Portrait frames are turned a quarter turn
//  clockwise to landscape, as in training; peaks come back Vision-normalised
//  (origin bottom-left) in the frame as given.
//

import CoreGraphics
import CoreML
import Accelerate
import CoreVideo
import Foundation
import VideoToolbox

final class HeatmapBallDetector {

    /// One frame, prepared once and reused by every window it's in.
    struct Frame {
        /// Model-size grayscale, 0–1, row-major (already turned if portrait).
        let pixels: [Float]
        let portrait: Bool
    }

    struct Peak {
        /// Vision-normalised (bottom-left origin) box around the ball.
        let rect: CGRect
        /// Heatmap value at the ball, 0–1.
        let confidence: Float
    }

    let seq: Int
    let width: Int
    let height: Int
    var threshold: Float

    private let model: MLModel

    /// `url`: a converted heatmap model (.mlpackage or compiled .mlmodelc).
    init?(modelURL url: URL, computeUnits: MLComputeUnits = .all) {
        do {
            let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
            let config = MLModelConfiguration()
            config.computeUnits = computeUnits
            model = try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            print("❌ Couldn't load heatmap model \(url.lastPathComponent): \(error)")
            return nil
        }
        guard let input = model.modelDescription.inputDescriptionsByName["clip"]?.multiArrayConstraint,
              input.shape.count == 4 else {
            print("❌ \(url.lastPathComponent) has no [1, seq, H, W] \"clip\" input — not a heatmap model")
            return nil
        }
        seq = input.shape[1].intValue
        height = input.shape[2].intValue
        width = input.shape[3].intValue
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        threshold = meta?["threshold"].flatMap(Float.init) ?? 0.5
    }

    /// The frame as the model sees it: turned to landscape if portrait,
    /// stretched to the model size, grayscale 0–1.
    func grayscale(_ image: CGImage) -> Frame? {
        let portrait = image.height > image.width
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        if portrait {
            // A quarter turn clockwise (as cv2.ROTATE_90_CLOCKWISE in training):
            // the image's top edge becomes the right edge, its left edge the top.
            // CG is y-up, so that's −90° about the origin, then up by the height.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.rotate(by: -.pi / 2)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: height, height: width))
        } else {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Frame(pixels: bytes.map { Float($0) / 255 }, portrait: portrait)
    }

    /// The same, straight from a decoded video frame (as stored, like the
    /// processing pipeline reads it). BGRA frames go through vImage on the
    /// frame's own memory — scale, turn portrait, grey (OpenCV's weights, as
    /// in training) — a few times faster than drawing a CGImage; anything
    /// else goes through VideoToolbox.
    func grayscale(_ pixelBuffer: CVPixelBuffer) -> Frame? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            return image.flatMap(grayscale)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcW = CVPixelBufferGetWidth(pixelBuffer), srcH = CVPixelBufferGetHeight(pixelBuffer)
        var src = vImage_Buffer(data: base, height: vImagePixelCount(srcH), width: vImagePixelCount(srcW),
                                rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        let portrait = srcH > srcW
        // Portrait: scale to the model's size turned sideways, then turn a
        // quarter turn clockwise into it.
        let (scaledW, scaledH) = portrait ? (height, width) : (width, height)
        var scaled = [UInt8](repeating: 0, count: scaledW * scaledH * 4)
        let scaledOK: Bool = scaled.withUnsafeMutableBytes { scaledPtr in
            var dst = vImage_Buffer(data: scaledPtr.baseAddress, height: vImagePixelCount(scaledH),
                                    width: vImagePixelCount(scaledW), rowBytes: scaledW * 4)
            return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard scaledOK else { return nil }
        var landscape = scaled
        if portrait {
            let turned: Bool = scaled.withUnsafeMutableBytes { scaledPtr in
                landscape.withUnsafeMutableBytes { outPtr in
                    var input = vImage_Buffer(data: scaledPtr.baseAddress, height: vImagePixelCount(scaledH),
                                              width: vImagePixelCount(scaledW), rowBytes: scaledW * 4)
                    var out = vImage_Buffer(data: outPtr.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * 4)
                    var black: [UInt8] = [0, 0, 0, 0]
                    return vImageRotate90_ARGB8888(&input, &out, UInt8(kRotate90DegreesClockwise), &black,
                                                   vImage_Flags(kvImageNoFlags)) == kvImageNoError
                }
            }
            guard turned else { return nil }
        }
        // BGRA → grey with cv2.COLOR_BGR2GRAY's weights (0.114 B + 0.587 G
        // + 0.299 R), then to 0–1 floats.
        var grey = [UInt8](repeating: 0, count: width * height)
        var pixels = [Float](repeating: 0, count: width * height)
        let converted: Bool = landscape.withUnsafeMutableBytes { bgraPtr in
            grey.withUnsafeMutableBytes { greyPtr in
                pixels.withUnsafeMutableBytes { floatPtr in
                    var bgra = vImage_Buffer(data: bgraPtr.baseAddress, height: vImagePixelCount(height),
                                             width: vImagePixelCount(width), rowBytes: width * 4)
                    var g = vImage_Buffer(data: greyPtr.baseAddress, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width)
                    var f = vImage_Buffer(data: floatPtr.baseAddress, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width * 4)
                    let divisor: Int32 = 4096
                    let matrix: [Int16] = [Int16(0.114 * 4096), Int16(0.587 * 4096), Int16(0.299 * 4096), 0]  // B, G, R, A
                    guard vImageMatrixMultiply_ARGB8888ToPlanar8(&bgra, &g, matrix, divisor, nil, 0,
                                                                 vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
                    return vImageConvert_Planar8toPlanarF(&g, &f, 1, 0, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                }
            }
        }
        guard converted else { return nil }
        return Frame(pixels: pixels, portrait: portrait)
    }

    /// Peaks on frame `target` of `frames` (exactly `seq` of them, in order).
    func peaks(in frames: [Frame], target: Int) -> [Peak] {
        detect(in: frames, target: target)?.peaks ?? []
    }

    /// The peaks and the heatmap itself (model size, row-major, top-down,
    /// in the model's landscape orientation) for frame `target`.
    func detect(in frames: [Frame], target: Int) -> (peaks: [Peak], heat: [Float])? {
        guard frames.count == seq, frames.indices.contains(target),
              let clip = try? MLMultiArray(shape: [1, NSNumber(value: seq), NSNumber(value: height), NSNumber(value: width)],
                                           dataType: .float32)
        else { return nil }
        let plane = width * height
        let input = clip.dataPointer.bindMemory(to: Float.self, capacity: seq * plane)
        for (k, frame) in frames.enumerated() {
            frame.pixels.withUnsafeBufferPointer { src in
                (input + k * plane).update(from: src.baseAddress!, count: plane)
            }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["clip": clip])),
              let maps = out.featureValue(for: "maps")?.multiArrayValue,
              let heat = Self.channel(maps, target, plane: plane),
              let radius = Self.channel(maps, seq + target, plane: plane) else { return nil }
        let peaks = Self.blobs(heat: heat, radius: radius, width: width, height: height,
                               threshold: threshold, portrait: frames[target].portrait)
        return (peaks, heat)
    }

    /// One [H, W] channel of a [1, C, H, W] output, as Floats.
    private static func channel(_ maps: MLMultiArray, _ c: Int, plane: Int) -> [Float]? {
        guard maps.shape.count == 4, c < maps.shape[1].intValue else { return nil }
        let offset = c * maps.strides[1].intValue
        switch maps.dataType {
        case .float32:
            let p = maps.dataPointer.bindMemory(to: Float.self, capacity: maps.count)
            return Array(UnsafeBufferPointer(start: p + offset, count: plane))
        case .float16:
            let p = maps.dataPointer.bindMemory(to: Float16.self, capacity: maps.count)
            return UnsafeBufferPointer(start: p + offset, count: plane).map(Float.init)
        default:
            return (0..<plane).map { maps[offset + $0].floatValue }
        }
    }

    /// Centroids of the 8-connected blobs above `threshold` (2+ pixels), as
    /// in training's scoring, with the radius map read at each.
    private static func blobs(heat: [Float], radius: [Float], width: Int, height: Int,
                              threshold: Float, portrait: Bool) -> [Peak] {
        let plane = width * height
        var label = [Int32](repeating: 0, count: plane)
        var peaks: [Peak] = []
        var next: Int32 = 0
        for start in 0..<plane where label[start] == 0 && heat[start] >= threshold {
            next += 1
            var stack = [start]
            label[start] = next
            var sumX = 0.0, sumY = 0.0, count = 0
            var best: (v: Float, i: Int) = (0, start)
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                sumX += Double(x); sumY += Double(y); count += 1
                let v = heat[i]
                if v > best.v { best = (v, i) }
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let j = ny * width + nx
                        if label[j] == 0 && heat[j] >= threshold {
                            label[j] = next
                            stack.append(j)
                        }
                    }
                }
            }
            guard count >= 2 else { continue }
            // Model pixels → top-left normalised in the model frame.
            let mx = (sumX / Double(count) + 0.5) / Double(width)
            let my = (sumY / Double(count) + 0.5) / Double(height)
            let r = Double(radius[best.i])   // fraction of the model frame's width
            var side = CGSize(width: 2 * r, height: 2 * r * Double(width) / Double(height))
            // Back to the frame as given: undo the quarter turn for portrait.
            var (x, y) = (mx, my)
            if portrait {
                (x, y) = (my, 1 - mx)
                side = CGSize(width: side.height, height: side.width)
            }
            let rect = CGRect(x: x - side.width / 2, y: 1 - y - side.height / 2, width: side.width, height: side.height)
            peaks.append(Peak(rect: rect, confidence: best.v))
        }
        return peaks
    }
}
