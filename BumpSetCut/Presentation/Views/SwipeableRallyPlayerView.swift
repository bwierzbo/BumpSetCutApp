//
//  SwipeableRallyPlayerView.swift
//  BumpSetCut
//
//  Minimalist rally-by-rally video review with swipe navigation
//  Enhanced with preloaded players and smooth transitions
//

import SwiftUI
import AVKit
import AVFoundation

struct SwipeableRallyPlayerView: View {
    // MARK: - Properties

    let videoMetadata: VideoMetadata
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var metadataStore = MetadataStore()
    @StateObject private var playerCache = RallyPlayerCache()

    // Rally state
    @State private var processingMetadata: ProcessingMetadata?
    @State private var currentRallyIndex = 0
    @State private var isLoading = true
    @State private var hasError = false

    // Transition state
    @State private var isTransitioning = false
    @State private var transitionOpacity = 1.0
    @State private var showFlash = false

    // Gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var bounceOffset: CGFloat = 0.0

    // Debug state
    #if DEBUG
    @State private var showDebugInfo = false
    @State private var fps: Int = 0
    @State private var lastFrameTime = CACurrentMediaTime()
    #endif

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    private var canGoNext: Bool {
        guard let metadata = processingMetadata else { return false }
        return currentRallyIndex < metadata.rallySegments.count - 1
    }

    private var canGoPrevious: Bool {
        return currentRallyIndex > 0
    }

    var body: some View {
        ZStack {
            // Black background extends to all edges
            Color.black.ignoresSafeArea()

            // Content respects safe areas
            VStack(spacing: 0) {
                // Top safe area spacer
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 100) // Space for navigation overlay

                // Main content area
                if isLoading {
                    Spacer()
                    createLoadingView()
                    Spacer()
                } else if hasError {
                    Spacer()
                    createErrorView()
                    Spacer()
                } else {
                    createVideoPlayerStack()
                        .offset(x: dragOffset.width + bounceOffset, y: dragOffset.height)
                        .scaleEffect(isDragging ? 0.95 : 1.0)
                        .opacity(transitionOpacity)
                        .gesture(createSwipeGesture())
                        .onTapGesture(count: 2) {
                            #if DEBUG
                            showDebugInfo.toggle()
                            #endif
                        }
                        .onTapGesture(perform: togglePlayPause)
                }

                // Bottom safe area spacer
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 50)
            }

            // Flash transition effect
            if showFlash {
                Color.black
                    .ignoresSafeArea()
                    .opacity(0.8)
                    .animation(.easeInOut(duration: 0.1), value: showFlash)
            }

            // Debug overlay
            #if DEBUG
            if showDebugInfo {
                createDebugOverlay()
            }
            #endif
        }
        // Clean navigation overlay
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack {
                    // Clean back arrow button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(.black.opacity(0.6))
                                    .overlay(
                                        Circle()
                                            .stroke(.white.opacity(0.2), lineWidth: 1)
                                    )
                            )
                    }
                    .padding(.leading, 20)
                    .padding(.top, 60)

                    Spacer()
                }

                Spacer()
            }
            .allowsHitTesting(true)
            .zIndex(999)
        }
        // Rally counter overlay
        .overlay(alignment: .topTrailing) {
            VStack {
                HStack {
                    Spacer()

                    // Clean rally counter
                    if let metadata = processingMetadata, !metadata.rallySegments.isEmpty {
                        Text("\(currentRallyIndex + 1) / \(metadata.rallySegments.count)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.black.opacity(0.6))
                                    .overlay(
                                        Capsule()
                                            .stroke(.white.opacity(0.2), lineWidth: 1)
                                    )
                            )
                            .padding(.trailing, 20)
                            .padding(.top, 60)
                    }
                }
                Spacer()
            }
            .allowsHitTesting(true)
            .zIndex(999)
        }
        .onAppear(perform: setupView)
        .onDisappear(perform: cleanupAll)
        .animation(.easeOut(duration: 0.3), value: dragOffset)
        .animation(.easeOut(duration: 0.2), value: isDragging)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: bounceOffset)
    }
}

// MARK: - UI Components

