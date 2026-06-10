//
//  TestVideoFactory.swift
//  BumpSetCutTests
//
//  Produces REAL, playable H.264 .mp4 files for tests.
//
//  Why this exists: the test suite previously "created" videos by writing the
//  string "test video data" to a .mp4 file. AVFoundation cannot open those, so
//  every frame-extraction / asset-loading test failed with -11829 "Cannot Open",
//  and some then trapped on Int(NaN) when their results array came back empty.
//  This factory writes an actual encoded video so those tests exercise the real
//  code path instead of an unopenable file.
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

enum TestVideoFactory {

    enum FactoryError: Error {
        case writerSetupFailed
        case pixelBufferCreationFailed
        case writeFailed(String)
    }

    /// Write a real H.264 .mp4 to `url`.
    /// - Parameters:
    ///   - url: destination (parent directory must exist).
    ///   - duration: clip length in seconds.
    ///   - size: frame dimensions.
    ///   - fps: frames per second.
    @discardableResult
    static func writeVideo(
        to url: URL,
        duration: Double = 1.0,
        size: CGSize = CGSize(width: 320, height: 240),
        fps: Int32 = 30
    ) throws -> URL {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw FactoryError.writerSetupFailed
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)

        guard writer.canAdd(input) else { throw FactoryError.writerSetupFailed }
        writer.add(input)

        guard writer.startWriting() else {
            throw FactoryError.writeFailed(writer.error?.localizedDescription ?? "startWriting returned false")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(duration * Double(fps)))
        for frameIndex in 0..<totalFrames {
            // Spin until the input is ready (no real-time pressure in tests).
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let buffer = makePixelBuffer(size: size, frameIndex: frameIndex, totalFrames: totalFrames) else {
                throw FactoryError.pixelBufferCreationFailed
            }
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw FactoryError.writeFailed(writer.error?.localizedDescription ?? "append failed at frame \(frameIndex)")
            }
        }

        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        guard writer.status == .completed else {
            throw FactoryError.writeFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        return url
    }

    /// Convenience: write into a unique temp file and return its URL.
    static func makeTempVideo(
        duration: Double = 1.0,
        size: CGSize = CGSize(width: 320, height: 240),
        fps: Int32 = 30
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_video_\(UUID().uuidString).mp4")
        return try writeVideo(to: url, duration: duration, size: size, fps: fps)
    }

    // MARK: - Frame rendering

    /// A solid-color frame whose hue shifts across the clip so frames differ.
    private static func makePixelBuffer(size: CGSize, frameIndex: Int, totalFrames: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        let progress = totalFrames > 1 ? CGFloat(frameIndex) / CGFloat(totalFrames - 1) : 0
        ctx.setFillColor(CGColor(red: progress, green: 0.4, blue: 1 - progress, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        // A moving white square gives the frame distinct, non-uniform content.
        let squareSize = size.width * 0.2
        let x = (size.width - squareSize) * progress
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: x, y: size.height * 0.4, width: squareSize, height: squareSize))

        return buffer
    }
}
