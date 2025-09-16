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
    @StateObject private var metadataStore = MetadataStore()

    // Video player state
    @State private var player: AVPlayer?
    @State private var isPlayerReady = false

    // Metadata and rally state
    @State private var processingMetadata: ProcessingMetadata?
    @State private var currentRallyIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Performance tracking
    @State private var lastSeekTime = Date()
    @State private var seekPerformanceMs: Int = 0

    // Overlay state for MetadataOverlayView
    @State private var currentPlaybackTime: Double = 0.0
    @State private var showOverlay = true
    @State private var showTrajectories = true
    @State private var showRallyBoundaries = true
    @State private var showConfidenceIndicators = true

    // Video player observation
    @State private var playbackObserver: Any?
    @State private var observerPlayer: AVPlayer? // Track which player has the observer

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                createVideoPlayer()
                createRallyControls()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: createToolbar)
        }
        .onAppear(perform: setupView)
        .onDisappear(perform: cleanupPlayer)
        .onChange(of: currentRallyIndex) { _, newIndex in
            seekToRally(at: newIndex)
        }
    }
}

// MARK: - Video Player

private extension RallyPlayerView {
    func createVideoPlayer() -> some View {
        Group {
            if isLoading {
                createLoadingView()
            } else if let errorMessage = errorMessage {
                createErrorView(message: errorMessage)
            } else if let player = player {
                createVideoPlayerWithOverlay(player: player)
            } else {
                createLoadingView()
            }
        }
    }

