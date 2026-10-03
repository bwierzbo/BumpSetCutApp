//
//  HeatmapVideo.swift
//  RallyLab
//
//  A side-by-side video of a tracked rally: YOLO's boxes on the left, the
//  multi-frame model's heatmap and its trail of peaks on the right, at half
//  speed — to see what each finds and misses.
//

import AVFoundation
import CoreGraphics
import CoreText
import Foundation

enum HeatmapVideo {

    struct Failure: Error { let message: String }

    /// Each half is this wide; height follows the video.
    static let halfWidth = 960

    static func render(video: URL, times: [Double], title: String, heatModel: URL, yolo: URL?, to output: URL,
                       progress: @escaping @Sendable (Int, Int) -> Void) async -> Swift.Result<URL, Failure> {
        guard let heat = HeatmapBallDetector(modelURL: heatModel) else {
            return .failure(Failure(message: "Couldn't load \(heatModel.lastPathComponent)."))
        }
        let detector = SamplerModel.detector(model: yolo, confidence: Float(ProcessorConfig().detectionConfidence))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)

        // Read every frame once (grays for the model, the picture for drawing).
        var images: [CGImage] = []
        var grays: [HeatmapBallDetector.Frame] = []
        for await result in generator.images(for: times.map(TrackFrameStore.request)) {
            guard let image = try? result.image, let gray = heat.grayscale(image) else { continue }
            images.append(image)
            grays.append(gray)
        }
        guard let first = images.first else { return .failure(Failure(message: "Couldn't read the rally's frames.")) }
        let halfHeight = Int((Double(halfWidth) * Double(first.height) / Double(first.width)).rounded() / 2) * 2
        let size = CGSize(width: halfWidth * 2, height: halfHeight)

        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
            return .failure(Failure(message: "Couldn't write \(output.path)."))
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let n = images.count, half = heat.seq / 2
        var trail: [[CGPoint]] = []
        for i in 0..<n {
            let window = (i - half...i + half).map { grays[min(max(0, $0), n - 1)] }
            guard let found = heat.detect(in: window, target: half) else { continue }
            let peaks = found.peaks
            let heatmap = overlay(found.heat, width: heat.width, height: heat.height, portrait: window[half].portrait)
            let boxes = detector.detect(in: images[i], at: .zero).map(\.bbox)
            trail.append(peaks.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) })

            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let buffer = pixelBuffer
            else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let left = CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight)
                let right = CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight)
                ctx.draw(images[i], in: left)
                ctx.draw(images[i], in: right)
                // YOLO boxes (Vision rects are bottom-up, like CG).
                ctx.setStrokeColor(CGColor(red: 1, green: 0.78, blue: 0, alpha: 1))
                ctx.setLineWidth(2.5)
                for b in boxes {
                    ctx.stroke(CGRect(x: b.minX * left.width - 3, y: b.minY * left.height - 3,
                                      width: b.width * left.width + 6, height: b.height * left.height + 6))
                }
                // The heatmap, then the trail and the current peaks.
                if let heatmap { ctx.draw(heatmap, in: right) }
                for (k, points) in trail.suffix(15).enumerated() {
                    ctx.setFillColor(CGColor(red: 0, green: 1, blue: 1, alpha: 0.35 + 0.04 * CGFloat(k)))
                    for p in points {
                        ctx.fillEllipse(in: CGRect(x: right.minX + p.x * right.width - 3, y: p.y * right.height - 3, width: 6, height: 6))
                    }
                }
                ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 1, alpha: 1))
                for p in trail[i] {
                    ctx.strokeEllipse(in: CGRect(x: right.minX + p.x * right.width - 14, y: p.y * right.height - 14, width: 28, height: 28))
                }
                label(ctx, "YOLO (single frame), app threshold", at: CGPoint(x: 10, y: CGFloat(halfHeight) - 28))
                label(ctx, "Multi-frame model (9 frames)", at: CGPoint(x: CGFloat(halfWidth) + 10, y: CGFloat(halfHeight) - 28))
                label(ctx, title, at: CGPoint(x: CGFloat(halfWidth) + 10, y: 10), size: 14)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            // Half speed: 15 fps for frames ~1/30 s apart.
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 15))
            if i % 10 == 0 { progress(i, n) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? .success(output)
            : .failure(Failure(message: "Writing the video failed: \(writer.error?.localizedDescription ?? "unknown")"))
    }

    /// The heatmap as a picture to lay over the frame: transparent where
    /// it's 0, blue → green → yellow → red as it rises, turned back upright
    /// for portrait (the model saw it a quarter turn clockwise).
    private static func overlay(_ heat: [Float], width: Int, height: Int, portrait: Bool) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = min(max(heat[i], 0), 1)
            guard v > 0.03 else { continue }
            let (r, g, b): (Float, Float, Float) = v < 0.5 ? (0, v * 2, 1 - v * 2) : ((v - 0.5) * 2, 1 - (v - 0.5) * 2, 0)
            let a = min(v * 1.6, 0.75)
            rgba[i * 4] = UInt8(r * a * 255); rgba[i * 4 + 1] = UInt8(g * a * 255)
            rgba[i * 4 + 2] = UInt8(b * a * 255); rgba[i * 4 + 3] = UInt8(a * 255)
        }
        guard let model = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = model.makeImage() else { return nil }
        guard portrait else { return image }
        // Undo the quarter turn: draw it a quarter turn anticlockwise into a portrait canvas.
        guard let upright = CGContext(data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        upright.translateBy(x: CGFloat(height), y: 0)
        upright.rotate(by: .pi / 2)
        upright.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return upright.makeImage()
    }

    private static func label(_ ctx: CGContext, _ text: String, at point: CGPoint, size: CGFloat = 18) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
        ctx.fill(CGRect(x: point.x - 6, y: point.y - 6, width: bounds.width + 12, height: bounds.height + 12))
        ctx.textPosition = CGPoint(x: point.x, y: point.y + 2)
        CTLineDraw(line, ctx)
    }
}
