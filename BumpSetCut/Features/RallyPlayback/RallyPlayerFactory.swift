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
    static func createRallyPlayer(for videoMetadata: VideoMetadata, mediaStore: MediaStore) -> some View {
        if videoMetadata.hasMetadata {
            RallyPlayerView(videoMetadata: videoMetadata, mediaStore: mediaStore)
        } else {
            VideoPlayerView(videoURL: videoMetadata.originalURL)
        }
    }

    /// Creates a rally player with session tracking
    static func createTrackedRallyPlayer(for videoMetadata: VideoMetadata, mediaStore: MediaStore) -> some View {
        TrackedRallyPlayer(videoMetadata: videoMetadata, mediaStore: mediaStore)
    }
}

// MARK: - Tracked Rally Player

@MainActor
struct TrackedRallyPlayer: View {
    let videoMetadata: VideoMetadata
    let mediaStore: MediaStore
    @State private var startTime = Date()

    var body: some View {
        RallyPlayerFactory.createRallyPlayer(for: videoMetadata, mediaStore: mediaStore)
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
        ),
        mediaStore: MediaStore()
    )
}
#endif
