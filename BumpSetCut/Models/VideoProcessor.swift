//
//  VideoProcessor.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import Foundation
import AVFoundation
import CoreML
import Vision
import UIKit

@MainActor @Observable class VideoProcessor {
    var isProcessing = false
    var progress: Double = 0.0
    var processedURL: URL?
    
    private var detectionModel: VNCoreMLModel?
    private var ballTracker = BallTracker()
}

// MARK: - Model Setup
private extension VideoProcessor {
    func loadYOLOModel() async -> Bool {
        // Debug: List all files in bundle
        if let resourcePath = Bundle.main.resourcePath {
            let files = try? FileManager.default.contentsOfDirectory(atPath: resourcePath)
            print("📁 Bundle files: \(files?.filter { $0.contains("ml") } ?? [])")
        }
        
        // Try different variations
        let variations = [
            ("volleyball_detector", "mlpackage"),
            ("best", "mlpackage"),
            ("best", "mlmodelc"),
            ("volleyball_detector", "mlmodelc")
        ]
        
        for (name, ext) in variations {
            if let modelURL = Bundle.main.url(forResource: name, withExtension: ext) {
                print("✅ Found model: \(modelURL)")
                if let model = try? VNCoreMLModel(for: MLModel(contentsOf: modelURL)) {
                    print("✅ Model loaded successfully!")
                    detectionModel = model
                    return true
                } else {
                    print("❌ Failed to create VNCoreMLModel from: \(modelURL)")
                }
            }
        }
        
        print("❌ No model file found in bundle")
        return false
    }
}

// MARK: - Video Processing
extension VideoProcessor {
    func processVideo(_ videoURL: URL) async throws -> URL {
        print("🎬 Starting video processing")
        isProcessing = true
        progress = 0.0
        
        // Load model first
        print("🧠 Loading YOLO model...")
        let modelLoaded = await loadYOLOModel()
        print("🧠 Model loaded: \(modelLoaded)")
        guard modelLoaded else {
            throw ProcessingError.modelLoadFailed
        }
        
        let asset = AVURLAsset(url: videoURL)
        let processedURL = try await createAnnotatedVideo(from: asset)
        
        self.processedURL = processedURL
        isProcessing = false
        return processedURL
    }
}

// MARK: - Frame Processing
private extension VideoProcessor {
    func processFrame(_ sampleBuffer: CMSampleBuffer) async throws -> [DetectionResult] {
        guard let model = detectionModel,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return createMockDetections()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let detections = self.parseYOLOResults(request.results)
                continuation.resume(returning: detections)
            }
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    func parseYOLOResults(_ results: [VNObservation]?) -> [DetectionResult] {
        guard let results = results as? [VNRecognizedObjectObservation] else {
            print("❌ No VNRecognizedObjectObservation results")
            return []
        }
        
        print("🔍 Raw detections: \(results.count)")
        
        let detections: [DetectionResult] = results.compactMap { observation in
            guard observation.confidence > 0.6 else { return nil } // Increased from 0.3 to 0.7 (70%)
            
            let label = observation.labels.first?.identifier ?? ""
            print("🎯 Detection: \(label) confidence: \(observation.confidence)")
            
            let type: DetectionType
            
            switch label {
            case "player", "person":  // Handle both variations
                type = .player
            case "ball", "volleyball":  // Handle both variations
                type = .ball
            default:
                print("⚠️ Unknown label: \(label)")
                return nil
            }
            
            return DetectionResult(
                type: type,
                confidence: observation.confidence,
                boundingBox: observation.boundingBox
            )
        }
        
        print("✅ Valid detections: \(detections.count)")
        return detections
    }
    
    func analyzeDetections(_ detections: [DetectionResult], at timestamp: CMTime) -> Bool {
        let balls = detections.filter { $0.type == .ball }
        
        // Update ball tracking for trajectory visualization
        if let ball = balls.first {
            let center = CGPoint(x: ball.boundingBox.midX, y: ball.boundingBox.midY)
            ballTracker.addBallPosition(center, at: timestamp)
        }
        
        // For now, just return true since we're not cutting video
        return true
    }
    
