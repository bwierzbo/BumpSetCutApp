//
//  RallyPlayerView.swift
//  BumpSetCut
//
//  Created for Metadata Video Processing - Task 005
//

import SwiftUI
import AVKit
import AVFoundation

struct RallyPlayerView: View {
    // MARK: - Properties

    let videoMetadata: VideoMetadata
    @Environment(\.dismiss) private var dismiss
    @StateObject private var navigationState: RallyNavigationState
    @StateObject private var metadataStore = MetadataStore()

    // Smart dual-player state
    @State private var primaryPlayer: AVPlayer?
    @State private var secondaryPlayer: AVPlayer?
    @State private var isPrimaryPlayerReady = false
    @State private var isSecondaryPlayerReady = false

    // Player management
    @State private var playersInitialized = false

    // Performance tracking
    @State private var lastSeekTime = Date()
    @State private var seekPerformanceMs: Int = 0

    // Overlay state for MetadataOverlayView
    @State private var currentPlaybackTime: Double = 0.0
    @State private var showOverlay = true
    @State private var showTrajectories = true
    @State private var showRallyBoundaries = true
    @State private var showConfidenceIndicators = true

    // Rally action state
    @State private var likedRallies: Set<Int> = []
    @State private var deletedRallies: Set<Int> = []
    @State private var lastAction: (action: RallyAction, rallyIndex: Int)?

    // Video player observation
    @State private var playbackObserver: Any?
    @State private var observerPlayer: AVPlayer? // Track which player has the observer

    // Orientation tracking
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    // MARK: - Initialization
    init(videoMetadata: VideoMetadata) {
        self.videoMetadata = videoMetadata
        self._navigationState = StateObject(wrappedValue: RallyNavigationState(videoMetadata: videoMetadata))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-screen video player
                createVideoPlayer()

                // Overlaid controls (only in landscape)
                if isLandscape {
                    createLandscapeOverlay()
                        .transition(.opacity.combined(with: .scale))
                        .animation(.easeInOut(duration: 0.3), value: isLandscape)
                } else {
                    // Portrait mode with traditional layout
                    VStack(spacing: 0) {
                        Spacer()
                        createRallyControls()
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.3), value: isLandscape)
                }
            }
            .background(Color.black)
            .ignoresSafeArea(isLandscape ? .all : [])
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(isLandscape)
            .toolbar {
                if !isLandscape {
                    createToolbar()
                }
            }
        }
        .onAppear(perform: setupView)
        .onDisappear(perform: cleanupPlayers)
        .onChange(of: navigationState.currentRallyIndex) { _, newIndex in
            Task {
                await seekToRally(at: newIndex)
            }
        }
    }
}

// MARK: - Video Player

private extension RallyPlayerView {
    func createVideoPlayer() -> some View {
        Group {
            if navigationState.shouldShowLoading {
                createLoadingView()
            } else if navigationState.hasError {
                createErrorView(message: navigationState.errorMessage)
            } else if let currentPlayer = getCurrentPlayer() {
                createVideoPlayerWithOverlay(player: currentPlayer)
            } else {
                createLoadingView()
            }
        }
    }

    func getCurrentPlayer() -> AVPlayer? {
        switch navigationState.currentPlayerSlot {
        case .primary:
            return primaryPlayer
        case .secondary:
            return secondaryPlayer
        }
    }

