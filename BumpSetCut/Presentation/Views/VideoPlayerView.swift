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
    @State private var player: AVPlayer?
    
    var body: some View {
        NavigationStack{
            VStack(spacing: 0) {
                createVideoPlayer()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: createToolbar)
        }
        .onAppear(perform: setupPlayer)
        .onDisappear(perform: cleanupPlayer)
    }
}

// MARK: - Video Player
private extension VideoPlayerView {
    func createVideoPlayer() -> some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
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

// MARK: - Toolbar
private extension VideoPlayerView {
    func createToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            createCloseButton()
        }
    }
    
    func createCloseButton() -> some View {
        Button("Done") {
            dismiss()
        }
        .foregroundColor(.white)
        .fontWeight(.medium)
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
