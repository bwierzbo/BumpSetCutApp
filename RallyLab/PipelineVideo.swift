//
//  PipelineVideo.swift
//  RallyLab
//
//  A stretch of a video with what the pipeline saw drawn over it, from the
//  evidence a run recorded: every ball found (YOLO yellow, multi-frame cyan,
//  off-court grey) with its confidence, the tracked ball's trail (red, green
//  while the ballistics gate accepts it as a projectile), the net, the gate's
//  readout, and whether the frame is in a clip the pipeline cut and in a
//  rally you marked. Real time, at the source frame rate.
//
//  Headless: RallyLab --project <name> --render-pipeline <clip> <start s> <length s>
//            [--heat <multi-frame model> [--heat-only]] [--rotate]
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

enum PipelineVideo {

    /// Output width; height follows the video.
    static let width = 1280
    /// Seconds of trail behind the ball.
    static let trailSeconds = 1.0

    static func render(_ v: RallyCutScore.Video, video: URL, from start: Double, length: Double,
                       title: String, to output: URL) async -> Swift.Result<URL, HeatmapVideo.Failure> {
        func fail(_ m: String) -> Swift.Result<URL, HeatmapVideo.Failure> { .failure(HeatmapVideo.Failure(message: m)) }
        let asset = AVURLAsset(url: video)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let reader = try? AVAssetReader(asset: asset) else { return fail("Couldn't read \(video.lastPathComponent).") }
        // Frames as stored, as the pipeline reads them, then turned upright;
        // evidence recorded without --rotate is turned upright to match.
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        let orientation = VideoFrameGeometry.orientation(for: transform)
        let turn: CGImagePropertyOrientation = (v.evidence.first?.upright ?? false) ? .up : orientation
        let stored = CGSize(width: abs(natural.width), height: abs(natural.height))
        let sideways = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let drawn = sideways ? CGSize(width: stored.height, height: stored.width) : stored
        let size = CGSize(width: width, height: Int((CGFloat(width) * drawn.height / drawn.width / 2).rounded()) * 2)

        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return fail("Couldn't write \(output.path).") }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { return fail("Couldn't start reading or writing.") }
        writer.startSession(atSourceTime: .zero)
        defer { reader.cancelReading() }

        let evidence = v.evidence
        var e = 0   // evidence[e] is the newest processed frame at or before this one
        while let sbuf = out.copyNextSampleBuffer() {
            guard let pix = CMSampleBufferGetImageBuffer(sbuf) else { continue }
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sbuf))
            while e + 1 < evidence.count, evidence[e + 1].time <= t + 0.0005 { e += 1 }
            let now = evidence.indices.contains(e) && evidence[e].time <= t + 0.0005 ? evidence[e] : nil

            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
                  let frame = image(pix, orientation: orientation) else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(frame, in: CGRect(origin: .zero, size: size))
                draw(now, trail: evidence[max(0, e - 120)...min(e, evidence.count - 1)].filter { t - $0.time <= trailSeconds },
                     at: t, video: v, title: title, turn: turn, in: ctx, size: size)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t - start, preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? .success(output)
            : fail("Writing the video failed: \(writer.error?.localizedDescription ?? "unknown")")
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private static func image(_ pix: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pix).oriented(orientation)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    private static func draw(_ now: VideoProcessor.FrameEvidence?, trail: [VideoProcessor.FrameEvidence], at t: Double,
                             video v: RallyCutScore.Video, title: String, turn: CGImagePropertyOrientation,
                             in ctx: CGContext, size: CGSize) {
        // Vision-normalised (origin bottom-left), turned upright → output
        // pixels; CG is y-up too.
        func px(_ r: CGRect) -> CGRect {
            let r = VideoFrameGeometry.upright(r, from: turn)
            return CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        func px(_ p: CGPoint) -> CGPoint {
            let r = px(CGRect(x: p.x, y: p.y, width: 0, height: 0))
            return CGPoint(x: r.midX, y: r.midY)
        }

        if let net = now?.detectedNet {
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.7))
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [8, 6])
            ctx.stroke(px(net.box))
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Trail: red, green where the gate accepted a projectile.
        let points = trail.compactMap { e in e.trackPoint.map { (px($0), e.isProjectile) } }
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        for (a, b) in zip(points, points.dropFirst()) {
            ctx.setStrokeColor(b.1 ? CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 0.9) : CGColor(red: 1, green: 0.25, blue: 0.2, alpha: 0.9))
            ctx.strokeLineSegments(between: [a.0, b.0])
        }

        for d in now?.detections ?? [] {
            let r = px(d.bbox).insetBy(dx: -6, dy: -6)
            let color = d.isOffCourt ? CGColor(gray: 0.6, alpha: 0.8)
                : d.fromHeatmap ? CGColor(red: 0, green: 0.9, blue: 1, alpha: 1)
                : CGColor(red: 1, green: 0.8, blue: 0, alpha: 1)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(3)
            if d.fromHeatmap { ctx.strokeEllipse(in: r) } else { ctx.stroke(r) }
            HeatmapVideo.label(ctx, String(format: "%.2f", d.confidence), at: CGPoint(x: r.maxX + 4, y: r.maxY - 6), size: 13)
        }

        // HUD, top-left down.
        let inClip = v.clips.contains { t >= $0.start && t <= $0.end }
        let inRally = v.truth.contains { t >= $0.start && t <= $0.end }
        var lines = [title, String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))]
        if let now {
            let yolo = now.detections.filter { !$0.fromHeatmap }.count
            let heat = now.detections.count - yolo
            lines.append("balls: \(yolo) YOLO · \(heat) multi-frame")
            var gate = "projectile: \(now.isProjectile ? "YES" : "no")"
            if let r2 = now.rSquared { gate += String(format: " · r² %.2f", r2) }
            if let why = now.rejectionReason { gate += " · \(why)" }
            lines.append(gate)
        }
        for (k, line) in lines.enumerated() {
            HeatmapVideo.label(ctx, line, at: CGPoint(x: 14, y: size.height - 32 - CGFloat(k) * 30), size: k == 0 ? 15 : 17)
        }

        // State bars along the bottom: the pipeline's clip, your marked rally.
        func bar(_ on: Bool, _ text: String, y: CGFloat, _ color: CGColor) {
            ctx.setFillColor(on ? color : CGColor(gray: 0.15, alpha: 0.75))
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: 26))
            HeatmapVideo.label(ctx, text + (on ? "" : " — no"), at: CGPoint(x: 14, y: y + 4), size: 14)
        }
        bar(inClip, "Pipeline clip", y: 30, CGColor(red: 0.1, green: 0.65, blue: 0.25, alpha: 0.85))
        bar(inRally, "Your marked rally", y: 2, CGColor(red: 0.15, green: 0.4, blue: 0.9, alpha: 0.85))
    }
}
