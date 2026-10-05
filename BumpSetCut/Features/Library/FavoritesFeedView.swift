//
//  FavoritesFeedView.swift
//  BumpSetCut
//
//  Full-screen vertical feed of favorited rally clips, opened from
//  FavoritesGridView. Tap to pause, long-press to trim.
//

import SwiftUI
import AVFoundation
import CoreMedia

// MARK: - Full-Screen Feed

struct FavoritesFeedView: View {
    let videos: [VideoMetadata]
    let startIndex: Int
    let onDismiss: () -> Void

    @State private var currentIndex: Int?
    @State private var hasScrolledToStart = false
    @State private var playerPool = LoopingPlayerPool<Int>(automaticallyWaitsToMinimizeStalling: false)
    // Indices whose player has rendered a frame — their thumbnails unmount so
    // they can't peek out around the video layer during rotation.
    @State private var readyPlayers: Set<Int> = []

    // Tap-to-pause
    @State private var isPaused = false

    // Trim
    @State private var isTrimmingMode = false
    @State private var trimBefore: Double = 0
    @State private var trimAfter: Double = 0
    @State private var clipDuration: Double = 0
    @State private var savedTrims: [Int: RallyTrimAdjustment] = [:]

    // One-time discoverability hint for the long-press trim gesture.
    @State private var showTrimHint = false