    func createVideoPlayerWithOverlay(player: AVPlayer) -> some View {
        ZStack {
            VideoPlayer(player: player)
                .aspectRatio(contentMode: isLandscape ? .fill : .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Metadata overlay
            if showOverlay,
               let metadata = navigationState.processingMetadata,
               metadata.hasEnhancedData {
                GeometryReader { geometry in
                    MetadataOverlayView(
                        processingMetadata: metadata,
                        currentTime: currentPlaybackTime,
                        videoSize: geometry.size,
                        showTrajectories: showTrajectories,
                        showRallyBoundaries: showRallyBoundaries,
                        showConfidenceIndicators: showConfidenceIndicators
                    )
                }
                .aspectRatio(contentMode: isLandscape ? .fill : .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .gesture(
            DragGesture()
                .onEnded { gesture in
                    handleSwipeGesture(translation: gesture.translation)
                }
        )
    }

    func createLoadingView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))

            if navigationState.isLoading {
                Text("Loading rally data...")
                    .foregroundColor(.white)
                    .font(.caption)
            } else if navigationState.isVideoBuffering {
                VStack(spacing: 8) {
                    Text("Buffering video...")
                        .foregroundColor(.white)
                        .font(.caption)

                    if navigationState.videoLoadingProgress > 0 {
                        ProgressView(value: navigationState.videoLoadingProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .frame(width: 200)
                    }
                }
            }

            // Show preloading status if applicable
            if navigationState.preloadingStatus == .loading {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .green))
                        .scaleEffect(0.7)

                    Text("Preloading next rally...")
                        .foregroundColor(.green)
                        .font(.caption2)

                    if navigationState.preloadingProgress > 0 {
                        Text("\(Int(navigationState.preloadingProgress * 100))%")
                            .foregroundColor(.green)
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func createErrorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundColor(.orange)

            Text("Rally Data Unavailable")
                .font(.headline)
                .foregroundColor(.white)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Watch Full Video") {
                // Fallback to normal video playback
                setupNormalVideoPlayback()
            }
            .foregroundColor(.blue)
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rally Controls

private extension RallyPlayerView {
    func createRallyControls() -> some View {
        Group {
            if let metadata = navigationState.processingMetadata, !metadata.rallySegments.isEmpty {
                VStack(spacing: 12) {
                    createRallyProgressIndicator(metadata: metadata)
                    createRallyNavigationButtons(metadata: metadata)
                    createOverlayControls()
                    createPerformanceIndicator()
                    createPreloadingIndicator()
                }
                .padding()
                .background(Color.black.opacity(0.8))
            }
        }
    }

    func createRallyProgressIndicator(metadata: ProcessingMetadata) -> some View {
        VStack(spacing: 8) {
            // Rally indicator
            HStack {
                Text("Rally")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("\(navigationState.currentRallyIndex + 1) of \(metadata.rallySegments.count)")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                if seekPerformanceMs > 0 {
                    Text("\(seekPerformanceMs)ms")
                        .font(.caption2)
                        .foregroundColor(seekPerformanceMs < 200 ? .green : .orange)
                }
            }

            // Progress bar showing rally positions
            createRallyProgressBar(metadata: metadata)
        }
    }

    func createRallyProgressBar(metadata: ProcessingMetadata) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(metadata.rallySegments.enumerated()), id: \.offset) { index, rally in
                    let isCurrentRally = index == navigationState.currentRallyIndex
                    let isPreloaded = index == navigationState.preloadedPlayerIndex
                    let width = max(4, geometry.size.width / CGFloat(metadata.rallySegments.count) - 2)

                    Rectangle()
                        .fill(isCurrentRally ? Color.white :
                              isPreloaded ? Color.green.opacity(0.8) :
                              Color.gray.opacity(0.6))
                        .frame(width: width, height: 4)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                Task {
                                    await navigateToRally(index)
                                }
                            }
                        }
                }
            }
        }
        .frame(height: 8)
    }

    func createRallyNavigationButtons(metadata: ProcessingMetadata) -> some View {
        HStack(spacing: 32) {
            // Previous rally button
            Button(action: previousRally) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Text("Previous")
                        .font(.caption)
                }
            }
            .disabled(!navigationState.canGoPrevious)
            .foregroundColor(!navigationState.canGoPrevious ? .gray : .white)

            Spacer()

            // Rally info
            VStack(spacing: 4) {
                let currentRally = metadata.rallySegments[navigationState.currentRallyIndex]
                Text(String(format: "%.1fs", currentRally.duration))
                    .font(.headline)
                    .foregroundColor(.white)

                Text("Quality: \(String(format: "%.0f%%", currentRally.quality * 100))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Next rally button
            Button(action: nextRally) {
                HStack(spacing: 8) {
                    Text("Next")
                        .font(.caption)
                    Image(systemName: "chevron.right")
                }
            }
            .disabled(!navigationState.canGoNext)
            .foregroundColor(!navigationState.canGoNext ? .gray : .white)
        }
    }

    func createPerformanceIndicator() -> some View {
        HStack {
            if seekPerformanceMs > 0 {
                let performanceColor: Color = seekPerformanceMs < 100 ? .green :
                                            seekPerformanceMs < 200 ? .orange : .red
                HStack(spacing: 4) {
                    Circle()
                        .fill(performanceColor)
                        .frame(width: 6, height: 6)

                    Text("Seek: \(seekPerformanceMs)ms")
                        .font(.caption2)
                        .foregroundColor(performanceColor)
                }
            }

            Spacer()
        }
    }

    func createPreloadingIndicator() -> some View {
        Group {
            if navigationState.preloadingStatus != .idle {
                HStack {
                    switch navigationState.preloadingStatus {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .green))
                                .scaleEffect(0.6)

                            Text("Preloading rally \(navigationState.preloadedPlayerIndex?.advanced(by: 1) ?? 0)...")
                                .font(.caption2)
                                .foregroundColor(.green)

                            if navigationState.preloadingProgress > 0 {
                                Text("\(Int(navigationState.preloadingProgress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                    case .ready:
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)

                            Text("Rally \(navigationState.preloadedPlayerIndex?.advanced(by: 1) ?? 0) ready")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    case .failed:
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)

                            Text("Preload failed")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    case .idle:
                        EmptyView()
                    }

                    Spacer()
                }
            }
        }
    }

    func createOverlayControls() -> some View {
        VStack(spacing: 8) {
            // Main overlay toggle
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showOverlay.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showOverlay ? "eye.fill" : "eye.slash.fill")
                        Text("Overlay")
                        Text(showOverlay ? "On" : "Off")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                }

                Spacer()
            }

            // Detailed overlay controls (only shown when overlay is enabled)
            if showOverlay {
                MetadataOverlayView.createOverlayControls(
                    showTrajectories: $showTrajectories,
                    showRallyBoundaries: $showRallyBoundaries,
                    showConfidenceIndicators: $showConfidenceIndicators
                )
            }
        }
    }

    // MARK: - Landscape Overlay

    func createLandscapeOverlay() -> some View {
        VStack {
            // Top overlay with rally info and close button
            HStack {
                if let metadata = navigationState.processingMetadata, !metadata.rallySegments.isEmpty {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rally \(navigationState.currentRallyIndex + 1) of \(metadata.rallySegments.count)")
                                .font(.headline)
                                .foregroundColor(.white)

                            let currentRally = metadata.rallySegments[navigationState.currentRallyIndex]
                            Text("\(String(format: "%.1fs", currentRally.duration)) • Quality: \(String(format: "%.0f%%", currentRally.quality * 100))")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }

                        // Rally status indicators
                        HStack(spacing: 8) {
                            if likedRallies.contains(navigationState.currentRallyIndex) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.pink)
                            }
                            if deletedRallies.contains(navigationState.currentRallyIndex) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .foregroundColor(.white)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer()

            // Bottom action buttons
            createLandscapeActionButtons()
        }
    }

    func createLandscapeActionButtons() -> some View {
        let isCurrentRallyLiked = likedRallies.contains(navigationState.currentRallyIndex)
        let isCurrentRallyDeleted = deletedRallies.contains(navigationState.currentRallyIndex)

        return HStack(spacing: 40) {
            // Delete button
            Button(action: {
                performRallyAction(.delete)
            }) {
                Image(systemName: isCurrentRallyDeleted ? "trash.fill" : "trash")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        Circle()
                            .fill(isCurrentRallyDeleted ? Color.red : Color.red.opacity(0.6))
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    )
            }
            .scaleEffect(isCurrentRallyDeleted ? 1.2 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isCurrentRallyDeleted)

            // Undo button
            Button(action: {
                performRallyAction(.undo)
            }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .fill(Color.gray.opacity(0.8))
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    )
            }
            .opacity(lastAction != nil ? 1.0 : 0.4)
            .disabled(lastAction == nil)
            .animation(.easeInOut(duration: 0.2), value: lastAction != nil)

            // Like button
            Button(action: {
                performRallyAction(.like)
            }) {
                Image(systemName: isCurrentRallyLiked ? "heart.fill" : "heart")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        Circle()
                            .fill(isCurrentRallyLiked ? Color.pink : Color.green.opacity(0.6))
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    )
            }
            .scaleEffect(isCurrentRallyLiked ? 1.2 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isCurrentRallyLiked)
        }
        .padding(.bottom, 30) // Safe area padding for bottom
        .padding(.horizontal, 20)
    }
}

