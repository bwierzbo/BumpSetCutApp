//
//  MessageClipPlayerView.swift
//  BumpSetCut
//
//  Full-screen playback for a privately-sent clip. The bucket is private, so
//  every view needs a fresh signed URL.
//

import SwiftUI
import AVKit

struct MessageClipPlayerView: View {
    let path: String
    var onDismiss: () -> Void = {}

    @State private var player: AVPlayer?
    @State private var failed = false
    /// Signed URLs expire; allow exactly one silent refresh before giving up.
    @State private var didRetry = false

    private let media: any MessageMediaClient

    init(path: String, media: (any MessageMediaClient)? = nil, onDismiss: @escaping () -> Void = {}) {
        self.path = path
        self.media = media ?? SupabaseAPIClient.shared
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.bscMediaBackground.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if failed {
                VStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "video.slash")
                        .bscFont(size: 36)
                        .foregroundColor(.bscOnMediaSecondary)
                    Text("Couldn't load this clip")
                        .bscFont(size: 15)
                        .foregroundColor(.bscOnMediaSecondary)
                }
            } else {
                ProgressView()
                    .tint(.bscOnMedia)
            }

            BSCMediaCloseButton { onDismiss() }
                .padding(BSCSpacing.xs)
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let url = try await media.signedURL(forMessageClip: path)
            player = AVPlayer(url: url)
        } catch {
            if didRetry {
                failed = true
            } else {
                didRetry = true
                await load()
            }
        }
    }
}
