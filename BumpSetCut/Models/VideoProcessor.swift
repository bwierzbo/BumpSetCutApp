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
    private var kalmanBallTracker = KalmanBallTracker()
    private var rallyStateTracker = RallyStateTracker()
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
        print("🎬 Starting video processing (DEV MODE)")
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
            throw ProcessingError.modelLoadFailed
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
            guard observation.confidence > 0.7 else { return nil }
            
            let label = observation.labels.first?.identifier ?? ""
            print("🎯 Detection: \(label) confidence: \(observation.confidence)")
            
            let type: DetectionType
            
            switch label {
            case "player", "person":
                type = .player
            case "ball", "volleyball":
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
}

// MARK: - Rally Detection
private extension VideoProcessor {
    func analyzeDetections(_ detections: [DetectionResult], at timestamp: CMTime) -> RallyAnalysis {
        let players = detections.filter { $0.type == .player }
        let balls = detections.filter { $0.type == .ball }
        
        // Update Kalman ball tracking
        if let ball = balls.first {
            let center = CGPoint(x: ball.boundingBox.midX, y: ball.boundingBox.midY)
            kalmanBallTracker.updateWithDetection(position: center, confidence: ball.confidence, at: timestamp)
        } else {
            // No detection - predict based on physics
            kalmanBallTracker.predictWithoutDetection(at: timestamp)
        }
        
        // Get enhanced ball tracking data
        let ballVelocity = kalmanBallTracker.getCurrentVelocity()
        let predictedPosition = kalmanBallTracker.getPredictedPosition()
        let hasTrajectoryChange = kalmanBallTracker.hasSignificantTrajectoryChange()
        let hasBallTrajectory = ballVelocity > 0.05 || hasTrajectoryChange
        
        // Player analysis - secondary indicators
        let hasActivePlayers = players.count >= 2
        let playerMovement = analyzePlayerMovement(players)
        
        // Update volleyball-specific rally state tracker
        let currentEvidence = VolleyballRallyEvidence(
            ballVisible: !balls.isEmpty,
            ballHasTrajectory: hasBallTrajectory,
            playersPresent: hasActivePlayers,
            ballVelocity: ballVelocity,
            hasTrajectoryChange: hasTrajectoryChange,
            timestamp: timestamp
        )
        
        let isActiveRally = rallyStateTracker.updateVolleyballState(with: currentEvidence)
        
        return RallyAnalysis(
            isActiveRally: isActiveRally,
            playerCount: players.count,
            ballVisible: !balls.isEmpty,
            ballVelocity: ballVelocity,
            hasTrajectoryChange: hasTrajectoryChange,
            playerMovement: playerMovement,
            timestamp: timestamp,
            predictedBallPosition: predictedPosition
        )
    }
    
    func analyzePlayerMovement(_ players: [DetectionResult]) -> CGFloat {
        guard players.count >= 2 else { return 0 }
        return players.count >= 2 ? 0.03 : 0.01
    }
}

// MARK: - Video Export
private extension VideoProcessor {
    func createAnnotatedVideo(from asset: AVAsset) async throws -> URL {
        let fileName = "dev_annotated_\(UUID().uuidString).mp4"
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputURL = documentsURL.appendingPathComponent(fileName)
        
        // Reset trackers
        kalmanBallTracker = KalmanBallTracker()
        rallyStateTracker = RallyStateTracker()
        
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
        let videoRect = CGRect(origin: .zero, size: videoSize).applying(transform)
        let finalSize = CGSize(width: abs(videoRect.width), height: abs(videoRect.height))
        
        print("📐 Original size: \(videoSize), Final size: \(finalSize)")
        
        // Create writer
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
            let detections = try await processFrame(sampleBuffer)
            let rallyAnalysis = analyzeDetections(detections, at: timestamp)
            
            let annotatedPixelBuffer = try await createAnnotatedFrame(
                sampleBuffer,
                detections: detections,
                rallyAnalysis: rallyAnalysis,
                size: finalSize
            )
            
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            
            adaptor.append(annotatedPixelBuffer, withPresentationTime: timestamp)
            frameIndex += 1
            progress = min(1.0, max(0.0, Double(frameIndex) / Double(totalFrames)))
        }
        