// MARK: - Toolbar

private extension RallyPlayerView {
    func createToolbar() -> some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarLeading) {
                createVideoInfoButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                createCloseButton()
            }
        }
    }

    func createVideoInfoButton() -> some View {
        Button {
            // Could show video and rally info
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.white)
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

// MARK: - Setup and Initialization

private extension RallyPlayerView {
    func setupView() {
        Task { @MainActor in
            await initializeNavigationState()
            await setupDualPlayerSystem()
        }
    }

    @MainActor
    func initializeNavigationState() async {
        navigationState.metadataStore = metadataStore
        await navigationState.initialize()
    }

    @MainActor
    func setupDualPlayerSystem() async {
        guard let metadata = navigationState.processingMetadata,
              !metadata.rallySegments.isEmpty else {
            return
        }

        navigationState.startVideoBuffering()

        // Setup primary player
        await setupPlayer(slot: .primary, rallyIndex: navigationState.currentRallyIndex)

        // Start preloading next rally if available
        if let nextIndex = navigationState.getNextPreloadTarget() {
            await triggerPreloading(targetIndex: nextIndex)
        }

        navigationState.completeVideoBuffering(success: true)
        playersInitialized = true

        print("RallyPlayerView: Dual player system initialized")
    }

    @MainActor
    func setupPlayer(slot: PlayerSlot, rallyIndex: Int) async {
        guard let metadata = navigationState.processingMetadata,
              rallyIndex >= 0 && rallyIndex < metadata.rallySegments.count else {
            return
        }

        // Ensure audio session is active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ Warning: Could not activate audio session: \(error)")
        }

        let videoURL = videoMetadata.originalURL
        let avPlayer = AVPlayer(url: videoURL)

        // Configure player for optimal seeking
        avPlayer.volume = 1.0
        avPlayer.isMuted = false
        avPlayer.automaticallyWaitsToMinimizeStalling = false

        // Assign to appropriate slot
        switch slot {
        case .primary:
            primaryPlayer = avPlayer
            isPrimaryPlayerReady = true
        case .secondary:
            secondaryPlayer = avPlayer
            isSecondaryPlayerReady = true
        }

        // Setup playback time observation only for current player
        if slot == navigationState.currentPlayerSlot {
            setupPlaybackTimeObserver(for: avPlayer)
        }

        // Seek to target rally
        let rally = metadata.rallySegments[rallyIndex]
        let seekTime = rally.startCMTime

        await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

        if slot == navigationState.currentPlayerSlot {
            currentPlaybackTime = CMTimeGetSeconds(seekTime)
            avPlayer.play()
        } else {
            // Preloaded player - pause at the seek position
            avPlayer.pause()
        }

        print("RallyPlayerView: Setup \(slot) player for rally \(rallyIndex + 1)")
    }

    @MainActor
    func triggerPreloading(targetIndex: Int) async {
        guard navigationState.shouldPreload(targetIndex: targetIndex) else {
            return
        }

        navigationState.triggerPreloading(for: targetIndex)

        // Use the opposite slot for preloading
        let preloadSlot: PlayerSlot = navigationState.currentPlayerSlot == .primary ? .secondary : .primary

        // Setup preloaded player
        await setupPlayer(slot: preloadSlot, rallyIndex: targetIndex)

        navigationState.completePreloading(success: true)
    }

    @MainActor
    func navigateToRally(_ targetIndex: Int) async {
        guard let metadata = navigationState.processingMetadata,
              targetIndex >= 0 && targetIndex < metadata.rallySegments.count else {
            return
        }

        let startTime = Date()

        // Check if we can use preloaded player
        if navigationState.preloadedPlayerIndex == targetIndex && navigationState.preloadingStatus == .ready {
            // Use preloaded player - instant transition
            if navigationState.swapToPreloadedPlayer() {
                // Update observer to new current player
                if let currentPlayer = getCurrentPlayer() {
                    setupPlaybackTimeObserver(for: currentPlayer)
                    currentPlayer.play()

                    let rally = metadata.rallySegments[targetIndex]
                    currentPlaybackTime = CMTimeGetSeconds(rally.startCMTime)
                }

                // Start preloading next rally
                if let nextIndex = navigationState.getNextPreloadTarget() {
                    await triggerPreloading(targetIndex: nextIndex)
                }

                // Calculate performance
                let seekDuration = Date().timeIntervalSince(startTime) * 1000
                seekPerformanceMs = Int(seekDuration)
                print("RallyPlayerView: Instant navigation to rally \(targetIndex + 1) in \(seekPerformanceMs)ms")
            }
        } else {
            // Fallback to traditional seeking
            await seekToRally(at: targetIndex)
        }

        // Auto-hide performance indicator
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.seekPerformanceMs = 0
        }
    }

    func setupPlaybackTimeObserver(for player: AVPlayer) {
        // Remove existing observer from the correct player
        if let observer = playbackObserver, let oldPlayer = observerPlayer {
            oldPlayer.removeTimeObserver(observer)
        }

        // Add new observer for real-time overlay synchronization
        let interval = CMTime(seconds: 0.033, preferredTimescale: 600) // ~30fps updates
        playbackObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in

            let timeInSeconds = CMTimeGetSeconds(time)
            if timeInSeconds.isFinite {
                self.currentPlaybackTime = timeInSeconds
            }
        }

        // Track which player has the observer
        observerPlayer = player
    }

}

