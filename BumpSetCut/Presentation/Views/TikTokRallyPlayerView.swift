//
//  TikTokRallyPlayerView.swift
//  BumpSetCut
//
//  TikTok-style rally player with individual video files and seamless swiping
//

import SwiftUI
import AVKit
import AVFoundation

struct TikTokRallyPlayerView: View {
    // MARK: - Properties

    let videoMetadata: VideoMetadata
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var metadataStore = MetadataStore()

    // Rally video state
    @State private var processingMetadata: ProcessingMetadata?
    @State private var rallyVideoURLs: [URL] = []
    @State private var currentRallyIndex = 0
    @State private var isLoading = true
    @State private var isExportingRallies = false
    @State private var hasError = false
    @State private var errorMessage = ""

    // Rally management state
    @State private var savedRallies: Set<Int> = []
    @State private var removedRallies: Set<Int> = []

    // Video players state
    @State private var players: [AVPlayer] = []
    @State private var playerLayers: [AVPlayerLayer] = []
    @State private var notificationObservers: [NSObjectProtocol] = []

    // Gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var bounceOffset: CGFloat = 0.0

    // Transition state
    @State private var isTransitioning = false
    @State private var transitionOpacity = 1.0
    @State private var videoScale: CGFloat = 1.0

    // Action feedback state
    @State private var actionFeedback: ActionFeedback?
    @State private var showActionFeedback = false

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    private var canGoNext: Bool {
        currentRallyIndex < rallyVideoURLs.count - 1
    }