        writerInput.markAsFinished()
        await writer.finishWriting()
        return outputURL
    }
    
    func createAnnotatedFrame(_ sampleBuffer: CMSampleBuffer, detections: [DetectionResult], rallyAnalysis: RallyAnalysis, size: CGSize) async throws -> CVPixelBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ProcessingError.noVideoTrack
        }
        
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
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        let sourceData = CVPixelBufferGetBaseAddress(pixelBuffer)
        let destData = CVPixelBufferGetBaseAddress(outputBuffer)
        let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
        
        memcpy(destData, sourceData, dataSize)
        
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
            drawDevAnnotations(ctx: ctx, detections: detections, rallyAnalysis: rallyAnalysis, size: size)
        }
        
        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        
        return outputBuffer
    }
    
    func drawDevAnnotations(ctx: CGContext, detections: [DetectionResult], rallyAnalysis: RallyAnalysis, size: CGSize) {
        // Draw bounding boxes
        for detection in detections {
            let rect = CGRect(
                x: detection.boundingBox.origin.x * size.width,
                y: detection.boundingBox.origin.y * size.height,
                width: detection.boundingBox.width * size.width,
                height: detection.boundingBox.height * size.height
            )
            
            switch detection.type {
            case .player:
                ctx.setStrokeColor(UIColor.green.cgColor)
            case .ball:
                ctx.setStrokeColor(UIColor.red.cgColor)
            }
            
            ctx.setLineWidth(3.0)
            ctx.stroke(rect)
            
            let textRect = CGRect(x: rect.origin.x, y: rect.origin.y - 25, width: 100, height: 20)
            ctx.setFillColor(detection.type == .player ? UIColor.green.cgColor : UIColor.red.cgColor)
            ctx.fill(textRect)
        }
        
        // Draw ball trajectory
        drawBallTrajectory(ctx: ctx, size: size)
        
        // Draw rally state overlay
        drawRallyStateOverlay(ctx: ctx, rallyAnalysis: rallyAnalysis, size: size)
    }
    
    func drawRallyStateOverlay(ctx: CGContext, rallyAnalysis: RallyAnalysis, size: CGSize) {
        let overlayX: CGFloat = 20
        let overlayY: CGFloat = 40
        let lineHeight: CGFloat = 25
        
        // Rally status colors
        let statusColor = rallyAnalysis.isActiveRally ? UIColor.green : UIColor.red
        
        let statusRect = CGRect(x: overlayX - 5, y: overlayY - 5, width: 200, height: 30)
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.8).cgColor)
        ctx.fill(statusRect)
        
        // Draw status indicator
        ctx.setFillColor(statusColor.cgColor)
        let indicatorRect = CGRect(x: overlayX + 180, y: overlayY + 5, width: 15, height: 20)
        ctx.fill(indicatorRect)
        
        // Debug info areas (colored rectangles representing text)
        let debugInfo = [
            "Ball Trajectory",
            "Players",
            "Ball Visible",
            "Ball Velocity",
            "Time"
        ]
        
        let debugRect = CGRect(x: overlayX - 5, y: overlayY + 35, width: 300, height: CGFloat(debugInfo.count) * lineHeight + 15)
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fill(debugRect)
        
        // Draw colored rectangles representing debug info
        for (index, _) in debugInfo.enumerated() {
            let yPos = overlayY + 55 + CGFloat(index) * lineHeight
            let infoRect = CGRect(x: overlayX, y: yPos - 5, width: 200, height: 18)
            
            // Color code based on the type of info
            let rectColor: UIColor
            switch index {
            case 0: rectColor = rallyAnalysis.hasTrajectoryChange ? .yellow : .gray  // Ball Trajectory
            case 1: rectColor = rallyAnalysis.playerCount >= 2 ? .green : .red       // Players
            case 2: rectColor = rallyAnalysis.ballVisible ? .blue : .gray            // Ball Visible
            case 3: rectColor = rallyAnalysis.ballVelocity > 0.05 ? .cyan : .gray    // Ball Velocity
            case 4: rectColor = .white                                                // Time
            default: rectColor = .white
            }
            
            ctx.setFillColor(rectColor.cgColor)
            ctx.fill(infoRect)
        }
        
        // Add Kalman Filter status indicator
        let kalmanRect = CGRect(x: overlayX + 210, y: overlayY + 55, width: 80, height: 18)
        ctx.setFillColor(UIColor.purple.cgColor)
        ctx.fill(kalmanRect)
        
        // Draw predicted position indicator (small circle)
        let predPos = rallyAnalysis.predictedBallPosition
        if predPos.x > 0 && predPos.y > 0 {
            let predPixelPos = CGPoint(x: predPos.x * size.width, y: predPos.y * size.height)
            let predRect = CGRect(x: predPixelPos.x - 3, y: predPixelPos.y - 3, width: 6, height: 6)
            ctx.setFillColor(UIColor.purple.withAlphaComponent(0.7).cgColor)
            ctx.fillEllipse(in: predRect)
        }
        
        // Draw trajectory change indicator triangle
        if rallyAnalysis.hasTrajectoryChange {
            let trianglePoints = [
                CGPoint(x: overlayX + 270, y: overlayY + 60),
                CGPoint(x: overlayX + 280, y: overlayY + 75),
                CGPoint(x: overlayX + 260, y: overlayY + 75)
            ]
            
            ctx.setFillColor(UIColor.orange.cgColor)
            ctx.move(to: trianglePoints[0])
            ctx.addLine(to: trianglePoints[1])
            ctx.addLine(to: trianglePoints[2])
            ctx.closePath()
            ctx.fillPath()
        }
    }
    
    func drawBallTrajectory(ctx: CGContext, size: CGSize) {
        let ballPositions = kalmanBallTracker.getTrajectoryHistory()
        guard ballPositions.count > 1 else { return }
        
        // Draw actual trajectory (blue line)
        ctx.setStrokeColor(UIColor.blue.cgColor)
        ctx.setLineWidth(3.0)
        
        for i in 1..<ballPositions.count {
            let start = CGPoint(
                x: ballPositions[i-1].x * size.width,
                y: ballPositions[i-1].y * size.height
            )
            let end = CGPoint(
                x: ballPositions[i].x * size.width,
                y: ballPositions[i].y * size.height
            )
            
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        }
        
        // Draw predicted trajectory (orange dashed line)
        let predictedTrajectory = kalmanBallTracker.getPredictedTrajectory(steps: 10)
        if predictedTrajectory.count > 1 {
            ctx.setStrokeColor(UIColor.orange.cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [5.0, 3.0])
            
            for i in 1..<predictedTrajectory.count {
                let start = CGPoint(
                    x: predictedTrajectory[i-1].x * size.width,
                    y: predictedTrajectory[i-1].y * size.height
                )
                let end = CGPoint(
                    x: predictedTrajectory[i].x * size.width,
                    y: predictedTrajectory[i].y * size.height
                )
                
                ctx.move(to: start)
                ctx.addLine(to: end)
                ctx.strokePath()
            }
            
            // Reset line dash
            ctx.setLineDash(phase: 0, lengths: [])
        }
        
        // Draw current predicted position (green circle)
        let currentPrediction = kalmanBallTracker.getPredictedPosition()
        let predictionPoint = CGPoint(
            x: currentPrediction.x * size.width,
            y: currentPrediction.y * size.height
        )
        
        ctx.setFillColor(UIColor.green.cgColor)
        let predictionCircle = CGRect(
            x: predictionPoint.x - 5,
            y: predictionPoint.y - 5,
            width: 10,
            height: 10
        )
        ctx.fillEllipse(in: predictionCircle)
    }
}

