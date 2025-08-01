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

@MainActor @Observable class VideoProcessor {
    var isProcessing = false
    var progress: Double = 0.0
    var processedURL: URL?
    
    private var detectionModel: VNCoreMLModel?
}

// MARK: - Model Setup
private extension VideoProcessor {
    func loadYOLOModel() async -> Bool {
        // TODO: Load YOLOv8 Core ML model when available
        // For now, we'll use a placeholder
        return true
    }
}

// MARK: - Video Processing
extension VideoProcessor {
    func processVideo(_ videoURL: URL) async throws -> URL {
        isProcessing = true
        progress = 0.0
        
        let asset = AVAsset(url: videoURL)
        let rallySegments = try await detectRallySegments(in: asset)
        let processedURL = try await createEditedVideo(from: asset, segments: rallySegments)
        
        self.processedURL = processedURL
        isProcessing = false
        return processedURL
    }
}

// MARK: - Rally Detection
private extension VideoProcessor {
    func detectRallySegments(in asset: AVAsset) async throws -> [RallySegment] {
        let duration = try await asset.load(.duration)
        let frameRate: Double = 5 // Process every 5th frame for performance
        
        var segments: [RallySegment] = []
        var currentSegment: RallySegment?
        
        // Create video reader
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()
        
        var frameIndex = 0
        let totalFrames = Int(duration.seconds * frameRate)
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if frameIndex % Int(30 / frameRate) == 0 { // Sample at desired rate
                let detections = try await processFrame(sampleBuffer)
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                
                let isActiveRally = analyzeDetections(detections, at: timestamp)
                
                if isActiveRally && currentSegment == nil {
                    // Start new rally segment
                    currentSegment = RallySegment(start: timestamp)
                } else if !isActiveRally && currentSegment != nil {
                    // End current rally segment
                    currentSegment?.end = timestamp
                    if let segment = currentSegment {
                        segments.append(segment)
                    }
                    currentSegment = nil
                }
                
                progress = Double(frameIndex) / Double(totalFrames)
            }
            
            frameIndex += 1
        }
        
        // Close any remaining segment
        if var segment = currentSegment {
            segment.end = duration
            segments.append(segment)
        }
        
        return segments
    }
    
    func processFrame(_ sampleBuffer: CMSampleBuffer) async throws -> [DetectionResult] {
        guard let _ = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return []
        }
        
        // TODO: Replace with actual YOLOv8 model when available
        // For now, return mock detections for testing
        return createMockDetections()
    }
    
    func analyzeDetections(_ detections: [DetectionResult], at timestamp: CMTime) -> Bool {
        let playerCount = detections.filter { $0.type == .player }.count
        let ballDetections = detections.filter { $0.type == .ball }
        
        // Basic logic: rally is active if we have players and ball movement
        let hasPlayers = playerCount >= 2
        let hasBall = !ballDetections.isEmpty
        
        // TODO: Add trajectory analysis and movement detection
        return hasPlayers && hasBall
    }
    
    func createMockDetections() -> [DetectionResult] {
        // Mock data for testing - replace with actual model results
        return [
            DetectionResult(type: .player, confidence: 0.8, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.15, height: 0.4)),
            DetectionResult(type: .player, confidence: 0.7, boundingBox: CGRect(x: 0.7, y: 0.3, width: 0.12, height: 0.35)),
            DetectionResult(type: .ball, confidence: 0.6, boundingBox: CGRect(x: 0.45, y: 0.1, width: 0.05, height: 0.05))
        ]
    }
}

// MARK: - Video Export
private extension VideoProcessor {
    func createEditedVideo(from asset: AVAsset, segments: [RallySegment]) async throws -> URL {
        let composition = AVMutableComposition()
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ProcessingError.noTracks
        }
        
        let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        
        var insertTime = CMTime.zero
        
        for segment in segments {
            let timeRange = CMTimeRange(start: segment.start, end: segment.end)
            
            try compositionVideoTrack?.insertTimeRange(timeRange, of: videoTrack, at: insertTime)
            try compositionAudioTrack?.insertTimeRange(timeRange, of: audioTrack, at: insertTime)
            
            insertTime = CMTimeAdd(insertTime, timeRange.duration)
        }
        
        // Export processed video
        let fileName = "processed_\(UUID().uuidString).mp4"
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputURL = documentsURL.appendingPathComponent(fileName)
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetMediumQuality) else {
            throw ProcessingError.exportFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        
        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed, .cancelled:
                    continuation.resume(throwing: ProcessingError.exportFailed)
                default:
                    continuation.resume(throwing: ProcessingError.exportFailed)
                }
            }
        }
    }
}

// MARK: - Data Models
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
}