    private var canGoPrevious: Bool {
        currentRallyIndex > 0
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if hasError {
                    errorView
                } else if rallyVideoURLs.isEmpty {
                    noRalliesView
                } else {
                    rallyPlayerStack(geometry: geometry)
                        .clipped() // Ensure no video content bleeds outside
                }

                // Navigation overlay
                if !isLoading && !hasError && !rallyVideoURLs.isEmpty {
                    navigationOverlay
                }

                // Action feedback overlay
                if showActionFeedback, let feedback = actionFeedback {
                    actionFeedbackOverlay(feedback: feedback)
                }
            }
            .clipped() // Additional clipping at the top level
        }
        .onAppear {
            Task {
                await loadRallyVideos()
            }
        }
        .onDisappear {
            cleanupPlayers()
        }
    }

    // MARK: - Video Player Stack

    private func rallyPlayerStack(geometry: GeometryProxy) -> some View {
        ZStack {
            ForEach(Array(rallyVideoURLs.enumerated()), id: \.offset) { index, url in
                if index == currentRallyIndex || (isDragging && abs(index - currentRallyIndex) <= 1) {
                    TikTokVideoPlayer(
                        url: url,
                        isActive: index == currentRallyIndex,
                        size: geometry.size
                    )
                    .offset(
                        x: 0, // Always centered horizontally, ignore horizontal drag
                        y: CGFloat(index - currentRallyIndex) * geometry.size.height + dragOffset.height
                    )
                    .scaleEffect(index == currentRallyIndex ? videoScale : 0.95)
                    .opacity(index == currentRallyIndex ? 1.0 : 0.0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.2), value: currentRallyIndex)
                    .allowsHitTesting(index == currentRallyIndex) // Only allow interaction with current video
                }
            }
        }
        .clipped() // Prevent videos from showing outside bounds
        .gesture(swipeGesture(geometry: geometry))
    }

    // MARK: - Swipe Gesture

    private func swipeGesture(geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation

                // Subtle scale effect during drag
                let dragProgress = abs(dragOffset.height) / 100.0
                videoScale = max(0.98, 1.0 - dragProgress * 0.02)

                // Resistance at boundaries for vertical navigation (both orientations)
                if !canGoNext && dragOffset.height < 0 {
                    dragOffset.height *= 0.3
                }
                if !canGoPrevious && dragOffset.height > 0 {
                    dragOffset.height *= 0.3
                }
            }
            .onEnded { value in
                isDragging = false

                let threshold: CGFloat = 100
                let actionThreshold: CGFloat = 120

                // Unified gesture handling for both orientations
                let verticalVelocity = value.velocity.height
                let verticalOffset = dragOffset.height
                let horizontalVelocity = value.velocity.width
                let horizontalOffset = dragOffset.width

                print("🎯 Gesture Debug:")
                print("   Vertical: velocity=\(verticalVelocity), offset=\(verticalOffset)")
                print("   Horizontal: velocity=\(horizontalVelocity), offset=\(horizontalOffset)")
                print("   Thresholds: nav=\(threshold), action=\(actionThreshold)")
                print("   CanGoNext: \(canGoNext), CanGoPrevious: \(canGoPrevious)")
                print("   Portrait: \(isPortrait)")

                // Determine the dominant direction based on which has higher magnitude
                let isVerticalDominant = abs(verticalVelocity) > abs(horizontalVelocity) || abs(verticalOffset) > abs(horizontalOffset)

                print("🧭 Gesture Analysis:")
                print("   Vertical dominant: \(isVerticalDominant)")
                print("   Vertical magnitude: velocity=\(abs(verticalVelocity)), offset=\(abs(verticalOffset))")
                print("   Horizontal magnitude: velocity=\(abs(horizontalVelocity)), offset=\(abs(horizontalOffset))")

                if isVerticalDominant {
                    // Vertical navigation (up/down swipes)
                    if abs(verticalVelocity) > 500 || abs(verticalOffset) > threshold {
                        print("📱 Vertical navigation detected - Offset: \(verticalOffset)")
                        if verticalOffset > 0 && canGoPrevious {
                            print("👇 Swipe DOWN (positive offset) -> Previous rally")
                            navigateToPrevious()
                        } else if verticalOffset < 0 && canGoNext {
                            print("👆 Swipe UP (negative offset) -> Next rally")
                            navigateToNext()
                        } else {
                            print("⚠️ Navigation blocked - offset: \(verticalOffset), canNext: \(canGoNext), canPrev: \(canGoPrevious)")
                        }
                    } else {
                        print("❌ Vertical gesture too weak")
                    }
                } else {
                    // Horizontal actions (left/right swipes)
                    if abs(horizontalVelocity) > 300 || abs(horizontalOffset) > actionThreshold {
                        print("🔄 Horizontal action detected")
                        if horizontalOffset < -actionThreshold {
                            print("⬅️ Swipe left - remove rally")
                            performRemoveAction()
                        } else if horizontalOffset > actionThreshold {
                            print("➡️ Swipe right - save rally")
                            performSaveAction()
                        }
                    } else {
                        print("❌ Horizontal gesture too weak")
                    }
                }

                withAnimation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0.1)) {
                    dragOffset = .zero
                    videoScale = 1.0 // Reset scale when drag ends
                }
            }
    }

    // MARK: - Navigation

    private func navigateToNext() {
        guard canGoNext else { return }
        print("🔄 Navigating to NEXT rally: \(currentRallyIndex) -> \(currentRallyIndex + 1)")

        // Subtle scale animation during transition
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            videoScale = 0.98
        }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0.1)) {
            currentRallyIndex += 1
            dragOffset = .zero
        }

        // Return to normal scale
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                videoScale = 1.0
            }
        }
    }

    private func navigateToPrevious() {
        guard canGoPrevious else { return }
        print("🔄 Navigating to PREVIOUS rally: \(currentRallyIndex) -> \(currentRallyIndex - 1)")

        // Subtle scale animation during transition
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            videoScale = 0.98
        }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0.1)) {
            currentRallyIndex -= 1
            dragOffset = .zero
        }

        // Return to normal scale
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                videoScale = 1.0
            }
        }
    }

    // MARK: - Rally Actions

    private func performRemoveAction() {
        let rallyIndex = currentRallyIndex

        withAnimation(.easeInOut(duration: 0.5)) {
            removedRallies.insert(rallyIndex)
            actionFeedback = ActionFeedback(type: .remove, message: "Rally Removed")
            showActionFeedback = true
        }

        // Auto-hide feedback after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                showActionFeedback = false
            }
        }

        // Navigate away from removed rally
        if canGoNext {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigateToNext()
            }
        } else if canGoPrevious {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigateToPrevious()
            }
        }

        print("🗑️ Rally \(rallyIndex + 1) marked for removal")
    }

    private func performSaveAction() {
        let rallyIndex = currentRallyIndex

        withAnimation(.easeInOut(duration: 0.5)) {
            savedRallies.insert(rallyIndex)
            removedRallies.remove(rallyIndex) // Remove from removed set if it was there
            actionFeedback = ActionFeedback(type: .save, message: "Rally Saved")
            showActionFeedback = true
        }

        // Auto-hide feedback after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                showActionFeedback = false
            }
        }

        print("💾 Rally \(rallyIndex + 1) marked as saved")
    }

    // MARK: - Rally Management

    /// Get the indices of rallies that should be kept (not removed)
    var activeRallyIndices: [Int] {
        Array(0..<rallyVideoURLs.count).filter { !removedRallies.contains($0) }
    }

    /// Get the indices of saved rallies
    var savedRallyIndices: [Int] {
        Array(savedRallies).sorted()
    }

    /// Export saved rallies as individual video files or stitched together
    func exportSavedRallies(asSingleVideo: Bool = false) async {
        guard !savedRallies.isEmpty else {
            print("⚠️ No rallies saved for export")
            return
        }

        print("📼 Exporting \(savedRallies.count) saved rallies (single video: \(asSingleVideo))")
        // TODO: Implement export functionality
        // This would involve:
        // 1. Getting the rally segments from processingMetadata
        // 2. Using VideoExporter to create individual files or stitch together
        // 3. Saving to user's photo library or Documents folder
    }

    /// Clear all rally management state
    func clearRallySelections() {
        withAnimation(.easeInOut(duration: 0.3)) {
            savedRallies.removeAll()
            removedRallies.removeAll()
        }
        print("🔄 Cleared all rally selections")
    }

    // MARK: - Navigation Overlay

    private var navigationOverlay: some View {
        VStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
                .padding(.leading, 16)

                Spacer()

                // Rally counter with status
                HStack(spacing: 8) {
                    // Rally status indicator
                    if savedRallies.contains(currentRallyIndex) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.green)
                    } else if removedRallies.contains(currentRallyIndex) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.red)
                    }

                    Text("\(currentRallyIndex + 1) / \(rallyVideoURLs.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.4))
                .clipShape(Capsule())
                .padding(.trailing, 16)
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Loading States

    private var loadingView: some View {
        VStack(spacing: 16) {
            if isExportingRallies {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Creating rally videos...")
                    .font(.headline)
                    .foregroundColor(.white)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Loading rallies...")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)

            Text("Error Loading Rallies")
                .font(.headline)
                .foregroundColor(.white)

            Text(errorMessage)
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                Task {
                    await loadRallyVideos()
                }
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var noRalliesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No Rallies Found")
                .font(.headline)
                .foregroundColor(.white)

            Text("No rally segments were detected in this video.")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - Data Loading

    private func loadRallyVideos() async {
        guard let metadata = await loadProcessingMetadata() else { return }

        if metadata.rallySegments.isEmpty {
            await MainActor.run {
                hasError = false
                isLoading = false
            }
            return
        }

        await MainActor.run {
            isExportingRallies = true
        }

        do {
            let asset = AVURLAsset(url: videoMetadata.originalURL)
            let exporter = VideoExporter()
            let urls = try await exporter.exportRallySegments(asset: asset, rallies: metadata.rallySegments)

            await MainActor.run {
                self.rallyVideoURLs = urls
                self.processingMetadata = metadata
                self.isLoading = false
                self.isExportingRallies = false
                self.hasError = false
            }

        } catch {
            await MainActor.run {
                self.hasError = true
                self.isLoading = false
                self.isExportingRallies = false
                self.errorMessage = "Failed to create rally videos: \(error.localizedDescription)"
            }
        }
    }

    private func loadProcessingMetadata() async -> ProcessingMetadata? {
        do {
            let metadata = try metadataStore.loadMetadata(for: videoMetadata.id)
            return metadata
        } catch {
            await MainActor.run {
                self.hasError = true
                self.isLoading = false
                self.errorMessage = "Failed to load video metadata: \(error.localizedDescription)"
            }
            return nil
        }
    }

    // MARK: - Visual Feedback

    private func actionFeedbackOverlay(feedback: ActionFeedback) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: feedback.type.iconName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(feedback.type.color)

                Text(feedback.message)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(feedback.type.color, lineWidth: 2)
                    )
            )
            .scaleEffect(showActionFeedback ? 1.0 : 0.8)
            .opacity(showActionFeedback ? 1.0 : 0.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showActionFeedback)

            Spacer()
                .frame(height: 120) // Space above bottom for rally counter
        }
    }

    // MARK: - Cleanup

    private func cleanupPlayers() {
        // Cleanup will be handled by TikTokVideoPlayer components
    }
}