// MARK: - Data Models
struct RallyAnalysis {
    let isActiveRally: Bool
    let playerCount: Int
    let ballVisible: Bool
    let ballVelocity: CGFloat
    let hasTrajectoryChange: Bool
    let playerMovement: CGFloat
    let timestamp: CMTime
    let predictedBallPosition: CGPoint
}

struct VolleyballRallyEvidence {
    let ballVisible: Bool
    let ballHasTrajectory: Bool
    let playersPresent: Bool
    let ballVelocity: CGFloat
    let hasTrajectoryChange: Bool
    let timestamp: CMTime
}

private class RallyStateTracker {
    private var currentlyInRally = false
    private var lastBallActivityTime: CMTime?
    private var rallyStartTime: CMTime?
    private let rallyEndTimeout: Double = 4.0
    private let rallyStartBuffer: Double = 1.5
    
    func updateVolleyballState(with evidence: VolleyballRallyEvidence) -> Bool {
        let currentTime = evidence.timestamp
        
        if evidence.ballHasTrajectory {
            lastBallActivityTime = currentTime
        }
        
        if currentlyInRally {
            let shouldEndRally = shouldEndCurrentRally(evidence: evidence, currentTime: currentTime)
            
            if shouldEndRally {
                currentlyInRally = false
                print("🔴 Rally ended at \(currentTime.seconds)s (no ball activity for \(rallyEndTimeout)s)")
                lastBallActivityTime = nil
                rallyStartTime = nil
            }
        } else {
            let shouldStartRally = shouldStartNewRally(evidence: evidence)
            
            if shouldStartRally {
                currentlyInRally = true
                let bufferedStartTime = CMTimeSubtract(currentTime, CMTimeMakeWithSeconds(rallyStartBuffer, preferredTimescale: 600))
                rallyStartTime = bufferedStartTime
                lastBallActivityTime = currentTime
                
                print("🟢 Rally started at \(bufferedStartTime.seconds)s (detected at \(currentTime.seconds)s)")
            }
        }
        
        return currentlyInRally
    }
    