private extension SwipeableRallyPlayerView {
    func createLoadingView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)

            Text("Loading rally data...")
                .foregroundColor(.white.opacity(0.8))
                .font(.callout)
        }
    }

    func createErrorView() -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)

            Text("No rally data available")
                .font(.headline)
                .foregroundColor(.white)

            Button("Dismiss") {
                dismiss()
            }
            .foregroundColor(.blue)
            .font(.callout)
        }
    }

    func createVideoPlayerStack() -> some View {
        Group {
            if let metadata = processingMetadata,
               let currentCard = playerCache.getCurrentCard(for: currentRallyIndex) {
                RallyCardView(
                    rallyMetadata: metadata.rallySegments[currentRallyIndex],
                    videoURL: videoMetadata.originalURL,
                    playerCache: playerCache,
                    rallyIndex: currentRallyIndex,
                    isFocused: true
                )
                .overlay(alignment: .bottom) {
                    createRallyIndicator()
                }
            }
        }
    }

    func createRallyIndicator() -> some View {
        Group {
            if let metadata = processingMetadata, metadata.rallySegments.count > 1 {
                VStack(spacing: 8) {
                    // Rally dots indicator
                    HStack(spacing: 6) {
                        ForEach(0..<metadata.rallySegments.count, id: \.self) { index in
                            Circle()
                                .fill(index == currentRallyIndex ? Color.white : Color.white.opacity(0.3))
                                .frame(width: 6, height: 6)
                                .scaleEffect(index == currentRallyIndex ? 1.2 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: currentRallyIndex)
                        }
                    }

                    // Rally counter
                    Text("\(currentRallyIndex + 1)/\(metadata.rallySegments.count)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Capsule())
                }
                .padding(.bottom, 40)
            }
        }
    }

    #if DEBUG
    func createDebugOverlay() -> some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rally: \(currentRallyIndex + 1)")
                        .foregroundColor(.green)
                    Text("FPS: \(fps)")
                        .foregroundColor(.yellow)
                    Text("Cache: \(playerCache.getCacheStatus())")
                        .foregroundColor(.cyan)
                }
                .font(.caption2.monospaced())
                .padding(8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)

                Spacer()
            }
            .padding()

            Spacer()
        }
    }
    #endif
}

// MARK: - Gesture Handling

private extension SwipeableRallyPlayerView {
    func createSwipeGesture() -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true

                // Apply drag offset based on orientation with resistance at boundaries
                if isPortrait {
                    let resistanceFactor = calculateResistance(for: value.translation.height, axis: .vertical)
                    dragOffset = CGSize(width: 0, height: value.translation.height * resistanceFactor)
                } else {
                    let resistanceFactor = calculateResistance(for: value.translation.width, axis: .horizontal)
                    dragOffset = CGSize(width: value.translation.width * resistanceFactor, height: 0)
                }

                #if DEBUG
                updateFPS()
                #endif
            }
            .onEnded { value in
                isDragging = false
                dragOffset = .zero

                handleSwipeNavigation(translation: value.translation)
            }
    }

    func calculateResistance(for translation: CGFloat, axis: Axis) -> CGFloat {
        let threshold: CGFloat = 100
        let baseResistance: CGFloat = 0.3

        if axis == .vertical {
            // Portrait mode: up = next, down = previous
            if translation < 0 && !canGoNext {
                // Trying to go next when at last rally
                return max(0.1, baseResistance * (1 - abs(translation) / threshold))
            } else if translation > 0 && !canGoPrevious {
                // Trying to go previous when at first rally
                return max(0.1, baseResistance * (1 - abs(translation) / threshold))
            }
        } else {
            // Landscape mode: left = next, right = previous
            if translation < 0 && !canGoNext {
                return max(0.1, baseResistance * (1 - abs(translation) / threshold))
            } else if translation > 0 && !canGoPrevious {
                return max(0.1, baseResistance * (1 - abs(translation) / threshold))
            }
        }

        return baseResistance
    }

    func handleSwipeNavigation(translation: CGSize) {
        let threshold: CGFloat = 100

        if isPortrait {
            // Vertical swipe navigation in portrait
            if translation.height < -threshold && canGoNext {
                nextRally()
            } else if translation.height > threshold && canGoPrevious {
                previousRally()
            } else {
                // Bounce effect for edge cases
                triggerBounceEffect(translation: translation)
            }
        } else {
            // Horizontal swipe navigation in landscape
            if translation.width < -threshold && canGoNext {
                nextRally()
            } else if translation.width > threshold && canGoPrevious {
                previousRally()
            } else {
                triggerBounceEffect(translation: translation)
            }
        }
    }

    func triggerBounceEffect(translation: CGSize) {
        let bounceDistance: CGFloat = 20

        // Track edge bounce analytics
        if appSettings.enableAnalytics {
            appSettings.logRallyGestureUsage(
                gestureType: .edgeBounce,
                rallyIndex: currentRallyIndex
            )
        }

        if isPortrait {
            bounceOffset = translation.height > 0 ? bounceDistance : -bounceDistance
        } else {
            bounceOffset = translation.width > 0 ? bounceDistance : -bounceDistance
        }

        // Return to center
        Task { @MainActor in
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            bounceOffset = 0
        }
    }

    func togglePlayPause() {
        playerCache.togglePlayPause(for: currentRallyIndex)

        // Track tap gesture analytics
        if appSettings.enableAnalytics {
            appSettings.logRallyGestureUsage(
                gestureType: .tapPlayPause,
                rallyIndex: currentRallyIndex
            )
        }
    }

    #if DEBUG
    func updateFPS() {
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastFrameTime

        // Only update FPS every 0.1 seconds to reduce state update frequency
        if deltaTime > 0.1 {
            lastFrameTime = currentTime
            fps = Int(1.0 / deltaTime)
        }
    }
    #endif

    enum Axis {
        case horizontal, vertical
    }

}

