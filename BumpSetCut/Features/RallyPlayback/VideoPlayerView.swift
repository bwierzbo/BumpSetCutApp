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
    @State private var dragOffset: CGSize = .zero

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Media layer - full-bleed (ignores safe area)
            GeometryReader { geometry in
                ZStack {
                    Color.bscMediaBackground
                    createVideoPlayer(size: geometry.size)
                }
            }
            .ignoresSafeArea()
            .offset(y: dragOffset.height)
            .opacity(dismissDragOpacity)
            .contentShape(Rectangle())
            .simultaneousGesture(dismissDragGesture)

            // Close button - kept inside the safe area so it isn't tucked under the notch
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8), .black.opacity(0.3))
            }
            .padding()
        }
        .onAppear(perform: setupPlayer)
        .onDisappear(perform: cleanupPlayer)
    }

    // MARK: - Swipe-to-Dismiss

    /// Fade the video slightly as it's pulled down, for a "release to dismiss" feel.
    private var dismissDragOpacity: Double {
        let progress = min(max(dragOffset.height / 400, 0), 1)
        return 1.0 - progress * 0.4
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Only track downward drags
                guard value.translation.height > 0 else { return }
                dragOffset = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                let pulledFarEnough = value.translation.height > 150
                let flickedDown = value.velocity.height > 600
                if pulledFarEnough || flickedDown {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
                }
            }
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
        // Release the audio session activated in setupPlayer. Leaving it active holds the
        // system audio focus after dismissal, contradicting the app-wide design that avoids
        // a persistent .playback session (see BumpSetCutApp note) and risking the keyboard
        // stall regression documented there.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ Warning: Could not deactivate audio session: \(error)")
        }
    }
}