    private func shouldEndCurrentRally(evidence: VolleyballRallyEvidence, currentTime: CMTime) -> Bool {
        guard let lastActivity = lastBallActivityTime else {
            return true
        }
        
        let timeSinceLastActivity = CMTimeGetSeconds(CMTimeSubtract(currentTime, lastActivity))
        let timeoutReached = timeSinceLastActivity >= rallyEndTimeout
        let noRecentActivity = !evidence.ballHasTrajectory
        let playersGone = !evidence.playersPresent && timeSinceLastActivity > 2.0
        
        return timeoutReached && (noRecentActivity || playersGone)
    }
    
    private func shouldStartNewRally(evidence: VolleyballRallyEvidence) -> Bool {
        let ballActivityDetected = evidence.ballHasTrajectory
        let playersPresent = evidence.playersPresent
        
        return ballActivityDetected && playersPresent
    }
}

private class KalmanBallTracker {
    // State vector: [x, y, vx, vy] - position and velocity in normalized coordinates
    private var state: [Double] = [0.5, 0.5, 0.0, 0.0] // Start at center with zero velocity
    private var covariance: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
    private var lastUpdateTime: CMTime?
    private var trajectoryHistory: [CGPoint] = []
    private let maxHistoryCount = 30
    private var lastVelocities: [Double] = []
    private let maxVelocityHistory = 5
    
    // Physics constants (adapted for normalized coordinates)
    private let gravity: Double = 0.0005 // Gravity in normalized coordinates per second^2
    private let processNoise: Double = 0.01 // Process noise
    private let baseObservationNoise: Double = 0.05 // Base measurement noise
    
