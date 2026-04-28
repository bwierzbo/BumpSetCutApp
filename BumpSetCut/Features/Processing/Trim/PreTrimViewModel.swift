//
//  PreTrimViewModel.swift
//  BumpSetCut
//
//  ViewModel for the pre-processing video trim screen.
//

import SwiftUI
import AVFoundation
import Observation

@MainActor
@Observable
final class PreTrimViewModel {
    // MARK: - Dependencies
    let videoURL: URL
    private let trimService = PreTrimService()

    // MARK: - Video State
    var videoDuration: Double = 0
    var startTime: Double = 0
    var endTime: Double = 0
    var player: AVPlayer?
    var thumbnails: [UIImage] = []

    // MARK: - Export State
    var isExporting: Bool = false
    var exportProgress: Double = 0
    var exportError: String?

    // MARK: - Computed
    var selectionDuration: Double { max(0, endTime - startTime) }
    var canTrim: Bool { startTime > 0.01 || (videoDuration - endTime) > 0.01 }

    private let minSelectionDuration: Double = 3.0
    private let thumbnailCount = 20

    // MARK: - Init
    init(videoURL: URL) {
        self.videoURL = videoURL
    }

    // MARK: - Load
    func loadVideo() async {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await CMTimeGetSeconds(asset.load(.duration)), duration > 0 else { return }

        videoDuration = duration
        startTime = 0
        endTime = duration

        player = AVPlayer(url: videoURL)
        player?.actionAtItemEnd = .pause

        await generateThumbnails()
    }

    // MARK: - Scrub
    func scrubTo(time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Handle Drag
    func updateStartTime(_ newStart: Double) {
        let clamped = max(0, min(newStart, endTime - minSelectionDuration))
        startTime = clamped
        scrubTo(time: clamped)
    }

    func updateEndTime(_ newEnd: Double) {
        let clamped = min(videoDuration, max(newEnd, startTime + minSelectionDuration))
        endTime = clamped
        scrubTo(time: clamped)
    }

    // MARK: - Export
    func exportTrimmed() async -> URL? {
        isExporting = true
        exportProgress = 0
        exportError = nil

        do {
            let trimmedURL = try await trimService.exportTrimmedVideo(
                sourceURL: videoURL,
                startTime: startTime,
                endTime: endTime,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.exportProgress = progress
                    }
                }
            )
            isExporting = false
            return trimmedURL
        } catch {
            exportError = error.localizedDescription
            isExporting = false
            return nil
        }
    }

    // MARK: - Cleanup
    func cleanup() {
        player?.pause()
        player = nil
    }

    // MARK: - Thumbnails
    private func generateThumbnails() async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)

        let times: [CMTime] = (0..<thumbnailCount).map { i in
            let t = videoDuration * Double(i) / Double(thumbnailCount - 1)
            return CMTimeMakeWithSeconds(t, preferredTimescale: 600)
        }

        var result: [UIImage] = []
        for await imageResult in generator.images(for: times) {
            if let cgImage = try? imageResult.image {
                result.append(UIImage(cgImage: cgImage))
            }
        }

        thumbnails = result
    }
}