    func createVideoPlayerWithOverlay(player: AVPlayer) -> some View {
        ZStack {
            VideoPlayer(player: player)
                .aspectRatio(16/9, contentMode: .fit)

            // Metadata overlay
            if showOverlay,
               let metadata = processingMetadata,
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
                .aspectRatio(16/9, contentMode: .fit)
            }
        }
    }

    func createLoadingView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))

            if isLoading {
                Text("Loading rally data...")
                    .foregroundColor(.white)
                    .font(.caption)
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
            if let metadata = processingMetadata, !metadata.rallySegments.isEmpty {
                VStack(spacing: 12) {
                    createRallyProgressIndicator(metadata: metadata)
                    createRallyNavigationButtons(metadata: metadata)
                    createOverlayControls()
                    createPerformanceIndicator()
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

                Text("\(currentRallyIndex + 1) of \(metadata.rallySegments.count)")
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
                    let isCurrentRally = index == currentRallyIndex
                    let width = max(4, geometry.size.width / CGFloat(metadata.rallySegments.count) - 2)

                    Rectangle()
                        .fill(isCurrentRally ? Color.white : Color.gray.opacity(0.6))
                        .frame(width: width, height: 4)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentRallyIndex = index
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
            .disabled(currentRallyIndex == 0)
            .foregroundColor(currentRallyIndex == 0 ? .gray : .white)

            Spacer()

            // Rally info
            VStack(spacing: 4) {
                let currentRally = metadata.rallySegments[currentRallyIndex]
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
            .disabled(currentRallyIndex >= metadata.rallySegments.count - 1)
            .foregroundColor(currentRallyIndex >= metadata.rallySegments.count - 1 ? .gray : .white)
        }
        .gesture(
            DragGesture()
                .onEnded { gesture in
                    handleSwipeGesture(translation: gesture.translation)
                }
        )
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
            await loadMetadataAndSetupPlayer()
        }
    }

    @MainActor
    func loadMetadataAndSetupPlayer() async {
        isLoading = true
        errorMessage = nil

        do {
            // Check if metadata exists
            guard videoMetadata.hasMetadata else {
                throw RallyPlayerError.noMetadataAvailable
            }

            // Load processing metadata
            let metadata = try metadataStore.loadMetadata(for: videoMetadata.id)

            // Validate rally segments
            guard !metadata.rallySegments.isEmpty else {
                throw RallyPlayerError.noRalliesFound
            }

            processingMetadata = metadata
            currentRallyIndex = 0

            // Setup video player
            await setupVideoPlayer()

            print("RallyPlayerView: Successfully loaded \(metadata.rallySegments.count) rallies")

        } catch {
            print("RallyPlayerView: Failed to load rally data: \(error)")
            handleMetadataLoadError(error)
        }

        isLoading = false
    }

    func setupVideoPlayer() async {
        // Don't create a new player if one already exists and is ready
        guard player == nil || !isPlayerReady else { return }

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

        player = avPlayer
        isPlayerReady = true

        // Setup playback time observation for overlay synchronization
        setupPlaybackTimeObserver(for: avPlayer)

        // Seek to first rally
        if let metadata = processingMetadata, !metadata.rallySegments.isEmpty {
            let firstRally = metadata.rallySegments[0]
            let seekTime = firstRally.startCMTime

            await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentPlaybackTime = CMTimeGetSeconds(seekTime)
            avPlayer.play()
        }
    }

    func setupNormalVideoPlayback() {
        // Fallback to normal video playback when metadata is unavailable
        Task { @MainActor in
            await setupVideoPlayer()
            errorMessage = nil
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

    func handleMetadataLoadError(_ error: Error) {
        if let metadataError = error as? MetadataStoreError {
            switch metadataError {
            case .metadataNotFound:
                errorMessage = "No rally analysis available for this video. Process the video first to enable rally navigation."
            case .invalidJSON, .corruptedMetadata:
                errorMessage = "Rally data is corrupted. Try reprocessing the video."
            default:
                errorMessage = "Failed to load rally data: \(metadataError.localizedDescription)"
            }
        } else if let rallyError = error as? RallyPlayerError {
            switch rallyError {
            case .noMetadataAvailable:
                errorMessage = "No rally analysis available. Process this video to enable rally navigation."
            case .noRalliesFound:
                errorMessage = "No rallies were detected in this video. The video may not contain volleyball activity."
            }
        } else {
            errorMessage = "Unable to load rally data: \(error.localizedDescription)"
        }
    }
}

// MARK: - Rally Navigation

private extension RallyPlayerView {
    func seekToRally(at index: Int) {
        guard let metadata = processingMetadata,
              let player = player,
              index >= 0 && index < metadata.rallySegments.count else {
            return
        }

        let rally = metadata.rallySegments[index]
        let seekTime = rally.startCMTime

        // Track performance
        let startTime = Date()
        lastSeekTime = startTime

        Task { @MainActor in
            await player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

            // Update current playback time for overlay synchronization
            currentPlaybackTime = CMTimeGetSeconds(seekTime)

            // Calculate seek performance
            let seekDuration = Date().timeIntervalSince(startTime) * 1000
            seekPerformanceMs = Int(seekDuration)

            print("RallyPlayerView: Seeked to rally \(index + 1) at \(CMTimeGetSeconds(seekTime))s in \(seekPerformanceMs)ms")

            // Auto-hide performance indicator after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                seekPerformanceMs = 0
            }
        }
    }

    func previousRally() {
        guard currentRallyIndex > 0 else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            currentRallyIndex -= 1
        }
    }

    func nextRally() {
        guard let metadata = processingMetadata,
              currentRallyIndex < metadata.rallySegments.count - 1 else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            currentRallyIndex += 1
        }
    }

    func handleSwipeGesture(translation: CGSize) {
        let swipeThreshold: CGFloat = 50

        if translation.width > swipeThreshold {
            // Swipe right -> previous rally
            previousRally()
        } else if translation.width < -swipeThreshold {
            // Swipe left -> next rally
            nextRally()
        }
    }
}

// MARK: - Cleanup

private extension RallyPlayerView {
    func cleanupPlayer() {
        // Remove playback time observer from the correct player
        if let observer = playbackObserver, let currentPlayer = observerPlayer {
            currentPlayer.removeTimeObserver(observer)
            playbackObserver = nil
            observerPlayer = nil
        }

        player?.pause()
        player = nil
        isPlayerReady = false
    }
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