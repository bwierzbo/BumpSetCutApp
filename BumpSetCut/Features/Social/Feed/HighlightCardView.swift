//
//  HighlightCardView.swift
//  BumpSetCut
//
//  Full-screen card for a single highlight in the social feed.
//  Supports multi-rally posts with horizontal carousel.
//

import SwiftUI
import AVFoundation

struct HighlightCardView: View {
    let highlight: Highlight
    var isActive: Bool = true
    let onLike: () -> Void
    let onComment: () -> Void
    let onProfile: (String) -> Void
    var onDelete: (() -> Void)?
    var onLocation: ((String) -> Void)?
    /// Whether the card is laid out edge-to-edge under the bottom safe area
    /// (profile/search full-bleed contexts). False in the main feed, where the
    /// card ends above the tab bar so bottom chrome hugs the card's edge.
    var extendsUnderBottomSafeArea: Bool = true

    @State private var playerPool: [Int: AVPlayer] = [:]
    @State private var loopObservers: [Int: Any] = [:]
    @State private var showDeleteConfirmation = false
    @State private var showReportSheet = false
    @State private var showBlockAlert = false
    @State private var showLikeHeart = false
    @State private var currentVideoPage = 0
    @State private var isPaused = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var zoomOffset: CGSize = .zero
    @State private var lastZoomOffset: CGSize = .zero

    private let preloadRadius = 4
    private var videoURLs: [URL] { highlight.allVideoURLs }
    private var isMultiVideo: Bool { videoURLs.count > 1 }
    private var currentPlayer: AVPlayer? { playerPool[currentVideoPage] }

    /// Real device safe-area insets. The card lives in a `.ignoresSafeArea()` scroll
    /// context, so the local GeometryReader reports `.zero` — read the key window
    /// instead so overlay chrome clears the notch/Dynamic Island (esp. in landscape).
    private var deviceSafeArea: EdgeInsets {
        let insets = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
        return EdgeInsets(top: insets.top, leading: insets.left,
                          bottom: insets.bottom, trailing: insets.right)
    }