    init() {
        // Initialize covariance matrix with high uncertainty
        for i in 0..<4 {
            covariance[i][i] = 1.0 // High initial uncertainty
        }
    }
    
    func updateWithDetection(position: CGPoint, confidence: Float, at timestamp: CMTime) {
        let currentTime = timestamp
        
        // Calculate time delta
        let deltaTime: Double
        if let lastTime = lastUpdateTime {
            deltaTime = CMTimeGetSeconds(CMTimeSubtract(currentTime, lastTime))
        } else {
            deltaTime = 1.0/30.0 // Assume 30fps for first frame
        }
        
        // Prediction step using projectile motion physics
        predictState(deltaTime: deltaTime)
        
        // Update step with detection measurement
        let measurement = [Double(position.x), Double(position.y)]
        let observationNoise = calculateObservationNoise(confidence: confidence)
        updateWithMeasurement(measurement, noise: observationNoise)
        
        // Store history
        let statePosition = CGPoint(x: state[0], y: state[1])
        trajectoryHistory.append(statePosition)
        if trajectoryHistory.count > maxHistoryCount {
            trajectoryHistory.removeFirst()
        }
        
        // Store velocity history for trajectory change detection
        let currentVelocity = sqrt(state[2] * state[2] + state[3] * state[3])
        lastVelocities.append(currentVelocity)
        if lastVelocities.count > maxVelocityHistory {
            lastVelocities.removeFirst()
        }
        
        lastUpdateTime = currentTime
        
        print("🎯 Kalman Update: pos=(\(String(format: "%.3f", state[0])), \(String(format: "%.3f", state[1]))), vel=(\(String(format: "%.3f", state[2])), \(String(format: "%.3f", state[3]))), conf=\(confidence)")
    }
    
    func predictWithoutDetection(at timestamp: CMTime) {
        guard let lastTime = lastUpdateTime else { return }
        
        let deltaTime = CMTimeGetSeconds(CMTimeSubtract(timestamp, lastTime))
        
        // Only prediction step - no measurement update
        predictState(deltaTime: deltaTime)
        
        // Store predicted position in history
        let predictedPosition = CGPoint(x: state[0], y: state[1])
        trajectoryHistory.append(predictedPosition)
        if trajectoryHistory.count > maxHistoryCount {
            trajectoryHistory.removeFirst()
        }
        
        lastUpdateTime = timestamp
        
        print("🔮 Kalman Predict: pos=(\(String(format: "%.3f", state[0])), \(String(format: "%.3f", state[1]))), vel=(\(String(format: "%.3f", state[2])), \(String(format: "%.3f", state[3])))")
    }
    
    private func predictState(deltaTime: Double) {
        // Projectile motion equations
        // x(t+1) = x(t) + vx(t) * dt
        // y(t+1) = y(t) + vy(t) * dt + 0.5 * g * dt^2
        // vx(t+1) = vx(t) (no horizontal acceleration)
        // vy(t+1) = vy(t) + g * dt
        
        let dt = deltaTime
        let dt2 = dt * dt
        
        // State transition matrix F
        let F = [
            [1.0, 0.0, dt, 0.0],
            [0.0, 1.0, 0.0, dt],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0]
        ]
        
        // Control input (gravity affects y-velocity)
        let gravityInput = [0.0, 0.5 * gravity * dt2, 0.0, gravity * dt]
        
        // Predict state: x = F * x + B * u
        var newState = [Double](repeating: 0.0, count: 4)
        for i in 0..<4 {
            for j in 0..<4 {
                newState[i] += F[i][j] * state[j]
            }
            newState[i] += gravityInput[i]
        }
        state = newState
        
        // Predict covariance: P = F * P * F^T + Q
        let Q = processNoiseMatrix(dt: dt)
        covariance = matrixAdd(matrixMultiply(matrixMultiply(F, covariance), matrixTranspose(F)), Q)
        