    var body: some View {
        ZStack {
            Color.bscMediaBackground.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                        videoCard(video: video, index: index)
                            .containerRelativeFrame(.vertical)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentIndex)
            .ignoresSafeArea()
            .allowsHitTesting(!isTrimmingMode)

            // Overlay
            if !isTrimmingMode {
                VStack(spacing: BSCSpacing.md) {
                    HStack {
                        if videos.count > 1 {
                            Text("\((currentIndex ?? startIndex) + 1)/\(videos.count)")
                                .bscFont(size: 13, weight: .semibold, design: .monospaced)
                                .foregroundColor(.bscOnMedia)
                                .padding(.horizontal, BSCSpacing.sm)
                                .padding(.vertical, BSCSpacing.xs)
                                .background(Color.bscMediaScrim)
                                .clipShape(Capsule())
                                .accessibilityLabel("Rally \((currentIndex ?? startIndex) + 1) of \(videos.count)")
                                .accessibilityIdentifier(AccessibilityID.Favorites.feedCounter)
                        }

                        Spacer()

                        BSCMediaCloseButton { onDismiss() }
                            .accessibilityIdentifier(AccessibilityID.Favorites.feedClose)
                    }
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.top, BSCSpacing.md)

                    Spacer()

                    // One-time "hold to trim" hint, anchored above the name row.
                    if showTrimHint {
                        TrimCoachMark(text: "Hold anywhere to trim")
                            .allowsHitTesting(false)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Bottom: video name
                    HStack {
                        if let idx = currentIndex, idx < videos.count {
                            Text(videos[idx].displayName)
                                .bscFont(size: 14, weight: .semibold)
                                .foregroundColor(.bscOnMedia)
                                .lineLimit(1)
                                .accessibilityIdentifier(AccessibilityID.Favorites.feedVideoName)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.bottom, BSCSpacing.huge)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }

            // Pause icon
            if isPaused && !isTrimmingMode {
                Image(systemName: "play.fill")
                    .bscFont(size: 60)
                    .foregroundColor(.bscOnMediaSecondary)
                    .shadow(color: Color.bscMediaScrimBase.opacity(0.33), radius: 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier(AccessibilityID.Favorites.feedPauseIcon)
            }

            // Trim overlay
            if isTrimmingMode {
                if let idx = currentIndex, idx < videos.count {
                    RallyTrimOverlay(
                        trimBefore: $trimBefore,
                        trimAfter: $trimAfter,
                        trimRotation: .constant(0),
                        trimZoom: .constant(1),
                        rallyStartTime: 0,
                        rallyEndTime: clipDuration,
                        videoURL: videos[idx].originalURL,
                        videoDuration: clipDuration,
                        onScrub: { time in
                            if let player = playerPool.player(for: idx) {
                                player.seek(to: CMTimeMakeWithSeconds(time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        },
                        onConfirm: { confirmTrim() },
                        onCancel: { cancelTrim() },
                        showsAngleControl: false,
                        showsZoomControl: false
                    )
                    .transition(.opacity)
                }
            }
        }
        // Full-screen video: hide the status bar and home indicator; edge
        // swipes need a second swipe so they don't fight the paging scroll.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .vertical)
        .onAppear {
            if !hasScrolledToStart {
                currentIndex = startIndex
                hasScrolledToStart = true
            }
        }
        .task {
            await maybeShowTrimHint()
        }
        .onChange(of: currentIndex) { oldIdx, newIdx in
            if let old = oldIdx { playerPool.player(for: old)?.pause() }
            isPaused = false
            isTrimmingMode = false
            if let new = newIdx { setupPlayer(at: new) }
        }
        .onDisappear {
            playerPool.teardownAll()
            readyPlayers.removeAll()
        }
    }

    // MARK: - Video Card

    private func videoCard(video: VideoMetadata, index: Int) -> some View {
        ZStack {
            // Only until the first video frame renders — a thumbnail left mounted
            // behind a live video peeks out around it during rotation (the SwiftUI
            // image and the AVPlayerLayer resize on different schedules).
            if !readyPlayers.contains(index) {
                VideoThumbnailView(
                    thumbnailURL: nil,
                    videoURL: video.originalURL,
                    contentMode: .fit
                )
            }

            if let player = playerPool.player(for: index) {
                CustomVideoPlayerView(
                    player: player,
                    gravity: .resizeAspect,
                    onReadyForDisplay: { ready in
                        guard ready != readyPlayers.contains(index) else { return }
                        // Async: updateUIView reports synchronously during view updates
                        DispatchQueue.main.async {
                            if ready { readyPlayers.insert(index) } else { readyPlayers.remove(index) }
                        }
                    }
                )
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isTrimmingMode, currentIndex == index else { return }
            togglePause()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard !isTrimmingMode, currentIndex == index else { return }
                    enterTrimMode(at: index)
                }
        )
        // VoiceOver equivalents of tap-to-pause and long-press-to-trim.
        .accessibilityElement()
        .accessibilityLabel("Rally \(index + 1) video")
        .accessibilityValue(currentIndex == index && isPaused ? "Paused" : "")
        .accessibilityAction(named: "Play or pause") {
            guard !isTrimmingMode, currentIndex == index else { return }
            togglePause()
        }
        .accessibilityAction(named: "Trim rally") {
            guard !isTrimmingMode, currentIndex == index else { return }
            enterTrimMode(at: index)
        }
        .onAppear { if currentIndex == index { setupPlayer(at: index) } }
    }

    // MARK: - Pause

    private func togglePause() {
        guard let idx = currentIndex, let player = playerPool.player(for: idx) else { return }
        if isPaused {
            player.play()
        } else {
            player.pause()
        }
        withAnimation(.bscQuick) { isPaused.toggle() }
    }

    // MARK: - Trim Hint

    /// Surface the long-press trim affordance once, then never again. Runs inside
    /// the view's `.task`, so closing the feed cancels the sleeps — the flag is
    /// burned only if the hint actually appears.
    private func maybeShowTrimHint() async {
        guard !videos.isEmpty, !AppSettings.shared.hasSeenFavoritesTrimHint else { return }

        guard (try? await Task.sleep(nanoseconds: 600_000_000)) != nil else { return }

        AppSettings.shared.hasSeenFavoritesTrimHint = true
        withAnimation(.bscStandard) { showTrimHint = true }

        guard (try? await Task.sleep(nanoseconds: 3_500_000_000)) != nil else { return }
        withAnimation(.bscStandard) { showTrimHint = false }
    }

    // MARK: - Trim

    private func enterTrimMode(at index: Int) {
        guard index < videos.count else { return }

        UIImpactFeedbackGenerator.medium()
        withAnimation(.bscQuick) { showTrimHint = false }

        // Pause playback
        playerPool.player(for: index)?.pause()
        isPaused = false

        // Load clip duration
        let asset = AVURLAsset(url: videos[index].originalURL)
        Task {
            let duration = try? await asset.load(.duration)
            let secs = duration.map { CMTimeGetSeconds($0) } ?? 0
            // An indefinite duration reads as NaN, which max() would keep.
            clipDuration = secs.isFinite ? max(secs, 0.1) : 0.1

            // Load saved trim
            let videoId = videos[index].id
            let store = MetadataStore.shared
            let trims = store.loadTrimAdjustments(for: videoId)
            if let adj = trims[0] {
                trimBefore = adj.before
                trimAfter = adj.after
            } else {
                trimBefore = 0
                trimAfter = 0
            }

            withAnimation(.bscQuick) { isTrimmingMode = true }
        }
    }

    private func confirmTrim() {
        guard let idx = currentIndex, idx < videos.count else { return }
        let videoId = videos[idx].id
        let adjustment = RallyTrimAdjustment(before: trimBefore, after: trimAfter)
        PersistenceMonitor.shared.attempt("favorite trim", retryKey: "trims-\(videoId)") {
            try MetadataStore.shared.saveTrimAdjustments([0: adjustment], for: videoId)
        }
        savedTrims[idx] = adjustment

        withAnimation(.bscQuick) { isTrimmingMode = false }
        applyTrimAndPlay(at: idx)
    }

    private func cancelTrim() {
        withAnimation(.bscQuick) { isTrimmingMode = false }
        if let idx = currentIndex {
            applyTrimAndPlay(at: idx)
        }
    }

    private func applyTrimAndPlay(at index: Int) {
        guard let player = playerPool.player(for: index) else { return }
        let trim = savedTrims[index]

        // trimBefore > 0 means extend before start (not applicable for favorites clips starting at 0)
        // trimBefore < 0 means cut into clip from start
        // trimAfter > 0 means extend after end (not applicable)
        // trimAfter < 0 means cut from end
        let startTime = max(0, -(trim?.before ?? 0))
        let endTime = clipDuration + (trim?.after ?? 0)
        let start = CMTimeMakeWithSeconds(startTime, preferredTimescale: 600)

        // Loop over the trimmed slice; an untrimmed end loops at end of file.
        let end = endTime < clipDuration - 0.05 ? CMTimeMakeWithSeconds(endTime, preferredTimescale: 600) : nil
        playerPool.setLoop(for: index, start: start, end: end)

        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPaused = false
    }

    // MARK: - Player Management

    private func setupPlayer(at index: Int) {
        guard index < videos.count else { return }
        // Keep the neighbours' players for a quick swipe back; a player per
        // page visited piled up until the feed closed.
        playerPool.retain(window: Set(index - 1...index + 1))
        readyPlayers.formIntersection(playerPool.players.keys)

        // Load saved trim for this clip
        if savedTrims[index] == nil {
            let store = MetadataStore.shared
            let trims = store.loadTrimAdjustments(for: videos[index].id)
            if let adj = trims[0] {
                savedTrims[index] = adj
            }
        }

        if playerPool.player(for: index) == nil {
            playerPool.player(for: index, url: videos[index].originalURL)

            // Load clip duration for trim
            let asset = AVURLAsset(url: videos[index].originalURL)
            Task {
                let duration = try? await asset.load(.duration)
                let secs = duration.map { CMTimeGetSeconds($0) } ?? 0
                if secs > 0 { clipDuration = secs }
            }
        }

        applyTrimAndPlay(at: index)
    }
}