    /// Bottom clearance for chrome: the device inset when the card underlaps
    /// the bottom safe area, zero when the card already ends above the tab bar.
    private var bottomChromeInset: CGFloat {
        extendsUnderBottomSafeArea ? deviceSafeArea.bottom : 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.bscMediaBackground.ignoresSafeArea()

                // Video content (single or carousel) with zoom + tap gestures
                // Tap gestures are on the same view as the TabView so they don't block swipes
                videoContent(size: geo.size)
                    .scaleEffect(zoomScale)
                    .offset(zoomOffset)
                    .simultaneousGesture(pinchOnlyGesture)
                    .modifier(ConditionalDragModifier(isEnabled: zoomScale > 1.0, onDrag: { translation in
                        zoomOffset = CGSize(
                            width: lastZoomOffset.width + translation.width,
                            height: lastZoomOffset.height + translation.height
                        )
                    }, onEnd: {
                        lastZoomOffset = zoomOffset
                        if zoomScale <= 1.05 {
                            withAnimation(.easeOut(duration: 0.25)) {
                                zoomOffset = .zero
                            }
                            lastZoomOffset = .zero
                        }
                    }))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        UIImpactFeedbackGenerator.medium()
                        onLike()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            showLikeHeart = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                showLikeHeart = false
                            }
                        }
                    }
                    .onTapGesture(count: 1) {
                        UIImpactFeedbackGenerator.light()
                        togglePlayback()
                    }

                // Like heart animation
                if showLikeHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.bscOnMedia)
                        .shadow(color: .black.opacity(0.3), radius: 8)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                // Page indicator dots at bottom for multi-video
                if isMultiVideo {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(0..<videoURLs.count, id: \.self) { i in
                                Circle()
                                    .fill(i == currentVideoPage ? Color.bscOnMedia : Color.bscOnMedia.opacity(0.35))
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .padding(.horizontal, BSCSpacing.md)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.bscMediaScrim))
                        // Sit just above the bottom edge in landscape; clear the
                        // controls in portrait.
                        .padding(.bottom, geo.size.width > geo.size.height
                            ? bottomChromeInset + BSCSpacing.md
                            : bottomChromeInset + BSCSpacing.huge + BSCSpacing.md)
                    }
                    .allowsHitTesting(false)
                }

                // Bottom scrim so white chrome stays legible over bright video frames
                LinearGradient(
                    colors: [.clear, Color.bscMediaScrim],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Overlay controls
                overlayControls(safeArea: deviceSafeArea)
            }
            // Full-screen video is a dark context regardless of system appearance.
            .environment(\.colorScheme, .dark)
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
            if isActive { setupPlayers() }
        }
        .onDisappear { teardownAllPlayers() }
        .onChange(of: isActive) { _, active in
            if active {
                setupPlayers()
                if isPaused { isPaused = false }
            } else {
                // Just pause — don't tear down. Keeps last video frame visible
                // during scroll transitions (prevents flash to thumbnail/black).
                // Actual teardown happens in onDisappear when LazyVStack recycles.
                pauseAllPlayers()
            }
        }
        .onChange(of: currentVideoPage) { _, _ in
            if isActive { onPageChanged() }
        }
        .sheet(isPresented: $showReportSheet) {
            ReportContentSheet(
                contentType: .highlight,
                contentId: UUID(uuidString: highlight.id) ?? UUID(),
                reportedUserId: UUID(uuidString: highlight.authorId) ?? UUID()
            )
        }
        .blockUserAlert(
            isPresented: $showBlockAlert,
            username: highlight.author?.username ?? "user",
            userId: UUID(uuidString: highlight.authorId) ?? UUID()
        ) {
            try await ModerationService.shared.blockUser(
                UUID(uuidString: highlight.authorId) ?? UUID()
            )
        }
    }

    // MARK: - Overlay Controls

    private func overlayControls(safeArea: EdgeInsets) -> some View {
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
                                .foregroundColor(.bscOnMedia)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View profile of \(highlight.author?.username ?? "user")")

                    // Location tag
                    if let location = highlight.locationName, !location.isEmpty {
                        Button {
                            onLocation?(location)
                        } label: {
                            HStack(spacing: BSCSpacing.xxs) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 12))
                                Text(location)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.bscOnMedia)
                        }
                        .buttonStyle(.plain)
                        .disabled(onLocation == nil)
                        .accessibilityLabel("Played at \(location)")
                    }

                    // Caption
                    if let caption = highlight.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 14))
                            .foregroundColor(.bscOnMedia)
                            .lineLimit(2)
                    }

                    // Poll — voting happens in the comments sheet (tap to open)
                    if highlight.poll != nil {
                        Button {
                            onComment()
                        } label: {
                            HStack(spacing: BSCSpacing.xxs) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 11))
                                Text("Vote in poll")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.bscOnMedia)
                            .padding(.horizontal, BSCSpacing.sm)
                            .padding(.vertical, BSCSpacing.xxs)
                            .background(Color.bscMediaScrim, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // Rally metadata
                    Label("\(String(format: "%.1f", highlight.rallyMetadata.duration))s", systemImage: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(.bscOnMediaSecondary)
                }
                .padding(.leading, BSCSpacing.md + safeArea.leading)

                Spacer()

                // Right: action buttons
                VStack(spacing: BSCSpacing.lg) {
                    // More menu
                    Menu {
                        // Delete (only for own posts)
                        if onDelete != nil {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete Post", systemImage: "trash")
                            }
                        } else {
                            // Report and Block (for other users' posts)
                            Button {
                                showReportSheet = true
                            } label: {
                                Label("Report Post", systemImage: "exclamationmark.shield")
                            }

                            Button(role: .destructive) {
                                showBlockAlert = true
                            } label: {
                                Label("Block @\(highlight.author?.username ?? "user")", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 22))
                            .foregroundColor(.bscOnMedia)
                            .frame(width: 44, height: 32)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    }

                    // Like
                    Button {
                        UIImpactFeedbackGenerator.medium()
                        onLike()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: highlight.isLikedByMe ? "heart.fill" : "heart")
                                .font(.system(size: 28))
                                .foregroundColor(highlight.isLikedByMe ? .bscError : .white)

                            if !highlight.hideLikes {
                                Text(formatCount(highlight.likesCount))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.bscOnMedia)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(highlight.isLikedByMe ? "Unlike" : "Like")
                    .accessibilityHint("\(highlight.likesCount) likes")

                    // Comments
                    Button {
                        UIImpactFeedbackGenerator.light()
                        onComment()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "bubble.right")
                                .font(.system(size: 26))
                                .foregroundColor(.bscOnMedia)

                            Text(formatCount(highlight.commentsCount))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.bscOnMedia)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Comments")
                    .accessibilityHint("\(highlight.commentsCount) comments")

                    // Share — deep link that opens this post in the app
                    ShareLink(
                        item: highlight.deepLinkURL,
                        message: Text("Check out this rally on BumpSetCut")
                    ) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.right")
                                .font(.system(size: 26))
                                .foregroundColor(.bscOnMedia)

                            Text("Share")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.bscOnMedia)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share highlight")
                }
                .padding(.trailing, BSCSpacing.md + safeArea.trailing)
            }
            .padding(.bottom, bottomChromeInset + BSCSpacing.huge)
            // Halo so chrome stays crisp over bright video frames, not just over the scrim.
            .shadow(color: .black.opacity(0.5), radius: 3)
        }
    }

    // MARK: - Tap to Pause/Play

    private func togglePlayback() {
        guard let player = currentPlayer else { return }
        isPaused.toggle()

        if isPaused {
            player.pause()
        } else {
            player.play()
        }
    }

    // MARK: - Pinch to Zoom

    /// Pinch gesture: uses simultaneousGesture so it doesn't block TabView swipes.
    private var pinchOnlyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastZoomScale * value.magnification
                zoomScale = min(max(newScale, 1.0), 4.0)
            }
            .onEnded { _ in
                if zoomScale <= 1.05 {
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
    }

    @ViewBuilder
    private func videoContent(size: CGSize) -> some View {
        if isMultiVideo {
            multiVideoCarousel(size: size)
        } else {
            singleVideoView(size: size)
        }
    }

    // MARK: - Single Video

    private func singleVideoView(size: CGSize) -> some View {
        ZStack {
            // Thumbnail always underneath to prevent flash
            VideoThumbnailView(
                thumbnailURL: highlight.thumbnailImageURL,
                videoURL: highlight.videoURL,
                contentMode: .fit
            )
            .frame(width: size.width, height: size.height)
            .clipped()

            // Video player overlay
            if let player = playerPool[0] {
                CustomVideoPlayerView(
                    player: player,
                    gravity: .resizeAspect,
                    onReadyForDisplay: { _ in }
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Multi-Video Carousel

    private func multiVideoCarousel(size: CGSize) -> some View {
        TabView(selection: $currentVideoPage) {
            ForEach(Array(videoURLs.enumerated()), id: \.offset) { index, url in
                ZStack {
                    // Thumbnail always underneath — prevents flash on page switch
                    VideoThumbnailView(
                        thumbnailURL: index == 0 ? highlight.thumbnailImageURL : nil,
                        videoURL: url,
                        contentMode: .fit
                    )
                    .frame(width: size.width, height: size.height)
                    .clipped()

                    // Preloaded video player overlay (within ±4 window)
                    if let pagePlayer = playerPool[index] {
                        CustomVideoPlayerView(
                            player: pagePlayer,
                            gravity: .resizeAspect,
                            onReadyForDisplay: { _ in }
                        )
                        .allowsHitTesting(false)
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

    // MARK: - Player Pool Management

    private func setupPlayers() {
        guard playerPool.isEmpty else {
            // Already set up — seek to start and resume
            currentVideoPage = 0
            for (_, player) in playerPool {
                player.seek(to: .zero)
            }
            isPaused = false
            playerPool[0]?.play()
            return
        }
        if isMultiVideo {
            updatePlayerPool(activePage: currentVideoPage)
        } else {
            // Single video — just one player at index 0
            let url = videoURLs.first ?? highlight.videoURL
            let avPlayer = makeLoopingPlayer(url: url, pageIndex: 0)
            avPlayer.play()
            playerPool[0] = avPlayer
        }
    }

    private func updatePlayerPool(activePage: Int) {
        let pageCount = videoURLs.count
        guard pageCount > 0 else { return }
        let lo = max(0, activePage - preloadRadius)
        let hi = min(pageCount - 1, activePage + preloadRadius)
        let visibleRange = lo...hi

        // Remove players outside the window
        for pageIndex in playerPool.keys where !visibleRange.contains(pageIndex) {
            if let observer = loopObservers.removeValue(forKey: pageIndex) {
                NotificationCenter.default.removeObserver(observer)
            }
            playerPool[pageIndex]?.pause()
            playerPool[pageIndex]?.replaceCurrentItem(with: nil)
            playerPool.removeValue(forKey: pageIndex)
        }

        // Create players for pages in the window
        for pageIndex in visibleRange {
            guard pageIndex < videoURLs.count else { continue }
            let isActivePage = (pageIndex == activePage)
            if playerPool[pageIndex] == nil {
                let url = videoURLs[pageIndex]
                let avPlayer = makeLoopingPlayer(url: url, pageIndex: pageIndex)

                if isActivePage && !isPaused {
                    avPlayer.seek(to: .zero)
                    avPlayer.play()
                } else {
                    avPlayer.pause()
                }
                playerPool[pageIndex] = avPlayer
            } else {
                // The active page restarts from the beginning; off-screen pages
                // pause and rewind so they replay from the start next time too.
                if isActivePage {
                    playerPool[pageIndex]?.seek(to: .zero)
                    if !isPaused { playerPool[pageIndex]?.play() }
                } else {
                    playerPool[pageIndex]?.pause()
                    playerPool[pageIndex]?.seek(to: .zero)
                }
            }
        }
    }

    private func makeLoopingPlayer(url: URL, pageIndex: Int) -> AVPlayer {
        let avPlayer = AVPlayer(url: url)
        avPlayer.isMuted = false
        avPlayer.automaticallyWaitsToMinimizeStalling = false

        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { [weak avPlayer] _ in
            avPlayer?.seek(to: .zero)
            avPlayer?.play()
        }
        loopObservers[pageIndex] = observer

        return avPlayer
    }

    private func onPageChanged() {
        isPaused = false
        // Reset zoom on page switch
        zoomScale = 1.0
        lastZoomScale = 1.0
        zoomOffset = .zero
        lastZoomOffset = .zero
        updatePlayerPool(activePage: currentVideoPage)
    }

    private func pauseAllPlayers() {
        for (_, player) in playerPool {
            player.pause()
        }
    }

    private func teardownAllPlayers() {
        for (pageIndex, player) in playerPool {
            if let observer = loopObservers[pageIndex] {
                NotificationCenter.default.removeObserver(observer)
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        playerPool.removeAll()
        loopObservers.removeAll()
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Conditional Drag Modifier

/// Only attaches a DragGesture when enabled, so it doesn't block other gestures (like TabView swipe) when disabled.
private struct ConditionalDragModifier: ViewModifier {
    let isEnabled: Bool
    let onDrag: (CGSize) -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.gesture(
                DragGesture()
                    .onChanged { value in onDrag(value.translation) }
                    .onEnded { _ in onEnd() }
            )
        } else {
            content
        }
    }
}