// MARK: - Setup and Initialization

private extension SwipeableRallyPlayerView {
    func setupView() {
        Task { @MainActor in
            await loadMetadataAndSetupPlayer()
        }
    }

    @MainActor
    func loadMetadataAndSetupPlayer() async {
        isLoading = true
        hasError = false

        do {
            let metadata: ProcessingMetadata

            // Check if metadata exists
            if videoMetadata.hasMetadata {
                // Load actual processing metadata
                metadata = try metadataStore.loadMetadata(for: videoMetadata.id)

                // Validate rally segments
                guard !metadata.rallySegments.isEmpty else {
                    throw RallyPlayerError.noRalliesFound
                }
            } else {
                #if DEBUG
                // DEBUG: For testing navigation overlay without metadata
                print("🎯 DEBUG: No metadata found, but showing SwipeableRallyPlayerView for navigation testing")
                isLoading = false
                hasError = true // This will show error view but navigation overlay should still be visible
                return
                #else
                throw RallyPlayerError.noMetadataAvailable
                #endif
            }

            processingMetadata = metadata
            currentRallyIndex = 0

            // Initialize player cache with metadata
            await playerCache.initialize(
                videoURL: videoMetadata.originalURL,
                rallies: metadata.rallySegments,
                metadata: metadata
            )

            // Preload current and adjacent rallies
            await preloadAdjacentRallies()

            print("SwipeableRallyPlayerView: Loaded \(metadata.rallySegments.count) rallies with preloading")

        } catch {
            print("SwipeableRallyPlayerView: Failed to load rally data: \(error)")
            hasError = true
        }

        isLoading = false
    }

    func preloadAdjacentRallies() async {
        guard let metadata = processingMetadata else { return }

        let indicesToPreload = [
            currentRallyIndex - 1,
            currentRallyIndex,
            currentRallyIndex + 1
        ].filter { $0 >= 0 && $0 < metadata.rallySegments.count }

        await playerCache.preloadRallies(indices: indicesToPreload)
    }
}

// MARK: - Rally Navigation

private extension SwipeableRallyPlayerView {
    func previousRally() {
        guard canGoPrevious else { return }

        // Track swipe gesture analytics
        if appSettings.enableAnalytics {
            appSettings.logRallyGestureUsage(
                gestureType: .swipePrevious,
                rallyIndex: currentRallyIndex
            )
        }

        Task { @MainActor in
            await performRallyTransition(to: currentRallyIndex - 1)
        }
    }

    func nextRally() {
        guard canGoNext else { return }

        // Track swipe gesture analytics
        if appSettings.enableAnalytics {
            appSettings.logRallyGestureUsage(
                gestureType: .swipeNext,
                rallyIndex: currentRallyIndex
            )
        }

        Task { @MainActor in
            await performRallyTransition(to: currentRallyIndex + 1)
        }
    }

    @MainActor
    func performRallyTransition(to newIndex: Int) async {
        guard let metadata = processingMetadata,
              newIndex >= 0 && newIndex < metadata.rallySegments.count else { return }

        isTransitioning = true

        // Cinematic flash effect
        showFlash = true
        Task { @MainActor in
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
            showFlash = false
        }

        // Crossfade transition
        withAnimation(.easeInOut(duration: 0.15)) {
            transitionOpacity = 0.3
        }

        // Switch to new rally
        let oldIndex = currentRallyIndex
        currentRallyIndex = newIndex

        // Activate new player
        await playerCache.switchToRally(index: newIndex)

        // Fade back in
        withAnimation(.easeInOut(duration: 0.15)) {
            transitionOpacity = 1.0
        }

        // Preload adjacent rallies for next transition
        await preloadAdjacentRallies()

        // Clean up old player if not adjacent
        await playerCache.cleanupDistantRallies(currentIndex: newIndex)

        isTransitioning = false

        print("SwipeableRallyPlayerView: Transitioned from rally \(oldIndex + 1) to \(newIndex + 1)")
    }
}

// MARK: - Cleanup

private extension SwipeableRallyPlayerView {
    func cleanupAll() {
        playerCache.cleanupAll()
    }
}

// MARK: - RallyPlayerCache

