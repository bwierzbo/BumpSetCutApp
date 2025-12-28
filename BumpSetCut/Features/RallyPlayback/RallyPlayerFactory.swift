//
//  RallyPlayerFactory.swift
//  BumpSetCut
//
//  Factory for creating the appropriate rally player view based on metadata availability
//

import SwiftUI

@MainActor
struct RallyPlayerFactory {
    /// Creates the appropriate rally player view based on metadata availability
    @ViewBuilder
    static func createRallyPlayer(for videoMetadata: VideoMetadata) -> some View {
        if videoMetadata.hasMetadata {
            RallyPlayerView(videoMetadata: videoMetadata)
        } else {
            VideoPlayerView(videoURL: videoMetadata.originalURL)
        }
    }

    /// Creates a rally player with session tracking
    static func createTrackedRallyPlayer(for videoMetadata: VideoMetadata) -> some View {
        TrackedRallyPlayer(videoMetadata: videoMetadata)
    }
}

// MARK: - Tracked Rally Player

@MainActor
struct TrackedRallyPlayer: View {
    let videoMetadata: VideoMetadata
    @State private var startTime = Date()

    var body: some View {
        RallyPlayerFactory.createRallyPlayer(for: videoMetadata)
            .onAppear {
                startTime = Date()
                print("Rally player opened for: \(videoMetadata.displayName)")
            }
            .onDisappear {
                let duration = Date().timeIntervalSince(startTime)
                print("Rally player session ended - Duration: \(String(format: "%.1f", duration))s")
            }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    RallyPlayerFactory.createRallyPlayer(
        for: VideoMetadata(
            fileName: "sample.mp4",
            customName: nil,
            folderPath: "",
            createdDate: Date(),
            fileSize: 0,
            duration: 120.0
        )
    )
}
#endif