// MARK: - Rally Navigation

private extension RallyPlayerView {
    @MainActor
    func seekToRally(at index: Int) async {
        guard let metadata = navigationState.processingMetadata,
              let currentPlayer = getCurrentPlayer(),
              index >= 0 && index < metadata.rallySegments.count else {
            return
        }

        let rally = metadata.rallySegments[index]
        let seekTime = rally.startCMTime

        // Track performance
        let startTime = Date()
        lastSeekTime = startTime

        await currentPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // Update current playback time for overlay synchronization
        currentPlaybackTime = CMTimeGetSeconds(seekTime)

        // Calculate seek performance
        let seekDuration = Date().timeIntervalSince(startTime) * 1000
        seekPerformanceMs = Int(seekDuration)

        print("RallyPlayerView: Seeked to rally \(index + 1) at \(CMTimeGetSeconds(seekTime))s in \(seekPerformanceMs)ms")

        // Start preloading next rally if it's not already preloaded
        if let nextIndex = navigationState.getNextPreloadTarget() {
            await triggerPreloading(targetIndex: nextIndex)
        }
    }

    func previousRally() {
        guard navigationState.canGoPrevious else { return }

        // Haptic feedback for smoother UX
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0.1)) {
            Task {
                await navigationState.navigateToPrevious()
            }
        }
    }

    func nextRally() {
        guard navigationState.canGoNext else { return }

        // Haptic feedback for smoother UX
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0.1)) {
            Task {
                await navigationState.navigateToNext()
            }
        }
    }

    func handleSwipeGesture(translation: CGSize) {
        let horizontalThreshold: CGFloat = 80
        let verticalThreshold: CGFloat = 60

        // Determine if this is primarily a horizontal or vertical swipe
        let isHorizontalSwipe = abs(translation.width) > abs(translation.height)

        if isHorizontalSwipe && abs(translation.width) > horizontalThreshold {
            // Horizontal swipes for like/delete actions
            if translation.width > horizontalThreshold {
                // Swipe right -> like rally
                performRallyAction(.like)
            } else if translation.width < -horizontalThreshold {
                // Swipe left -> delete rally
                performRallyAction(.delete)
            }
        } else if !isHorizontalSwipe && abs(translation.height) > verticalThreshold {
            // Vertical swipes for rally navigation
            if translation.height < -verticalThreshold {
                // Swipe up -> next rally
                nextRally()
            } else if translation.height > verticalThreshold {
                // Swipe down -> previous rally
                previousRally()
            }
        }
    }

    func performRallyAction(_ action: RallyAction) {
        let rallyIndex = navigationState.currentRallyIndex

        // Store the action for undo functionality
        lastAction = (action: action, rallyIndex: rallyIndex)

        // Haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            switch action {
            case .like:
                if likedRallies.contains(rallyIndex) {
                    likedRallies.remove(rallyIndex)
                } else {
                    likedRallies.insert(rallyIndex)
                    // Remove from deleted if it was deleted
                    deletedRallies.remove(rallyIndex)
                }
            case .delete:
                if deletedRallies.contains(rallyIndex) {
                    deletedRallies.remove(rallyIndex)
                } else {
                    deletedRallies.insert(rallyIndex)
                    // Remove from liked if it was liked
                    likedRallies.remove(rallyIndex)
                }
            case .undo:
                performUndoAction()
            }
        }

        print("Rally \(rallyIndex + 1) \(action.rawValue)")
    }

    func performUndoAction() {
        guard let lastAction = lastAction else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            switch lastAction.action {
            case .like:
                likedRallies.remove(lastAction.rallyIndex)
            case .delete:
                deletedRallies.remove(lastAction.rallyIndex)
            case .undo:
                break // Can't undo an undo
            }
        }

        self.lastAction = nil
        print("Undid action for rally \(lastAction.rallyIndex + 1)")
    }
}