// MARK: - TikTok Video Player Component

struct TikTokVideoPlayer: View {
    let url: URL
    let isActive: Bool
    let size: CGSize

    @StateObject private var playerManager = VideoPlayerManager()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            Color.black

            if let player = playerManager.player {
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: isPortrait ? .fit : .fill)
                    .disabled(true) // Remove all video player controls
                    .clipped() // Clip video content to bounds
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped() // Double clipping to ensure no overflow
        .contentShape(Rectangle()) // Ensure tap gesture area is constrained
        .onTapGesture {
            playerManager.togglePlayPause()
        }
        .onAppear {
            playerManager.setupPlayer(url: url)
            if isActive {
                playerManager.playFromBeginning()
            }
        }
        .onChange(of: isActive) { active in
            if active {
                playerManager.playFromBeginning()
            } else {
                playerManager.pause()
            }
        }
        .onDisappear {
            playerManager.cleanup()
        }
    }
}

// MARK: - Video Player Manager

@MainActor
class VideoPlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying: Bool = false
    private var notificationObserver: NSObjectProtocol?

    func setupPlayer(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Auto-loop
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func playFromBeginning() {
        player?.seek(to: .zero)
        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func cleanup() {
        player?.pause()
        player = nil
        isPlaying = false

        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
    }
}

// MARK: - Action Feedback Types

struct ActionFeedback {
    let type: ActionType
    let message: String

    enum ActionType {
        case save
        case remove

        var iconName: String {
            switch self {
            case .save:
                return "heart.fill"
            case .remove:
                return "trash.fill"
            }
        }

        var color: Color {
            switch self {
            case .save:
                return .green
            case .remove:
                return .red
            }
        }
    }
}
