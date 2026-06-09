//
//  DebugAnnotator.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25
//

//
//  DebugAnnotator.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25
//

import AVFoundation
import CoreImage
import CoreGraphics
import CoreVideo
import UIKit

/// Writes a full-length annotated video for debugging the AI pipeline.
/// Overlays:
///  - Volleyball detections (yellow boxes)
///  - Dotted blue detection path + solid red verified trajectory
///  - Thin top bar (green when in-rally, red when idle)
///  - HUD text: time, detection count, projectile Y/N, rally Y/N
final class DebugAnnotator {
    struct OverlayFrameData {
        let detections: [DetectionResult]
        let track: KalmanBallTracker.TrackedBall?
        let isProjectile: Bool
        let inRally: Bool
        let time: CMTime
        // Physics validation metrics for the active track (R², confidence, sub-criteria).
        // Pass nil when no track is being validated this frame.
        let validation: BallisticsGate.ValidationResult?
        // Optional: verified trajectory (distinct color). Defaults to nil so existing callers compile.
        let verifiedTrack: KalmanBallTracker.TrackedBall? = nil
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let ciContext = CIContext(options: nil)

    private let frameSize: CGSize
    private let transform: CGAffineTransform
    private let outURL: URL

    private var started = false

    /// Create an annotator. Orientation is preserved via `transform` (usually source track's preferredTransform).
    init(outputURL: URL? = nil, size: CGSize, transform: CGAffineTransform) throws {
        // Normalize to even-sized dimensions (H.264 requirement / avoids reader issues)
        let evenSize = CGSize(width: floor(size.width / 2) * 2,
                              height: floor(size.height / 2) * 2)
        self.frameSize = evenSize
        self.transform = transform

        let url = outputURL ?? DebugAnnotator.makeOutputURL()
        self.outURL = url

        // Configure writer
        self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(evenSize.width),
            AVVideoHeightKey: Int(evenSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, Int(evenSize.width * evenSize.height * 6)), // heuristic
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        self.videoInput.expectsMediaDataInRealTime = false
        self.videoInput.transform = transform

        let srcAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(evenSize.width),
            kCVPixelBufferHeightKey as String: Int(evenSize.height),
            kCVPixelFormatOpenGLESCompatibility as String: true
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: srcAttrs)

        guard writer.canAdd(videoInput) else { throw ProcessingError.compositionFailed }
        writer.add(videoInput)
    }

    func outputURL() -> URL { outURL }

