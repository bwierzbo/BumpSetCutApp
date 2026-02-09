//
//  VideoPlayerView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import SwiftUI
import AVKit
import AVFoundation

struct VideoPlayerView: View {
    let videoURL: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var player: AVPlayer?

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.bscMediaBackground.ignoresSafeArea()

                createVideoPlayer(size: geometry.size)

                // Close button overlay
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.8), .black.opacity(0.3))
                        }
                        .padding()
                    }
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: setupPlayer)
        .onDisappear(perform: cleanupPlayer)
    }
}

// MARK: - Video Player
private extension VideoPlayerView {
    func createVideoPlayer(size: CGSize) -> some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: isPortrait ? .fit : .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                createLoadingView()
            }
        }
    }

    func createLoadingView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            Text("Loading video...")
                .foregroundColor(.white)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Player Management
private extension VideoPlayerView {
    func setupPlayer() {
        // Ensure audio session is active for this player
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ Warning: Could not activate audio session: \(error)")
        }
        
        let avPlayer = AVPlayer(url: videoURL)
        
        // Enable audio output explicitly
        avPlayer.volume = 1.0
        avPlayer.isMuted = false
        
        player = avPlayer
        
        // Auto-play the video
        avPlayer.play()
    }
    
    func cleanupPlayer() {
        player?.pause()
        player = nil
    }
}
