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
    /// Send this post to someone as a direct message. Nil hides the button —
    /// signed out, or a context with no messaging.
    var onSend: (() -> Void)?
    /// Whether the card is laid out edge-to-edge under the bottom safe area
    /// (profile/search full-bleed contexts). False in the main feed, where the
    /// card ends above the tab bar so bottom chrome hugs the card's edge.
    var extendsUnderBottomSafeArea: Bool = true
    /// Hide the author, caption and action buttons (the feed's full-screen
    /// landscape); the video, page dots and gestures stay.
    var chromeHidden: Bool = false
    /// A tap paused (true) or resumed (false) the video.
    var onPlaybackToggled: ((_ paused: Bool) -> Void)?

    @State private var playerPool = LoopingPlayerPool<Int>(automaticallyWaitsToMinimizeStalling: false)
    @State private var showDeleteConfirmation = false
    @State private var showReportSheet = false
    @State private var blockTarget: BlockTarget?
    @State private var showLikeHeart = false
    @State private var currentVideoPage = 0
    @State private var isPaused = false
    @State private var zoomScale: CGFloat = 1.0
    /// Where the pinch started, so the zoom grows from under the fingers.
    @State private var zoomAnchor: UnitPoint = .center
    @State private var zoomOffset: CGSize = .zero
    /// Pages whose player has rendered a first frame — until then (or when a
    /// remote stream is buffering) a spinner shows over the thumbnail.
    @State private var readyPages: Set<Int> = []

    private let preloadRadius = 4
    private var videoURLs: [URL] { highlight.allVideoURLs }
    private var isMultiVideo: Bool { videoURLs.count > 1 }
    private var currentPlayer: AVPlayer? { playerPool.player(for: currentVideoPage) }

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
                    .scaleEffect(zoomScale, anchor: zoomAnchor)
                    .offset(zoomOffset)
                    .gesture(pinchGesture(size: geo.size))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        UIImpactFeedbackGenerator.light()
                        // Like-only (Instagram/TikTok semantics): double-tapping an
                        // already-liked post must not unlike it while playing the
                        // "liked" heart animation. The heart button stays a toggle.
                        if !highlight.isLikedByMe {
                            onLike()
                        }
                        withAnimation(.bscBounce) {
                            showLikeHeart = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            withAnimation(.bscBounce) {
                                showLikeHeart = false
                            }
                        }
                    }
                    .onTapGesture(count: 1) {
                        togglePlayback()
                    }
                    .accessibilityAction(named: "Like") {
                        if !highlight.isLikedByMe {
                            onLike()
                        }
                    }
                    .accessibilityAction(named: "Play or pause") {
                        togglePlayback()
                    }

                // Like heart animation
                if showLikeHeart {
                    Image(systemName: "heart.fill")
                        .bscFont(size: 80)
                        .foregroundColor(.bscOnMedia)
                        .shadow(color: Color.bscMediaScrimBase.opacity(0.3), radius: 8)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                // Page indicator dots for multi-video, with the chrome hidden:
                // just above the bottom edge. With the chrome showing they sit
                // in the controls stack, above the caption (overlayControls).
                if isMultiVideo && chromeHidden {
                    VStack {
                        Spacer()
                        pageDots
                            .padding(.bottom, bottomChromeInset + BSCSpacing.md)
                    }
                }

                // Bottom scrim so white chrome stays legible over bright video frames
                LinearGradient(
                    colors: [.clear, Color.bscMediaScrim],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(chromeHidden ? 0 : 1)

                // Overlay controls
                overlayControls(safeArea: deviceSafeArea)
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
                    .accessibilityHidden(chromeHidden)
            }
            // Full-screen video is a dark context regardless of system appearance.
            .environment(\.colorScheme, .dark)
        }
        // Your own post: press and hold anywhere to delete, instead of a
        // permanent button over the video.
        .contextMenu {
            if onDelete != nil {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Post", systemImage: "trash")
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
            if isActive { setupPlayers() }
        }
        .onDisappear { teardownAllPlayers() }
        .onChange(of: isActive) { _, active in
            // Zoom never follows a card across posts (tester bug: swiping out
            // and back kept the previous pinch).
            resetZoom()
            if active {
                setupPlayers()
                if isPaused { isPaused = false }
            } else {
                // Just pause — don't tear down. Keeps last video frame visible
                // during scroll transitions (prevents flash to thumbnail/black).
                // Actual teardown happens in onDisappear when LazyVStack recycles.
                playerPool.pauseAll()
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
        .blockUserAlert(target: $blockTarget)
    }

    // MARK: - Overlay Controls

    /// Which of a post's videos is showing.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<videoURLs.count, id: \.self) { i in
                Circle()
                    .fill(i == currentVideoPage ? Color.bscOnMedia : Color.bscOnMedia.opacity(0.5))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentVideoPage + 1) of \(videoURLs.count)")
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.bscMediaScrim))
        .allowsHitTesting(false)
    }

    private func overlayControls(safeArea: EdgeInsets) -> some View {
        VStack {
            Spacer()

            // Above the caption and buttons, never under them.
            if isMultiVideo {
                pageDots
                    .padding(.bottom, BSCSpacing.md)
            }

            HStack(alignment: .bottom, spacing: BSCSpacing.lg) {
                // Left: author info + caption
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    // Author
                    Button {
                        onProfile(highlight.authorId)
                    } label: {
                        HStack(spacing: BSCSpacing.xs) {
                            AvatarView(url: highlight.author?.avatarURL, name: highlight.author?.username ?? "?", size: 32)

                            (highlight.author.map { Text(verbatim: $0.username) } ?? Text("Unknown"))
                                .bscFont(size: 14, weight: .semibold)
                                .foregroundColor(.bscOnMedia)
                        }
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(highlight.author.map { Text("View profile of \($0.username)") } ?? Text("View profile"))

                    // Location tag
                    if let location = highlight.locationName, !location.isEmpty {
                        Button {
                            onLocation?(location)
                        } label: {
                            HStack(spacing: BSCSpacing.xxs) {
                                Image(systemName: "mappin.circle.fill")
                                    .bscFont(size: 12)
                                Text(location)
                                    .bscFont(size: 13, weight: .medium)
                                    .lineLimit(1)
                            }
                            .foregroundColor(.bscOnMedia)
                            .padding(.horizontal, BSCSpacing.sm)
                            .padding(.vertical, BSCSpacing.xxs)
                            .background(Color.bscMediaScrim, in: Capsule())
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onLocation == nil)
                        .accessibilityLabel("Played at \(location)")
                    }

                    // Caption
                    if let caption = highlight.caption, !caption.isEmpty {
                        Text(caption)
                            .bscFont(size: 14)
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
                                    .bscFont(size: 11)
                                Text("Vote in poll")
                                    .bscFont(size: 13, weight: .semibold)
                            }
                            .foregroundColor(.bscOnMedia)
                            .padding(.horizontal, BSCSpacing.sm)
                            .padding(.vertical, BSCSpacing.sm)
                            .background(Color.bscMediaScrim, in: Capsule())
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Rally metadata
                    Label {
                        Text(verbatim: highlight.rallyMetadata.duration.formattedSeconds())
                    } icon: {
                        Image(systemName: "timer")
                    }
                        .bscFont(size: 12)
                        .foregroundColor(.bscOnMediaSecondary)
                }
                .padding(.leading, BSCSpacing.md + safeArea.leading)

                Spacer()

                // Right: action buttons
                VStack(spacing: BSCSpacing.lg) {
                    // Report / block for other people's posts. Your own post has
                    // only one action — delete — which lives on a press-and-hold
                    // instead of a permanent button.
                    if onDelete == nil {
                        Menu {
                            Button {
                                showReportSheet = true
                            } label: {
                                Label("Report Post", systemImage: "exclamationmark.shield")
                            }

                            Button(role: .destructive) {
                                blockTarget = BlockTarget(userId: highlight.authorId, username: highlight.author?.username)
                            } label: {
                                Label {
                                    highlight.author.map { Text("Block @\($0.username)") } ?? Text("Block user")
                                } icon: {
                                    Image(systemName: "hand.raised")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .bscFont(size: 22)
                                .foregroundColor(.bscOnMedia)
                                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                                .shadow(color: Color.bscMediaScrimBase.opacity(0.4), radius: 4)
                        }
                        .accessibilityLabel("More options")
                    }

                    // Like
                    Button {
                        UIImpactFeedbackGenerator.light()
                        onLike()
                    } label: {
                        VStack(spacing: BSCSpacing.xs) {
                            Image(systemName: highlight.isLikedByMe ? "heart.fill" : "heart")
                                .bscFont(size: 28)
                                .foregroundColor(highlight.isLikedByMe ? .bscError : .bscOnMedia)

                            if !highlight.hideLikes {
                                Text(verbatim: highlight.likesCount.formattedCompact())
                                    .bscFont(size: 12, weight: .medium)
                                    .foregroundColor(.bscOnMedia)
                            }
                        }
                        .frame(minWidth: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(highlight.isLikedByMe ? "Unlike" : "Like")
                    // Only speak the count when it's on screen — hidden likes
                    // stay hidden for VoiceOver too.
                    .accessibilityValue(highlight.hideLikes ? Text(verbatim: "") : Text("\(highlight.likesCount) likes"))

                    // Comments
                    Button {
                        UIImpactFeedbackGenerator.light()
                        onComment()
                    } label: {
                        VStack(spacing: BSCSpacing.xs) {
                            Image(systemName: "bubble.right")
                                .bscFont(size: 26)
                                .foregroundColor(.bscOnMedia)

                            Text(verbatim: highlight.commentsCount.formattedCompact())
                                .bscFont(size: 12, weight: .medium)
                                .foregroundColor(.bscOnMedia)
                        }
                        .frame(minWidth: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Comments")
                    .accessibilityValue("\(highlight.commentsCount) comments")
                    .accessibilityIdentifier(AccessibilityID.Feed.commentButton)

                    // Send to a friend as a direct message
                    if let onSend {
                        Button {
                            UIImpactFeedbackGenerator.light()
                            onSend()
                        } label: {
                            VStack(spacing: BSCSpacing.xs) {
                                Image(systemName: "envelope")
                                    .bscFont(size: 26)
                                    .foregroundColor(.bscOnMedia)

                                Text("Send")
                                    .bscFont(size: 12, weight: .medium)
                                    .foregroundColor(.bscOnMedia)
                            }
                            .frame(minWidth: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send to friend")
                        .accessibilityIdentifier(AccessibilityID.Feed.sendButton)
                    }

                    // Share — deep link that opens this post in the app
                    ShareLink(
                        item: highlight.deepLinkURL,
                        message: Text("Check out this rally on BumpSetCut")
                    ) {
                        VStack(spacing: BSCSpacing.xs) {
                            Image(systemName: "arrowshape.turn.up.right")
                                .bscFont(size: 26)
                                .foregroundColor(.bscOnMedia)

                            Text("Share")
                                .bscFont(size: 12, weight: .medium)
                                .foregroundColor(.bscOnMedia)
                        }
                        .frame(minWidth: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share highlight")
                }
                .padding(.trailing, BSCSpacing.md + safeArea.trailing)
            }
            .padding(.bottom, bottomChromeInset + BSCSpacing.huge)
            // Halo so chrome stays crisp over bright video frames, not just over the scrim.
            .shadow(color: Color.bscMediaScrimBase.opacity(0.5), radius: 3)
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
        onPlaybackToggled?(isPaused)
    }

    // MARK: - Pinch to Zoom

    /// Instagram-style transient zoom: grows from under the fingers, follows
    /// them while they move, and always snaps back on release, so it can never
    /// be left stuck zoomed/panned (tester bug).
    private func pinchGesture(size: CGSize) -> FeedPinchGesture {
        FeedPinchGesture(
            onBegan: { location in
                zoomAnchor = UnitPoint(x: size.width > 0 ? location.x / size.width : 0.5,
                                       y: size.height > 0 ? location.y / size.height : 0.5)
            },
            onChanged: { scale, translation in
                zoomScale = min(max(scale, 1.0), 4.0)
                zoomOffset = translation
            },
            onEnded: {
                withAnimation(.bscStandard) {
                    zoomScale = 1.0
                    zoomOffset = .zero
                }
            }
        )
    }

    /// Hard reset (no animation) when the card leaves the screen or is recycled.
    private func resetZoom() {
        zoomScale = 1.0
        zoomAnchor = .center
        zoomOffset = .zero
    }

    @ViewBuilder
    private func videoContent(size: CGSize) -> some View {
        if isMultiVideo {
            multiVideoCarousel(size: size)
        } else {
            singleVideoView(size: size)
        }
    }

    /// Spinner while the active page's remote stream hasn't rendered a frame,
    /// so a buffering video never reads as a frozen/broken post.
    @ViewBuilder
    private func bufferingIndicator(forPage page: Int) -> some View {
        if isActive && !isPaused && !readyPages.contains(page) && currentVideoPage == page {
            ProgressView()
                .controlSize(.large)
                .tint(.bscOnMedia)
                .padding(BSCSpacing.md)
                .background(Circle().fill(Color.bscMediaScrim))
                .allowsHitTesting(false)
                .accessibilityLabel("Loading video")
        }
    }

    private func setPageReady(_ page: Int, _ ready: Bool) {
        // updateUIView reports synchronously during view updates — defer.
        DispatchQueue.main.async {
            if ready { readyPages.insert(page) } else { readyPages.remove(page) }
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
            if let player = playerPool.player(for: 0) {
                CustomVideoPlayerView(
                    player: player,
                    gravity: .resizeAspect,
                    onReadyForDisplay: { ready in
                        setPageReady(0, ready)
                    }
                )
                .allowsHitTesting(false)
            }

            bufferingIndicator(forPage: 0)
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
                    if let pagePlayer = playerPool.player(for: index) {
                        CustomVideoPlayerView(
                            player: pagePlayer,
                            gravity: .resizeAspect,
                            onReadyForDisplay: { ready in
                                setPageReady(index, ready)
                            }
                        )
                        .allowsHitTesting(false)
                    }

                    bufferingIndicator(forPage: index)
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
        guard playerPool.players.isEmpty else {
            // Already set up — seek to start and resume
            currentVideoPage = 0
            for player in playerPool.players.values {
                player.seek(to: .zero)
            }
            isPaused = false
            playerPool.player(for: 0)?.play()
            return
        }
        if isMultiVideo {
            updatePlayerPool(activePage: currentVideoPage)
        } else {
            // Single video — just one player at index 0
            playerPool.player(for: 0, url: videoURLs.first ?? highlight.videoURL).play()
        }
    }

    private func updatePlayerPool(activePage: Int) {
        let pageCount = videoURLs.count
        guard pageCount > 0 else { return }
        let lo = max(0, activePage - preloadRadius)
        let hi = min(pageCount - 1, activePage + preloadRadius)
        playerPool.retain(window: Set(lo...hi))

        // The active page restarts from the beginning; off-screen pages rewind
        // so they replay from the start next time too.
        for pageIndex in lo...hi {
            playerPool.player(for: pageIndex, url: videoURLs[pageIndex]).seek(to: .zero)
        }
        playerPool.activate(activePage, play: !isPaused)
    }

    private func onPageChanged() {
        isPaused = false
        resetZoom()
        updatePlayerPool(activePage: currentVideoPage)
    }

    private func teardownAllPlayers() {
        playerPool.teardownAll()
        readyPages.removeAll()
    }

}

// MARK: - Feed Pinch

/// Pinch for a card inside the feed's scroll views. SwiftUI's MagnifyGesture
/// lost those touches to the pager's and carousel's pans, so zoom never
/// started (tester bug, portrait and landscape); UIKit's pinch recognizes
/// alongside them and, while it lasts, switches their scrolling off so the
/// page doesn't move under the fingers.
private struct FeedPinchGesture: UIGestureRecognizerRepresentable {
    /// Where the fingers came down, in the card's coordinates.
    let onBegan: (CGPoint) -> Void
    /// Scale since the start (1 = none) and how far the fingers moved.
    let onChanged: (CGFloat, CGSize) -> Void
    let onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let pinch = UIPinchGestureRecognizer()
        pinch.delegate = context.coordinator
        return pinch
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            context.coordinator.start = location
            context.coordinator.holdScrolling(around: recognizer)
            onBegan(location)
            onChanged(recognizer.scale, .zero)
        case .changed:
            // Lifting one finger moves the centroid; only follow two.
            guard recognizer.numberOfTouches >= 2 else { return }
            let start = context.coordinator.start
            onChanged(recognizer.scale, CGSize(width: location.x - start.x, height: location.y - start.y))
        case .ended, .cancelled, .failed:
            context.coordinator.releaseScrolling()
            onEnded()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero
        /// The scroll views' pans seen alongside this pinch.
        private var scrollPans: [WeakRecognizer] = []

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if other is UIPanGestureRecognizer, other.view is UIScrollView,
               !scrollPans.contains(where: { $0.recognizer === other }) {
                scrollPans.append(WeakRecognizer(recognizer: other))
            }
            return true
        }

        /// Pans switched off for this pinch.
        private var held: [WeakRecognizer] = []

        /// Switch off scrolling for the pinch: the pans seen alongside it and
        /// those of the scroll views it sits in (the feed's pager). Switching
        /// a recognizer off also cancels a scroll in progress.
        func holdScrolling(around pinch: UIGestureRecognizer) {
            var pans = scrollPans.compactMap(\.recognizer)
            var view = pinch.view?.superview
            while let v = view {
                if let scroll = v as? UIScrollView { pans.append(scroll.panGestureRecognizer) }
                view = v.superview
            }
            for pan in pans where pan.isEnabled {
                pan.isEnabled = false
                held.append(WeakRecognizer(recognizer: pan))
            }
        }

        /// A card recycled mid-pinch must not leave the feed unscrollable.
        isolated deinit {
            releaseScrolling()
        }

        func releaseScrolling() {
            held.compactMap(\.recognizer).forEach { $0.isEnabled = true }
            held.removeAll()
            scrollPans.removeAll { $0.recognizer == nil }
        }

        private struct WeakRecognizer {
            weak var recognizer: UIGestureRecognizer?
        }
    }
}
