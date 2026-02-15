//
//  SportDetector.swift
//  BumpSetCut
//
//  Automatically detects volleyball type (beach vs indoor) from video characteristics.
//

import Foundation
import AVFoundation
import CoreML
import Vision

/// Detects whether a volleyball video is beach or indoor based on visual cues.
final class SportDetector {

    // MARK: - Detection Strategy

    /// Detects volleyball type by analyzing court characteristics and player count.
    /// - Parameters:
    ///   - asset: The video asset to analyze
    ///   - sampleCount: Number of frames to sample (default: 15)
    /// - Returns: Detected volleyball type with confidence score
    static func detectSport(from asset: AVAsset, sampleCount: Int = 15) async throws -> (type: VolleyballType, confidence: Double) {
        let reader = try AVAssetReader(asset: asset)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            print("⚠️ SportDetector: no video track found, defaulting to beach")
            return (.beach, 0.5)
        }

        // Sample frames evenly throughout the video
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds > 0 else {
            print("⚠️ SportDetector: zero duration video, defaulting to beach")
            return (.beach, 0.5)
        }

        // Set up video output
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)

        guard reader.canAdd(readerOutput) else {
            print("⚠️ SportDetector: cannot add reader output, defaulting to beach")
            return (.beach, 0.5)
        }

        reader.add(readerOutput)

        // Start reading
        guard reader.startReading() else {
            print("⚠️ SportDetector: failed to start reading, defaulting to beach")
            return (.beach, 0.5)
        }

        var signals = SportSignals()
        var framesAnalyzed = 0
        let targetSamples = min(sampleCount, 15)
        let skipFrames = max(1, Int(durationSeconds * 30) / targetSamples) // Assuming ~30fps
        var frameCount = 0

        while let sampleBuffer = readerOutput.copyNextSampleBuffer(), framesAnalyzed < targetSamples {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            frameCount += 1

            // Skip frames to get even distribution
            if frameCount % skipFrames != 0 {
                continue
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // Analyze this frame
            analyzeFrame(pixelBuffer: pixelBuffer, signals: &signals)
            framesAnalyzed += 1
        }

        reader.cancelReading()

        // Make decision based on accumulated signals
        let decision = makeDecision(from: signals, framesAnalyzed: framesAnalyzed)
        return decision
    }

    // MARK: - Frame Analysis

    private static func analyzeFrame(pixelBuffer: CVPixelBuffer, signals: inout SportSignals) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Sample colors from court area (center region)
        let samples = sampleCourtColors(pixelBuffer: pixelBuffer, width: width, height: height)

        // Check for sand-like colors (yellow/beige tones)
        let sandScore = samples.filter { isSandLike($0) }.count
        signals.sandColorSamples += sandScore

        // Check for indoor court colors (typically white/red/blue/wood)
        let indoorScore = samples.filter { isIndoorCourtLike($0) }.count
        signals.indoorColorSamples += indoorScore

        // Analyze brightness (beach is typically brighter/higher contrast)
        let brightness = calculateAverageBrightness(samples: samples)
        signals.brightnessSamples.append(brightness)

        signals.totalSamples += samples.count
    }

    /// Samples colors from the center court area
    private static func sampleCourtColors(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [RGB] {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return []
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var samples: [RGB] = []

        // Sample from bottom half (where court typically is)
        let startY = height / 2
        let endY = Int(Double(height) * 0.85)

        let samplePoints = 20
        let xStep = width / (samplePoints + 1)
        let yStep = (endY - startY) / (samplePoints / 2)

        for y in stride(from: startY, to: endY, by: yStep) {
            for x in stride(from: xStep, to: width - xStep, by: xStep) {
                let offset = y * bytesPerRow + x * 4

                // BGRA format
                let b = buffer[offset]
                let g = buffer[offset + 1]
                let r = buffer[offset + 2]

                samples.append(RGB(r: r, g: g, b: b))
            }
        }

        return samples
    }

    /// Detects sand-like colors (yellow/beige/tan)
    private static func isSandLike(_ color: RGB) -> Bool {
        let r = Double(color.r)
        let g = Double(color.g)
        let b = Double(color.b)

        // Sand is typically:
        // - Yellow/beige (r and g higher than b)
        // - Medium-high brightness
        // - Low saturation variance

        let brightness = (r + g + b) / 3.0
        guard brightness > 80 && brightness < 220 else { return false }

        // Yellow-ish: r ≈ g, both > b
        let isYellowish = r > b + 20 && g > b + 20 && abs(r - g) < 40

        return isYellowish
    }

    /// Detects indoor court colors (wood, painted lines, contrasting colors)
    private static func isIndoorCourtLike(_ color: RGB) -> Bool {
        let r = Double(color.r)
        let g = Double(color.g)
        let b = Double(color.b)

        let brightness = (r + g + b) / 3.0

        // Wood tones: brown/orange
        let isWood = r > 100 && g > 60 && g < r && b < r - 20

        // Painted court: bright red, blue, or green
        let isRedCourt = r > 150 && g < 100 && b < 100
        let isBlueCourt = b > 150 && r < 100 && g < 130
        let isGreenCourt = g > 150 && r < 120 && b < 120

        // White court (less common but exists)
        let isWhite = brightness > 200 && abs(r - g) < 20 && abs(g - b) < 20

        return isWood || isRedCourt || isBlueCourt || isGreenCourt || isWhite
    }

    private static func calculateAverageBrightness(samples: [RGB]) -> Double {
        guard !samples.isEmpty else { return 0 }

        let total = samples.reduce(0.0) { sum, color in
            sum + (Double(color.r) + Double(color.g) + Double(color.b)) / 3.0
        }

        return total / Double(samples.count)
    }

    // MARK: - Decision Logic

    private static func makeDecision(from signals: SportSignals, framesAnalyzed: Int) -> (type: VolleyballType, confidence: Double) {
        guard framesAnalyzed > 0, signals.totalSamples > 0 else {
            // Default to beach with low confidence
            return (.beach, 0.5)
        }

        // Calculate signal strengths
        let sandRatio = Double(signals.sandColorSamples) / Double(signals.totalSamples)
        let indoorRatio = Double(signals.indoorColorSamples) / Double(signals.totalSamples)

        let avgBrightness = signals.brightnessSamples.reduce(0.0, +) / Double(signals.brightnessSamples.count)

        // Beach indicators:
        // - High sand color ratio (>20%)
        // - High brightness (outdoor sun)
        // - Low indoor court color ratio

        let beachScore = (sandRatio * 2.0) + (avgBrightness > 140 ? 0.3 : 0.0) + (indoorRatio < 0.1 ? 0.2 : 0.0)

        // Indoor indicators:
        // - High indoor court color ratio (>15%)
        // - Lower brightness (controlled lighting)
        // - Low sand color ratio

        let indoorScore = (indoorRatio * 2.0) + (avgBrightness < 120 ? 0.3 : 0.0) + (sandRatio < 0.1 ? 0.2 : 0.0)

        // Make decision
        if beachScore > indoorScore {
            let confidence = min(0.95, 0.5 + (beachScore - indoorScore))
            return (.beach, confidence)
        } else {
            let confidence = min(0.95, 0.5 + (indoorScore - beachScore))
            return (.indoor, confidence)
        }
    }
}

// MARK: - Supporting Types

private struct SportSignals {
    var sandColorSamples: Int = 0
    var indoorColorSamples: Int = 0
    var brightnessSamples: [Double] = []
    var totalSamples: Int = 0
}

private struct RGB {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}
