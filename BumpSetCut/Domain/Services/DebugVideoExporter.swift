//
//  DebugVideoExporter.swift
//  BumpSetCut
//
//  Created for Metadata Video Processing - Task 007
//

#if DEBUG
import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import CoreVideo
import UIKit

/// Debug-only service for exporting annotated videos with metadata-based overlays.
/// Extends DebugAnnotator functionality to generate comprehensive visualization videos
/// for algorithm validation and QA purposes.
@MainActor
final class DebugVideoExporter: ObservableObject {

    // MARK: - Progress Reporting

    struct ExportProgress {
        let currentFrame: Int
        let totalFrames: Int
        let phase: ExportPhase
        let elapsedTime: TimeInterval
        let estimatedTimeRemaining: TimeInterval?

        var completionPercentage: Double {
            guard totalFrames > 0 else { return 0 }
            return min(1.0, Double(currentFrame) / Double(totalFrames))
        }
    }

    enum ExportPhase {
        case initializing
        case readingVideo
        case processingFrames
        case finalizing
        case completed
        case failed(Error)

        var description: String {
            switch self {
            case .initializing: return "Initializing export..."
            case .readingVideo: return "Reading video file..."
            case .processingFrames: return "Processing frames with overlays..."
            case .finalizing: return "Finalizing video export..."
            case .completed: return "Export completed"
            case .failed(let error): return "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Properties

    @Published private(set) var currentProgress: ExportProgress?
    @Published private(set) var isExporting: Bool = false

    private let metadataStore: MetadataStore
    private let ciContext = CIContext(options: nil)
    private var startTime: Date?

    // MARK: - Initialization

    init(metadataStore: MetadataStore) {
        self.metadataStore = metadataStore
    }

    // MARK: - Public API

    /// Export annotated debug video for a given video file using its metadata
    func exportAnnotatedVideo(for videoURL: URL, videoId: UUID) async throws -> URL {
        guard !isExporting else {
            throw DebugExportError.exportInProgress
        }

        isExporting = true
        startTime = Date()
        defer { isExporting = false }

        do {
            // Update progress: initializing
            updateProgress(phase: .initializing, currentFrame: 0, totalFrames: 0)

            // Load metadata for the video
            let metadata = try metadataStore.loadMetadata(for: videoId)

            // Setup output URL
            let outputURL = makeOutputURL(for: videoId)

            // Setup asset reader
            let asset = AVURLAsset(url: videoURL)

            // Update progress: reading video
            updateProgress(phase: .readingVideo, currentFrame: 0, totalFrames: 0)

            // Get video track and estimate frame count
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw DebugExportError.noVideoTrack
            }

            let duration = try await asset.load(.duration)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let estimatedFrameCount = Int(CMTimeGetSeconds(duration) * Double(nominalFrameRate))

            // Create debug annotator with video properties
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)

            let annotator = try DebugAnnotator(
                outputURL: outputURL,
                size: naturalSize,
                transform: preferredTransform
            )

            // Setup asset reader
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
            )
            reader.add(readerOutput)

            // Update progress: processing frames
            updateProgress(phase: .processingFrames, currentFrame: 0, totalFrames: estimatedFrameCount)

            // Start reading
            guard reader.startReading() else {
                throw reader.error ?? DebugExportError.readerFailed
            }

            var frameCount = 0

            // Process frames
            while reader.status == .reading {
                autoreleasepool {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { return }

                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let enhancedFrameData = createEnhancedOverlayFrameData(
                        for: presentationTime,
                        metadata: metadata
                    )

                    do {
                        try appendWithEnhancedOverlays(
                            sampleBuffer: sampleBuffer,
                            enhancedData: enhancedFrameData,
                            annotator: annotator,
                            frameSize: naturalSize
                        )
                        frameCount += 1

                        // Update progress every 30 frames to avoid excessive UI updates
                        if frameCount % 30 == 0 {
                            updateProgress(
                                phase: .processingFrames,
                                currentFrame: frameCount,
                                totalFrames: estimatedFrameCount
                            )
                        }
                    } catch {
                        print("DebugVideoExporter: Failed to append frame \(frameCount): \(error)")
                    }
                }
            }

            // Check for reader errors
            if reader.status == .failed {
                throw reader.error ?? DebugExportError.readerFailed
            }

            // Update progress: finalizing
            updateProgress(phase: .finalizing, currentFrame: frameCount, totalFrames: frameCount)

            // Finish annotation
            let finalURL = try await annotator.finish()

            // Update progress: completed
            updateProgress(phase: .completed, currentFrame: frameCount, totalFrames: frameCount)

            print("DebugVideoExporter: Successfully exported annotated video to: \(finalURL.path)")
            return finalURL

        } catch {
            updateProgress(phase: .failed(error), currentFrame: 0, totalFrames: 0)
            throw error
        }
    }