    func createMockDetections() -> [DetectionResult] {
        // Mock data for testing - replace with actual model results
        return [
            DetectionResult(type: .player, confidence: 0.8, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.15, height: 0.4)),
            DetectionResult(type: .player, confidence: 0.7, boundingBox: CGRect(x: 0.7, y: 0.3, width: 0.12, height: 0.35)),
            DetectionResult(type: .ball, confidence: 0.5, boundingBox: CGRect(x: 0.45, y: 0.1, width: 0.05, height: 0.05))
        ]
    }
}

// MARK: - Video Export
private extension VideoProcessor {
    func createAnnotatedVideo(from asset: AVAsset) async throws -> URL {
        let fileName = "annotated_\(UUID().uuidString).mp4"
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputURL = documentsURL.appendingPathComponent(fileName)
        
        // Reset ball tracker
        ballTracker = BallTracker()
        
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        
        // Get original video dimensions
        let videoSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        
        // Apply transform to get correct dimensions for rotated videos
        let videoRect = CGRect(origin: .zero, size: videoSize).applying(transform)
        let finalSize = CGSize(width: abs(videoRect.width), height: abs(videoRect.height))
        
        print("📐 Original size: \(videoSize), Final size: \(finalSize)")
        
        // Create writer with correct dimensions
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(finalSize.width),
            AVVideoHeightKey: Int(finalSize.height)
        ])
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(finalSize.width),
                kCVPixelBufferHeightKey as String: Int(finalSize.height)
            ]
        )
        
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        reader.startReading()
        
        var frameIndex = 0
        let duration = try await asset.load(.duration)
        let frameRate = try await track.load(.nominalFrameRate)
        let totalFrames = Int(duration.seconds * Double(frameRate))
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            // Run detection on frame
            let detections = try await processFrame(sampleBuffer)
            
            // Update ball tracking (for trajectory visualization)
            _ = analyzeDetections(detections, at: timestamp)
            
            // Create annotated frame
            let annotatedPixelBuffer = try await createAnnotatedFrame(sampleBuffer, detections: detections, size: finalSize)
            
            // Add to video
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            
            adaptor.append(annotatedPixelBuffer, withPresentationTime: timestamp)
            
            frameIndex += 1
            progress = Double(frameIndex) / Double(totalFrames)
        }
        
        writerInput.markAsFinished()
        await writer.finishWriting()
        
        return outputURL
    }
    
    func createAnnotatedFrame(_ sampleBuffer: CMSampleBuffer, detections: [DetectionResult], size: CGSize) async throws -> CVPixelBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ProcessingError.noVideoTrack
        }
        
        // Create mutable copy
        var annotatedPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &annotatedPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = annotatedPixelBuffer else {
            throw ProcessingError.exportFailed
        }
        
        // Copy original pixels
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        let sourceData = CVPixelBufferGetBaseAddress(pixelBuffer)
        let destData = CVPixelBufferGetBaseAddress(outputBuffer)
        let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
        
        memcpy(destData, sourceData, dataSize)
        
        // Draw annotations
        let context = CGContext(
            data: destData,
            width: CVPixelBufferGetWidth(outputBuffer),
            height: CVPixelBufferGetHeight(outputBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(outputBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        if let ctx = context {
            drawAnnotations(ctx: ctx, detections: detections, size: size)
        }
        
        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        
        return outputBuffer
    }
    
    func drawAnnotations(ctx: CGContext, detections: [DetectionResult], size: CGSize) {
        print("🎨 Drawing \(detections.count) detections on \(size)")
        
        // Draw bounding boxes
        for detection in detections {
            let rect = CGRect(
                x: detection.boundingBox.origin.x * size.width,
                y: detection.boundingBox.origin.y * size.height,  // Remove the inversion
                width: detection.boundingBox.width * size.width,
                height: detection.boundingBox.height * size.height
            )
            
            print("🎯 Drawing \(detection.type) at \(rect)")
            
            // Set color based on detection type
            switch detection.type {
            case .player:
                ctx.setStrokeColor(UIColor.green.cgColor)
            case .ball:
                ctx.setStrokeColor(UIColor.red.cgColor)
            }
            
            ctx.setLineWidth(3.0)
            ctx.stroke(rect)
            
            // Draw confidence background
            let textRect = CGRect(x: rect.origin.x, y: rect.origin.y - 25, width: 100, height: 20)
            
            ctx.setFillColor(detection.type == .player ? UIColor.green.cgColor : UIColor.red.cgColor)
            ctx.fill(textRect)
        }
        
        // Draw ball trajectory
        drawBallTrajectory(ctx: ctx, size: size)
    }
    
    func drawBallTrajectory(ctx: CGContext, size: CGSize) {
        let ballPositions = ballTracker.getBallPositions()
        guard ballPositions.count > 1 else { return }
        
        ctx.setStrokeColor(UIColor.blue.cgColor)
        ctx.setLineWidth(2.0)
        
        for i in 1..<ballPositions.count {
            let start = CGPoint(
                x: ballPositions[i-1].x * size.width,
                y: ballPositions[i-1].y * size.height  // Remove the inversion
            )
            let end = CGPoint(
                x: ballPositions[i].x * size.width,
                y: ballPositions[i].y * size.height     // Remove the inversion
            )
            
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        }
    }
}

// MARK: - Data Models
private class BallTracker {
    private var ballHistory: [(CGPoint, CMTime)] = []
    private let maxHistoryCount = 30 // Increased for better trajectory visualization
    
    func addBallPosition(_ position: CGPoint, at time: CMTime) {
        ballHistory.append((position, time))
        if ballHistory.count > maxHistoryCount {
            ballHistory.removeFirst()
        }
    }
    
    func getBallPositions() -> [CGPoint] {
        return ballHistory.map { $0.0 }
    }
    
    func getBallVelocity() -> CGFloat {
        guard ballHistory.count >= 2 else { return 0 }
        
        let recent = ballHistory.suffix(2)
        let start = recent.first!
        let end = recent.last!
        
        let distance = sqrt(pow(end.0.x - start.0.x, 2) + pow(end.0.y - start.0.y, 2))
        let timeDiff = CMTimeGetSeconds(CMTimeSubtract(end.1, start.1))
        
        return timeDiff > 0 ? distance / CGFloat(timeDiff) : 0
    }
    
    func hasTrajectoryChange() -> Bool {
        guard ballHistory.count >= 3 else { return false }
        
        let recent = ballHistory.suffix(3)
        let positions = recent.map { $0.0 }
        
        // Check if ball changed direction significantly
        let vector1 = CGPoint(x: positions[1].x - positions[0].x, y: positions[1].y - positions[0].y)
        let vector2 = CGPoint(x: positions[2].x - positions[1].x, y: positions[2].y - positions[1].y)
        
        let dotProduct = vector1.x * vector2.x + vector1.y * vector2.y
        let magnitude1 = sqrt(vector1.x * vector1.x + vector1.y * vector1.y)
        let magnitude2 = sqrt(vector2.x * vector2.x + vector2.y * vector2.y)
        
        guard magnitude1 > 0 && magnitude2 > 0 else { return false }
        
        let cosAngle = dotProduct / (magnitude1 * magnitude2)
        return cosAngle < 0.5 // Direction change > 60 degrees
    }
}

struct RallySegment {
    var start: CMTime
    var end: CMTime = CMTime.zero
}

struct DetectionResult {
    let type: DetectionType
    let confidence: Float
    let boundingBox: CGRect
}

enum DetectionType {
    case player
    case ball
}

enum ProcessingError: Error {
    case noVideoTrack
    case noTracks
    case exportFailed
    case modelLoadFailed
}
