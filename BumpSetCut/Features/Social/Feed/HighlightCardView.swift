//
//  HighlightCardView.swift
//  BumpSetCut
//
//  Full-screen card for a single highlight in the social feed.
//  Supports multi-rally posts with horizontal carousel.
//

import SwiftUI
import AVKit

struct HighlightCardView: View {
    let highlight: Highlight
    var isActive: Bool = true
    let onLike: () -> Void
    let onComment: () -> Void
    let onProfile: (String) -> Void
    var onDelete: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var showDeleteConfirmation = false
    @State private var showLikeHeart = false
    @State private var currentVideoPage = 0
    @State private var isPaused = false
    @State private var showPauseIcon = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var zoomOffset: CGSize = .zero
    @State private var lastZoomOffset: CGSize = .zero

    private var videoURLs: [URL] { highlight.allVideoURLs }
    private var isMultiVideo: Bool { videoURLs.count > 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.bscMediaBackground.ignoresSafeArea()

                // Video content (single or carousel) with zoom
                Group {
                    if isMultiVideo {
                        multiVideoCarousel(size: geo.size)
                    } else {
                        singleVideoView(size: geo.size)
                    }
                }
                .scaleEffect(zoomScale)
                .offset(zoomOffset)
                .gesture(pinchGesture)

                // Tap gestures layer
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onLike()
                        showLikeHeart = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            showLikeHeart = false
                        }
                    }
                    .onTapGesture(count: 1) {
                        togglePlayback()
                    }

                // Like heart animation
                if showLikeHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.3), radius: 8)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: showLikeHeart)
                }

                // Pause icon
                if showPauseIcon {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.4), radius: 10)
                        .transition(.opacity)
                }

                // Page indicator dots at bottom for multi-video
                if isMultiVideo {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(0..<videoURLs.count, id: \.self) { i in
                                Circle()
                                    .fill(i == currentVideoPage ? Color.white : Color.white.opacity(0.35))
                                    .frame(width: 7, height: 7)
                                    .animation(.easeInOut(duration: 0.2), value: currentVideoPage)
                            }
                        }
                        .padding(.horizontal, BSCSpacing.md)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                        .padding(.bottom, BSCSpacing.huge + 8)
                    }
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
                                    AvatarView(url: highlight.author?.avatarURL, name: highlight.author?.username ?? "?", size: 32)

                                    Text(highlight.author?.username ?? "Unknown")
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
                            Label("\(String(format: "%.1f", highlight.rallyMetadata.duration))s", systemImage: "timer")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.leading, BSCSpacing.md)

                        Spacer()

                        // Right: action buttons
                        VStack(spacing: BSCSpacing.lg) {
                            // More menu (only shown when delete is available)
                            if onDelete != nil {
                                Menu {
                                    Button(role: .destructive) {
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete Post", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 22))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 32)
                                        .shadow(color: .black.opacity(0.4), radius: 4)
                                }
                            }

                            // Like
                            Button(action: onLike) {
                                VStack(spacing: 4) {
                                    Image(systemName: highlight.isLikedByMe ? "heart.fill" : "heart")
                                        .font(.system(size: 28))
                                        .foregroundColor(highlight.isLikedByMe ? .red : .white)

                                    if !highlight.hideLikes {
                                        Text(formatCount(highlight.likesCount))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white)
                                    }
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
        .alert("Delete Post?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete?()
            }
        } message: {
            Text("This post will be permanently removed.")
        }
        .onAppear {
            if isActive { setupPlayer() }
        }
        .onDisappear { teardownPlayer() }
        .onChange(of: isActive) { _, active in
            if active {
                setupPlayer()
                if isPaused { isPaused = false }
            } else {
                teardownPlayer()
            }
        }
        .onChange(of: currentVideoPage) { _, _ in
            if isActive { switchToCurrentPage() }
        }
    }

    // MARK: - Tap to Pause/Play

    private func togglePlayback() {
        guard let player else { return }
        isPaused.toggle()

        if isPaused {
            player.pause()
        } else {
            player.play()
        }

        // Flash the icon briefly
        withAnimation(.easeIn(duration: 0.15)) {
            showPauseIcon = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 0.3)) {
                showPauseIcon = false
            }
        }
    }

    // MARK: - Pinch to Zoom

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastZoomScale * value.magnification
                zoomScale = min(max(newScale, 1.0), 4.0)
            }
            .onEnded { _ in
                if zoomScale <= 1.05 {
                    // Snap back to normal
                    withAnimation(.easeOut(duration: 0.25)) {
                        zoomScale = 1.0
                        zoomOffset = .zero
                    }
                    lastZoomScale = 1.0
                    lastZoomOffset = .zero
                } else {
                    lastZoomScale = zoomScale
                }
            }
            .simultaneously(with:
                DragGesture()
                    .onChanged { value in
                        guard zoomScale > 1.0 else { return }
                        zoomOffset = CGSize(
                            width: lastZoomOffset.width + value.translation.width,
                            height: lastZoomOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastZoomOffset = zoomOffset
                        if zoomScale <= 1.05 {
                            withAnimation(.easeOut(duration: 0.25)) {
                                zoomOffset = .zero
                            }
                            lastZoomOffset = .zero
                        }
                    }
            )
    }

    // MARK: - Single Video

    private func singleVideoView(size: CGSize) -> some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .disabled(true)
            } else {
                VideoThumbnailView(
                    thumbnailURL: highlight.thumbnailImageURL,
                    videoURL: highlight.videoURL
                )
                .frame(width: size.width, height: size.height)
                .clipped()
            }
        }
    }

    // MARK: - Multi-Video Carousel

    private func multiVideoCarousel(size: CGSize) -> some View {
        TabView(selection: $currentVideoPage) {
            ForEach(Array(videoURLs.enumerated()), id: \.offset) { index, _ in
                Group {
                    if index == currentVideoPage, let player {
                        VideoPlayer(player: player)
                            .disabled(true)
                    } else {
                        VideoThumbnailView(
                            thumbnailURL: highlight.thumbnailImageURL,
                            videoURL: videoURLs[index]
                        )
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Player Management

    private func setupPlayer() {
        guard player == nil else {
            if !isPaused { player?.play() }
            return
        }
        let url = videoURLs.isEmpty ? highlight.videoURL : videoURLs[currentVideoPage]
        let avPlayer = AVPlayer(url: url)
        avPlayer.isMuted = false
        player = avPlayer
        avPlayer.play()

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            avPlayer.seek(to: .zero)
            avPlayer.play()
        }
    }

    private func switchToCurrentPage() {
        isPaused = false
        // Reset zoom on page switch
        zoomScale = 1.0
        lastZoomScale = 1.0
        zoomOffset = .zero
        lastZoomOffset = .zero
        teardownPlayer()
        setupPlayer()
    }

    private func teardownPlayer() {
        player?.pause()
        player = nil
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}