@MainActor
class RallyPlayerCache: ObservableObject {
    private var players: [Int: AVPlayer] = [:]
    private var timeObservers: [Int: Any] = [:]
    private var currentRallyIndex = 0
    private var rallies: [RallySegment] = []
    var metadata: ProcessingMetadata?
    private var videoURL: URL?

    func initialize(videoURL: URL, rallies: [RallySegment], metadata: ProcessingMetadata) async {
        self.videoURL = videoURL
        self.rallies = rallies
        self.metadata = metadata
        self.currentRallyIndex = 0

        // Configure audio session
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ Warning: Could not activate audio session: \(error)")
        }
    }

    func preloadRallies(indices: [Int]) async {
        guard let videoURL = videoURL else { return }

        for index in indices {
            if players[index] == nil && index < rallies.count {
                let player = AVPlayer(url: videoURL)
                player.volume = 1.0
                player.isMuted = false
                player.automaticallyWaitsToMinimizeStalling = false

                // Seek to rally start
                let rally = rallies[index]
                let seekTime = rally.startCMTime
                await player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

                // Setup loop observer
                setupLoopObserver(for: player, rallyIndex: index)

                players[index] = player

                print("RallyPlayerCache: Preloaded rally \(index + 1)")
            }
        }
    }

    func switchToRally(index: Int) async {
        guard let player = players[index] else { return }

        // Pause all other players
        for (otherIndex, otherPlayer) in players {
            if otherIndex != index {
                otherPlayer.pause()
            }
        }

        // Start the new player
        currentRallyIndex = index
        player.play()
    }

    func togglePlayPause(for index: Int) {
        guard let player = players[index] else { return }

        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func getCurrentCard(for index: Int) -> AVPlayer? {
        return players[index]
    }

    func cleanupDistantRallies(currentIndex: Int) async {
        let keepIndices = Set([currentIndex - 1, currentIndex, currentIndex + 1])

        for (index, player) in players {
            if !keepIndices.contains(index) {
                // Remove time observer
                if let observer = timeObservers[index] {
                    player.removeTimeObserver(observer)
                    timeObservers[index] = nil
                }

                player.pause()
                players[index] = nil

                print("RallyPlayerCache: Cleaned up rally \(index + 1)")
            }
        }
    }

    func cleanupAll() {
        for (index, player) in players {
            if let observer = timeObservers[index] {
                player.removeTimeObserver(observer)
            }
            player.pause()
        }

        players.removeAll()
        timeObservers.removeAll()
    }

    func getCacheStatus() -> String {
        return "\(players.count) cached"
    }

    private func setupLoopObserver(for player: AVPlayer, rallyIndex: Int) {
        guard rallyIndex < rallies.count else { return }

        let rally = rallies[rallyIndex]
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)

        let currentIndex = self.currentRallyIndex  // Capture main actor value before closure
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let currentTimeSeconds = CMTimeGetSeconds(time)

            if currentTimeSeconds >= rally.endTime && rallyIndex == currentIndex {
                Task { @MainActor in
                    await player.seek(to: rally.startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }

        timeObservers[rallyIndex] = observer
    }
}

// MARK: - RallyCardView

struct RallyCardView: View {
    let rallyMetadata: RallySegment
    let videoURL: URL
    let playerCache: RallyPlayerCache
    let rallyIndex: Int
    let isFocused: Bool

    @State private var currentPlaybackTime: Double = 0.0

    var body: some View {
        Group {
            if let player = playerCache.getCurrentCard(for: rallyIndex) {
                ZStack {
                    VideoPlayer(player: player)
                        .aspectRatio(contentMode: .fit)
                        .background(Color.black)

                    // Minimal trajectory overlay
                    if let metadata = playerCache.metadata {
                        GeometryReader { geometry in
                            MetadataOverlayView(
                                processingMetadata: metadata,
                                currentTime: currentPlaybackTime,
                                videoSize: geometry.size,
                                showTrajectories: true,
                                showRallyBoundaries: false,
                                showConfidenceIndicators: false
                            )
                            .opacity(0.7)
                        }
                    }
                }
                .onAppear {
                    setupTimeObserver(for: player)
                }
            }
        }
    }

    private func setupTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600) // 10fps to reduce update frequency
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let timeInSeconds = CMTimeGetSeconds(time)
            if timeInSeconds.isFinite {
                Task { @MainActor in
                    self.currentPlaybackTime = timeInSeconds
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SwipeableRallyPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleVideo = VideoMetadata(
            fileName: "sample.mp4",
            customName: "Sample Rally Video",
            folderPath: "test",
            createdDate: Date(),
            fileSize: 1024000,
            duration: 120.0
        )

        SwipeableRallyPlayerView(videoMetadata: sampleVideo)
            .environmentObject(AppSettings.shared)
    }
}
#endif