    // MARK: - Progress Management

    private func updateProgress(phase: ExportPhase, currentFrame: Int, totalFrames: Int) {
        let elapsedTime = Date().timeIntervalSince(startTime ?? Date())

        var estimatedTimeRemaining: TimeInterval? = nil
        if totalFrames > 0 && currentFrame > 0 {
            let averageTimePerFrame = elapsedTime / Double(currentFrame)
            let remainingFrames = totalFrames - currentFrame
            estimatedTimeRemaining = averageTimePerFrame * Double(remainingFrames)
        }

        currentProgress = ExportProgress(
            currentFrame: currentFrame,
            totalFrames: totalFrames,
            phase: phase,
            elapsedTime: elapsedTime,
            estimatedTimeRemaining: estimatedTimeRemaining
        )
    }

    // MARK: - Output File Management

    private func makeOutputURL(for videoId: UUID) -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let debugExportsURL = documentsURL.appendingPathComponent("DebugExports", isDirectory: true)

        // Ensure debug exports directory exists
        try? FileManager.default.createDirectory(
            at: debugExportsURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let filename = "\(videoId.uuidString)_annotated.mov"
        return debugExportsURL.appendingPathComponent(filename)
    }

    // MARK: - Enhanced Overlay Features

    /// Enhanced overlay frame data that includes metadata-specific information
    struct EnhancedOverlayFrameData {
        let baseData: DebugAnnotator.OverlayFrameData
        let metadata: ProcessingMetadata
        let currentTime: CMTime
        let activeTrajectories: [ProcessingTrajectoryData]
        let currentRally: RallySegment?
        let physicsValidation: PhysicsValidationData?
        let classificationResults: [ProcessingClassificationResult]
    }

    // MARK: - Enhanced Overlay Processing

    private func appendWithEnhancedOverlays(
        sampleBuffer: CMSampleBuffer,
        enhancedData: EnhancedOverlayFrameData,
        annotator: DebugAnnotator,
        frameSize: CGSize
    ) throws {
        // Use base DebugAnnotator functionality first
        try annotator.append(sampleBuffer: sampleBuffer, overlay: enhancedData.baseData)

        // Additional enhanced overlays could be drawn here in future
        // For now, we rely on the comprehensive base overlay system
        // Future enhancements could include:
        // - Rally segment timeline visualization
        // - Physics validation confidence meters
        // - Movement classification indicators
        // - Quality metrics overlay
    }

    private func createEnhancedOverlayFrameData(
        for time: CMTime,
        metadata: ProcessingMetadata
    ) -> EnhancedOverlayFrameData {
        let timeSeconds = CMTimeGetSeconds(time)

        // Find relevant trajectory data for this timestamp
        let relevantTrajectories = metadata.trajectoryData?.filter { trajectory in
            timeSeconds >= trajectory.startTime && timeSeconds <= trajectory.endTime
        } ?? []

        // Find relevant rally segment
        let currentRally = metadata.rallySegments.first { rally in
            timeSeconds >= rally.startTime && timeSeconds <= rally.endTime
        }

        // Find physics validation for this timestamp
        let physicsValidation = metadata.physicsValidation?.first { validation in
            abs(validation.timestamp - timeSeconds) < 0.1 // Within 100ms
        }

        // Find classification results for this timestamp
        let classificationResults = metadata.classificationResults?.filter { classification in
            abs(classification.timestamp - timeSeconds) < 0.1 // Within 100ms
        } ?? []

        // Create base overlay data
        let baseData = createOverlayFrameData(for: time, from: metadata)

        return EnhancedOverlayFrameData(
            baseData: baseData,
            metadata: metadata,
            currentTime: time,
            activeTrajectories: relevantTrajectories,
            currentRally: currentRally,
            physicsValidation: physicsValidation,
            classificationResults: classificationResults
        )
    }

    // MARK: - Base Overlay Creation (Compatible with DebugAnnotator)