    private static func makeOutputURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("debug_ai_\(UUID().uuidString).mp4")
    }

    /// Append a frame with overlays. Call `finish()` when done.
    func append(sampleBuffer: CMSampleBuffer, overlay data: OverlayFrameData) throws {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = data.time

        // Start the session at the first PTS
        if !started {
            guard writer.startWriting() else { throw writer.error ?? ProcessingError.exportSessionFailed("Debug writer failed to start") }
            writer.startSession(atSourceTime: pts)
            started = true
        }

        // Bounded readiness wait to avoid hangs
        var spins = 0
        while !videoInput.isReadyForMoreMediaData && spins < 250 { // ~0.5s max
            usleep(2_000)
            spins += 1
        }
        if !videoInput.isReadyForMoreMediaData {
            // Drop this frame rather than hang indefinitely
            return
        }

        // Render base frame to CGImage
        let baseCI = CIImage(cvPixelBuffer: imageBuffer)

        // Create a new pixel buffer to draw into
        var outPB: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool else { throw ProcessingError.exportSessionFailed("Debug pixel buffer pool unavailable") }
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
        guard status == kCVReturnSuccess, let pixelBuffer = outPB else { throw ProcessingError.exportSessionFailed("Debug pixel buffer allocation failed") }

        // Render the base image into the output pixel buffer
        ciContext.render(baseCI, to: pixelBuffer)

        // Draw overlays
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let ctx = DebugAnnotator.makeContext(for: pixelBuffer, size: frameSize) {
            DebugAnnotator.drawOverlays(in: ctx, size: frameSize, data: data)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        // Append to writer
        if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
            throw writer.error ?? ProcessingError.exportSessionFailed("Debug frame append failed")
        }

        // Clean up sample buffer to prevent memory accumulation
        CMSampleBufferInvalidate(sampleBuffer)
    }

    /// Finish and return the file URL.
    func finish() async throws -> URL {
        videoInput.markAsFinished()

        // Check if writer is already in a terminal state
        guard writer.status == .writing else {
            if writer.status == .failed {
                throw writer.error ?? ProcessingError.exportSessionFailed("Debug writer in failed state")
            }
            // Already completed or cancelled
            return outURL
        }

        if #available(iOS 18.0, *) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    cont.resume()
                }
            }
        } else {
            writer.finishWriting {}
            while writer.status == .writing {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
        if writer.status == .failed {
            throw writer.error ?? ProcessingError.exportSessionFailed("Debug writer finish failed")
        }
        return outURL
    }

    // MARK: - Drawing helpers

    private static func makeContext(for pixelBuffer: CVPixelBuffer, size: CGSize) -> CGContext? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        return CGContext(data: base,
                         width: Int(size.width),
                         height: Int(size.height),
                         bitsPerComponent: 8,
                         bytesPerRow: bytesPerRow,
                         space: colorSpace,
                         bitmapInfo: bitmapInfo.rawValue)
    }

    private static func drawOverlays(in ctx: CGContext, size: CGSize, data: OverlayFrameData) {
        // Flip to typical top-left origin for drawing text/rects
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Drawing assumes origin at top-left (CoreGraphics default for bitmap contexts)
        // 1) Top bar
        let barHeight: CGFloat = 6
        ctx.setFillColor((data.inRally ? UIColor.systemGreen : UIColor.systemRed).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: barHeight))

        // 2) Detections (Vision bbox: normalized, origin bottom-left → convert)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(UIColor.systemYellow.cgColor)
        for det in data.detections {
            let rect = rectFromVision(bbox: det.bbox, canvas: size)
            ctx.stroke(rect)
        }

        // 3) Path (dotted = detections in blue; solid = verified trajectory in red)
        if let track = data.track {
            let pts = track.positions.suffix(30).map { $0.0 } // last 30 points
            if pts.count >= 2 {
                // Dotted blue: raw detection chain
                ctx.setLineWidth(3)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.setStrokeColor(UIColor.systemBlue.cgColor)
                ctx.beginPath()
                let first = pts.first!
                ctx.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                for p in pts.dropFirst() {
                    ctx.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])

                // Solid red: validated trajectory (when physics gate says projectile)
                if data.isProjectile {
                    ctx.setLineWidth(3)
                    ctx.setStrokeColor(UIColor.systemRed.cgColor)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                    for p in pts.dropFirst() {
                        ctx.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                    }
                    ctx.strokePath()
                }
            }
        }

        // 4) HUD text
        // Flip vertically so text is upright (CoreGraphics origin is top-left, but text draws upside-down)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)

        let font = UIFont.monospacedSystemFont(ofSize: 34, weight: .medium)
        func yn(_ b: Bool) -> UIColor { b ? UIColor.systemGreen : UIColor.systemRed }
        // Map a 0...1 score to red → yellow → green so R²/confidence read at a glance.
        func scoreColor(_ s: Double) -> UIColor {
            let c = max(0, min(1, s))
            return UIColor(red: CGFloat(min(1, 2 * (1 - c))),
                           green: CGFloat(min(1, 2 * c)),
                           blue: 0, alpha: 1)
        }
        // Draw colored tokens left-to-right with a black shadow for legibility.
        func drawTokens(_ tokens: [(String, UIColor)], y: CGFloat) {
            var x: CGFloat = 10
            let gap: CGFloat = 18
            for (text, color) in tokens {
                let ns = NSString(string: text)
                let shadow: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                let main: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                ns.draw(at: CGPoint(x: x + 1, y: y + 1), withAttributes: shadow)
                ns.draw(at: CGPoint(x: x, y: y), withAttributes: main)
                x += ns.size(withAttributes: main).width + gap
            }
        }

        // Line 1 — overall pipeline state.
        drawTokens([
            (String(format: "t=%.2fs", data.time.seconds), .white),
            (String(format: "det=%d", data.detections.count), .white),
            ("proj=\(data.isProjectile ? "Y" : "N")", yn(data.isProjectile)),
            ("rally=\(data.inRally ? "Y" : "N")", yn(data.inRally)),
        ], y: barHeight + 8)

        // Line 2 — physics validation breakdown for the active track.
        if let v = data.validation {
            drawTokens([
                (String(format: "R\u{00B2}=%.2f", v.rSquared), scoreColor(v.rSquared)),
                (String(format: "conf=%.2f", v.confidenceLevel), scoreColor(v.confidenceLevel)),
                ("curve=\(v.curvatureDirectionValid ? "Y" : "N")", yn(v.curvatureDirectionValid)),
                ("motion=\(v.hasMotionEvidence ? "Y" : "N")", yn(v.hasMotionEvidence)),
                ("jump=\(v.positionJumpsValid ? "Y" : "N")", yn(v.positionJumpsValid)),
            ], y: barHeight + 8 + 42)
        } else {
            drawTokens([("R\u{00B2}=--  conf=--  (no track)", .lightGray)], y: barHeight + 8 + 42)
        }

        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    private static func rectFromVision(bbox: CGRect, canvas: CGSize) -> CGRect {
        // Vision bbox: normalized, origin = bottom-left
        let w = bbox.width * canvas.width
        let h = bbox.height * canvas.height
        let x = bbox.minX * canvas.width
        // Treat bbox as top-left oriented to avoid vertical inversion in overlay
        let yTop = bbox.minY * canvas.height
        return CGRect(x: x, y: yTop, width: w, height: h)
    }
}
