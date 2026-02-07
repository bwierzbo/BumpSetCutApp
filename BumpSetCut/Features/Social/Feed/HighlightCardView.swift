//
//  HighlightCardView.swift
//  BumpSetCut
//
//  Full-screen card for a single highlight in the social feed.
//

import SwiftUI
import AVKit

struct HighlightCardView: View {
    let highlight: Highlight
    let onLike: () -> Void
    let onComment: () -> Void
    let onProfile: (String) -> Void

    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Video player
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                        .disabled(true) // Prevent built-in controls
                } else {
                    // Thumbnail placeholder
                    AsyncImage(url: highlight.thumbnailImageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.black
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }

                // Overlay controls
                VStack {
                    Spacer()

                    HStack(alignment: .bottom, spacing: BSCSpacing.lg) {
                        // Left: author info + caption
                        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                            // Author
                            Button {
                                onProfile(highlight.authorId)
                            } label: {
                                HStack(spacing: BSCSpacing.xs) {
                                    Circle()
                                        .fill(Color.bscSurfaceGlass)
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Text(highlight.author?.displayName.prefix(1).uppercased() ?? "?")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.white)
                                        )

                                    Text("@\(highlight.author?.username ?? "unknown")")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)

                            // Caption
                            if let caption = highlight.caption, !caption.isEmpty {
                                Text(caption)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                            }

                            // Rally metadata
                            HStack(spacing: BSCSpacing.xs) {
                                Label("\(String(format: "%.1f", highlight.rallyMetadata.duration))s", systemImage: "timer")
                                Label("\(Int(highlight.rallyMetadata.quality * 100))%", systemImage: "sparkles")
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.leading, BSCSpacing.md)

                        Spacer()

                        // Right: action buttons
                        VStack(spacing: BSCSpacing.lg) {
                            // Like
                            Button(action: onLike) {
                                VStack(spacing: 4) {
                                    Image(systemName: highlight.isLikedByMe ? "heart.fill" : "heart")
                                        .font(.system(size: 28))
                                        .foregroundColor(highlight.isLikedByMe ? .red : .white)

                                    Text(formatCount(highlight.likesCount))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)

                            // Comments
                            Button(action: onComment) {
                                VStack(spacing: 4) {
                                    Image(systemName: "bubble.right")
                                        .font(.system(size: 26))
                                        .foregroundColor(.white)

                                    Text(formatCount(highlight.commentsCount))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)

                            // Share
                            ShareLink(item: highlight.videoURL) {
                                VStack(spacing: 4) {
                                    Image(systemName: "arrowshape.turn.up.right")
                                        .font(.system(size: 26))
                                        .foregroundColor(.white)

                                    Text("Share")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, BSCSpacing.md)
                    }
                    .padding(.bottom, BSCSpacing.huge)
                }
            }
        }
        .onAppear {
            let avPlayer = AVPlayer(url: highlight.videoURL)
            avPlayer.isMuted = false
            player = avPlayer
            avPlayer.play()

            // Loop playback
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}