    private func createOverlayFrameData(for time: CMTime, from metadata: ProcessingMetadata) -> DebugAnnotator.OverlayFrameData {
        let timeSeconds = CMTimeGetSeconds(time)

        // Find relevant trajectory data for this timestamp
        let relevantTrajectories = metadata.trajectoryData?.filter { trajectory in
            timeSeconds >= trajectory.startTime && timeSeconds <= trajectory.endTime
        } ?? []

        // Find relevant rally segment
        let currentRally = metadata.rallySegments.first { rally in
            timeSeconds >= rally.startTime && timeSeconds <= rally.endTime
        }

        // Find physics validation for this timestamp
        let physicsValidation = metadata.physicsValidation?.first { validation in
            abs(validation.timestamp - timeSeconds) < 0.1 // Within 100ms
        }

        // Create mock detections from trajectory points (for visualization)
        let detections = createDetectionsFromTrajectories(
            trajectories: relevantTrajectories,
            timestamp: timeSeconds
        )

        // Create mock tracked ball from trajectory data
        let trackedBall = createTrackedBallFromTrajectories(
            trajectories: relevantTrajectories,
            timestamp: timeSeconds
        )

        // Determine if projectile based on physics validation
        let isProjectile = physicsValidation?.isValid ?? false

        // Determine if in rally
        let inRally = currentRally != nil

        return DebugAnnotator.OverlayFrameData(
            detections: detections,
            track: trackedBall,
            isProjectile: isProjectile,
            inRally: inRally,
            time: time
        )
    }

    private func createDetectionsFromTrajectories(
        trajectories: [ProcessingTrajectoryData],
        timestamp: Double
    ) -> [DetectionResult] {
        return trajectories.compactMap { trajectory in
            // Find the trajectory point closest to this timestamp
            guard let closestPoint = trajectory.points.min(by: { point1, point2 in
                abs(point1.timestamp - timestamp) < abs(point2.timestamp - timestamp)
            }) else { return nil }

            // Only include if within a reasonable time window (33ms for 30fps)
            guard abs(closestPoint.timestamp - timestamp) < 0.033 else { return nil }

            // Create a bounding box around the point (approximate size)
            let boxSize: CGFloat = 0.05 // 5% of frame size
            let bbox = CGRect(
                x: closestPoint.position.x - boxSize / 2,
                y: closestPoint.position.y - boxSize / 2,
                width: boxSize,
                height: boxSize
            )

            return DetectionResult(
                bbox: bbox,
                confidence: Float(closestPoint.confidence),
                timestamp: closestPoint.cmTime
            )
        }
    }

    private func createTrackedBallFromTrajectories(
        trajectories: [ProcessingTrajectoryData],
        timestamp: Double
    ) -> KalmanBallTracker.TrackedBall? {
        // Find the most confident trajectory at this timestamp
        guard let bestTrajectory = trajectories.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }

        // Get recent points from this trajectory (last 30 points for trail visualization)
        let recentPoints = bestTrajectory.points
            .filter { $0.timestamp <= timestamp }
            .suffix(30)
            .map { ($0.position, $0.cmTime) }

        guard !recentPoints.isEmpty else { return nil }

        // Create a mock tracked ball with the recent positions
        return KalmanBallTracker.TrackedBall(
            positions: recentPoints
        )
    }
}

// MARK: - Debug Export Errors

enum DebugExportError: Error, LocalizedError {
    case exportInProgress
    case noVideoTrack
    case readerFailed
    case metadataNotFound(UUID)
    case invalidMetadata(String)
    case exportDirectoryCreationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .exportInProgress:
            return "Another export operation is already in progress"
        case .noVideoTrack:
            return "No video track found in the input file"
        case .readerFailed:
            return "Failed to read video frames"
        case .metadataNotFound(let videoId):
            return "Metadata not found for video ID: \(videoId)"
        case .invalidMetadata(let reason):
            return "Invalid metadata: \(reason)"
        case .exportDirectoryCreationFailed(let error):
            return "Failed to create debug exports directory: \(error.localizedDescription)"
        }
    }
}

// MARK: - Convenience Extensions

extension DebugVideoExporter {

    /// Check if debug exports directory exists and create if needed
    static func ensureDebugExportsDirectory() throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let debugExportsURL = documentsURL.appendingPathComponent("DebugExports", isDirectory: true)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: debugExportsURL.path, isDirectory: &isDirectory)

        if !exists || !isDirectory.boolValue {
            do {
                try FileManager.default.createDirectory(
                    at: debugExportsURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw DebugExportError.exportDirectoryCreationFailed(error)
            }
        }
    }

    /// Get the debug exports directory URL
    static func debugExportsDirectory() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("DebugExports", isDirectory: true)
    }

    /// List all debug export files
    static func listDebugExports() -> [URL] {
        let debugExportsURL = debugExportsDirectory()

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: debugExportsURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            // Return .mov files sorted by modification date (newest first)
            return files
                .filter { $0.pathExtension.lowercased() == "mov" }
                .sorted { url1, url2 in
                    let date1 = try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let date2 = try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
                }
        } catch {
            print("DebugVideoExporter: Failed to list debug exports: \(error)")
            return []
        }
    }

    /// Delete a debug export file
    static func deleteDebugExport(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Get total size of debug exports directory
    static func debugExportsDirectorySize() -> Int64 {
        let files = listDebugExports()
        return files.compactMap { url in
            try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0) { $0 + Int64($1) }
    }
}

#endif // DEBUG