        // Clamp state to reasonable bounds (normalized coordinates)
        state[0] = max(0.0, min(1.0, state[0])) // x position [0,1]
        state[1] = max(0.0, min(1.0, state[1])) // y position [0,1]
        state[2] = max(-2.0, min(2.0, state[2])) // x velocity
        state[3] = max(-2.0, min(2.0, state[3])) // y velocity
    }
    
    private func updateWithMeasurement(_ measurement: [Double], noise: Double) {
        // Measurement matrix H (we observe position only)
        let H = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0]
        ]
        
        // Measurement noise matrix R
        let R = [
            [noise, 0.0],
            [0.0, noise]
        ]
        
        // Innovation: y = z - H * x
        let Hx = matrixVectorMultiply(H, state)
        let innovation = [measurement[0] - Hx[0], measurement[1] - Hx[1]]
        
        // Innovation covariance: S = H * P * H^T + R
        let HPHt = matrixMultiply(matrixMultiply(H, covariance), matrixTranspose(H))
        let S = matrixAdd(HPHt, R)
        
        // Kalman gain: K = P * H^T * S^-1
        let K = matrixMultiply(matrixMultiply(covariance, matrixTranspose(H)), matrixInverse(S))
        
        // Update state: x = x + K * y
        let Ky = matrixVectorMultiply(K, innovation)
        for i in 0..<4 {
            state[i] += Ky[i]
        }
        
        // Update covariance: P = (I - K * H) * P
        let I = identityMatrix(size: 4)
        let KH = matrixMultiply(K, H)
        let IminusKH = matrixSubtract(I, KH)
        covariance = matrixMultiply(IminusKH, covariance)
    }
    
    private func calculateObservationNoise(confidence: Float) -> Double {
        // Higher confidence = lower noise
        // Confidence is 0.0 to 1.0, we want noise to be higher when confidence is lower
        let confidenceDouble = Double(confidence)
        return baseObservationNoise * (2.0 - confidenceDouble) // Noise range: baseNoise to 2*baseNoise
    }
    
    private func processNoiseMatrix(dt: Double) -> [[Double]] {
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt3 * dt
        
        // Process noise matrix for constant acceleration model
        let q = processNoise
        return [
            [q * dt4 / 4.0, 0.0, q * dt3 / 2.0, 0.0],
            [0.0, q * dt4 / 4.0, 0.0, q * dt3 / 2.0],
            [q * dt3 / 2.0, 0.0, q * dt2, 0.0],
            [0.0, q * dt3 / 2.0, 0.0, q * dt2]
        ]
    }
    
    // Public interface methods
    func getCurrentVelocity() -> CGFloat {
        let velocity = sqrt(state[2] * state[2] + state[3] * state[3])
        return CGFloat(velocity)
    }
    
    func getPredictedPosition() -> CGPoint {
        return CGPoint(x: state[0], y: state[1])
    }
    
    func getTrajectoryHistory() -> [CGPoint] {
        return trajectoryHistory
    }
    
    func getPredictedTrajectory(steps: Int) -> [CGPoint] {
        var predictions: [CGPoint] = []
        var tempState = state
        let dt = 1.0/30.0 // Predict at 30fps intervals
        
        for _ in 0..<steps {
            // Apply projectile motion for one step
            tempState[0] += tempState[2] * dt
            tempState[1] += tempState[3] * dt + 0.5 * gravity * dt * dt
            tempState[3] += gravity * dt
            
            // Clamp to bounds
            tempState[0] = max(0.0, min(1.0, tempState[0]))
            tempState[1] = max(0.0, min(1.0, tempState[1]))
            
            predictions.append(CGPoint(x: tempState[0], y: tempState[1]))
        }
        
        return predictions
    }
    
    func hasSignificantTrajectoryChange() -> Bool {
        guard lastVelocities.count >= 3 else { return false }
        
        // Check for significant velocity changes (indicating hits, bounces, etc.)
        let recent = lastVelocities.suffix(3)
        let velocityChanges = zip(recent.dropFirst(), recent).map { abs($0 - $1) }
        let maxChange = velocityChanges.max() ?? 0.0
        
        return maxChange > 0.1 // Threshold for significant trajectory change
    }
    
    // Matrix operations (simplified for 2x2 and 4x4 matrices)
    private func matrixMultiply(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
        let rowsA = A.count
        let colsA = A[0].count
        let colsB = B[0].count
        
        var result = Array(repeating: Array(repeating: 0.0, count: colsB), count: rowsA)
        
        for i in 0..<rowsA {
            for j in 0..<colsB {
                for k in 0..<colsA {
                    result[i][j] += A[i][k] * B[k][j]
                }
            }
        }
        return result
    }
    
    private func matrixTranspose(_ A: [[Double]]) -> [[Double]] {
        let rows = A.count
        let cols = A[0].count
        var result = Array(repeating: Array(repeating: 0.0, count: rows), count: cols)
        
        for i in 0..<rows {
            for j in 0..<cols {
                result[j][i] = A[i][j]
            }
        }
        return result
    }
    
    private func matrixAdd(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
        let rows = A.count
        let cols = A[0].count
        var result = Array(repeating: Array(repeating: 0.0, count: cols), count: rows)
        
        for i in 0..<rows {
            for j in 0..<cols {
                result[i][j] = A[i][j] + B[i][j]
            }
        }
        return result
    }
    
    private func matrixSubtract(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
        let rows = A.count
        let cols = A[0].count
        var result = Array(repeating: Array(repeating: 0.0, count: cols), count: rows)
        
        for i in 0..<rows {
            for j in 0..<cols {
                result[i][j] = A[i][j] - B[i][j]
            }
        }
        return result
    }
    
    private func matrixVectorMultiply(_ A: [[Double]], _ v: [Double]) -> [Double] {
        let rows = A.count
        var result = Array(repeating: 0.0, count: rows)
        
        for i in 0..<rows {
            for j in 0..<v.count {
                result[i] += A[i][j] * v[j]
            }
        }
        return result
    }
    
    private func identityMatrix(size: Int) -> [[Double]] {
        var matrix = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        for i in 0..<size {
            matrix[i][i] = 1.0
        }
        return matrix
    }
    
    private func matrixInverse(_ A: [[Double]]) -> [[Double]] {
        // Simplified 2x2 matrix inverse for measurement update
        if A.count == 2 && A[0].count == 2 {
            let det = A[0][0] * A[1][1] - A[0][1] * A[1][0]
            if abs(det) < 1e-10 { return identityMatrix(size: 2) } // Avoid division by zero
            
            return [
                [A[1][1] / det, -A[0][1] / det],
                [-A[1][0] / det, A[0][0] / det]
            ]
        }
        
        return identityMatrix(size: A.count) // Fallback
    }
}

private class BallTracker {
    private var ballHistory: [(CGPoint, CMTime)] = []
    private let maxHistoryCount = 30
    
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
        
        let vector1 = CGPoint(x: positions[1].x - positions[0].x, y: positions[1].y - positions[0].y)
        let vector2 = CGPoint(x: positions[2].x - positions[1].x, y: positions[2].y - positions[1].y)
        
        let dotProduct = vector1.x * vector2.x + vector1.y * vector2.y
        let magnitude1 = sqrt(vector1.x * vector1.x + vector1.y * vector1.y)
        let magnitude2 = sqrt(vector2.x * vector2.x + vector2.y * vector2.y)
        
        guard magnitude1 > 0 && magnitude2 > 0 else { return false }
        
        let cosAngle = dotProduct / (magnitude1 * magnitude2)
        return cosAngle < 0.5
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
    case noRallySegments
}