// MARK: - Cleanup

private extension RallyPlayerView {
    func cleanupPlayers() {
        // Remove playback time observer
        if let observer = playbackObserver, let currentPlayer = observerPlayer {
            currentPlayer.removeTimeObserver(observer)
            playbackObserver = nil
            observerPlayer = nil
        }

        // Cleanup both players
        primaryPlayer?.pause()
        secondaryPlayer?.pause()
        primaryPlayer = nil
        secondaryPlayer = nil
        isPrimaryPlayerReady = false
        isSecondaryPlayerReady = false
        playersInitialized = false

        // Reset navigation state
        navigationState.reset()

        print("RallyPlayerView: Players cleaned up")
    }
}

// MARK: - Rally Action Types

enum RallyAction: String {
    case like = "liked"
    case delete = "deleted"
    case undo = "undone"
}

// MARK: - Error Types

enum RallyPlayerError: Error, LocalizedError {
    case noMetadataAvailable
    case noRalliesFound

    var errorDescription: String? {
        switch self {
        case .noMetadataAvailable:
            return "No rally analysis data available for this video"
        case .noRalliesFound:
            return "No rally segments found in the metadata"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct RallyPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a sample video metadata for preview
        let sampleVideo = VideoMetadata(
            fileName: "sample.mp4",
            customName: "Sample Rally Video",
            folderPath: "test",
            createdDate: Date(),
            fileSize: 1024000,
            duration: 120.0
        )

        RallyPlayerView(videoMetadata: sampleVideo)
    }
}
#endif