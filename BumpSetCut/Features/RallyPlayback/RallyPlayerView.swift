//
//  RallyPlayerView.swift
//  BumpSetCut
//
//  Unified rally player with TikTok-style swipe navigation
//

import SwiftUI
import AVKit

// MARK: - Rally Player View

struct RallyPlayerView: View {
    // MARK: - Properties

    let videoMetadata: VideoMetadata

    @State private var viewModel: RallyPlayerViewModel
    @State private var showingGestureTips = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var appSettings: AppSettings

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    // MARK: - Initialization

    init(videoMetadata: VideoMetadata) {
        self.videoMetadata = videoMetadata
        self._viewModel = State(wrappedValue: RallyPlayerViewModel(videoMetadata: videoMetadata))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                switch viewModel.loadingState {
                case .loading:
                    RallyLoadingView()

                case .error(let message):
                    RallyErrorView(
                        message: message,
                        onRetry: { Task { await viewModel.loadRallies() } },
                        onDismiss: { dismiss() }
                    )

                case .empty:
                    RallyEmptyView(onDismiss: { dismiss() })

                case .loaded:
                    rallyContent(geometry: geometry)
                }
            }
            .sheet(isPresented: $viewModel.showExportOptions) {
                RallyExportSheet(
                    savedRallies: viewModel.savedRalliesArray,
                    totalRallies: viewModel.totalRallies,
                    processingMetadata: viewModel.processingMetadata,
                    videoMetadata: videoMetadata,
                    onDismiss: { viewModel.showExportOptions = false }
                )
            }
        }
        .task {
            await viewModel.loadRallies()
        }
        .onAppear {
            // Show gesture tips on first launch
            if !appSettings.hasSeenRallyTips {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingGestureTips = true
                }
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }

    // MARK: - Rally Content

    @ViewBuilder
    private func rallyContent(geometry: GeometryProxy) -> some View {
        ZStack {
            // Stacked video cards (Tinder-style)
            ForEach(viewModel.visibleCardIndices, id: \.self) { rallyIndex in
                let position = viewModel.stackPosition(for: rallyIndex)
                let url = viewModel.rallyVideoURLs[rallyIndex]

                // Unified card - no component swapping for smooth transitions
                UnifiedRallyCard(
                    url: url,
                    rallyIndex: rallyIndex,
                    size: geometry.size,
                    position: position,
                    previousRallyIndex: viewModel.previousRallyIndex,
                    playerCache: viewModel.playerCache,
                    thumbnailCache: viewModel.thumbnailCache
                )
                .scaleEffect(scaleForPosition(position))
                .offset(y: offsetForPosition(position))
                .opacity(opacityForPosition(position))
                .zIndex(zIndexForPosition(position))
                // Apply drag transforms only to current card
                .modifier(TopCardDragModifier(
                    isTopCard: position == 0,
                    dragOffset: viewModel.dragOffset,
                    swipeOffset: viewModel.swipeOffset,
                    swipeOffsetY: viewModel.swipeOffsetY,
                    swipeRotation: viewModel.swipeRotation
                ))
            }

            // Navigation overlay (above all cards)
            RallyPlayerOverlay(
                currentIndex: viewModel.currentRallyIndex,
                totalCount: viewModel.totalRallies,
                isSaved: viewModel.currentRallyIsSaved,
                isRemoved: viewModel.currentRallyIsRemoved,
                onDismiss: { dismiss() },
                onShowTips: { showingGestureTips = true }
            )
            .zIndex(200)

            // Action buttons (above all cards)
            RallyActionButtons(
                isSaved: viewModel.currentRallyIsSaved,
                isRemoved: viewModel.currentRallyIsRemoved,
                canUndo: viewModel.lastAction != nil,
                onRemove: { performAction(.remove) },
                onUndo: { viewModel.undoLastAction() },
                onSave: { performAction(.save) }
            )
            .zIndex(200)

            // Action feedback (topmost)
            if let feedback = viewModel.actionFeedback {
                RallyActionFeedbackView(
                    feedback: feedback,
                    isShowing: viewModel.showActionFeedback
                )
                .zIndex(300)
            }

            // Gesture tips overlay (highest z-index)
            if showingGestureTips {
                GestureTipsOverlay {
                    showingGestureTips = false
                    appSettings.hasSeenRallyTips = true
                }
                .zIndex(400)
                .transition(.opacity)
            }

            // Buffering overlay (topmost - shows while waiting for video to buffer)
            if viewModel.isBuffering {
                RallyBufferingOverlay()
                    .zIndex(500)
            }
        }
        .gesture(swipeGesture(geometry: geometry))
    }

    // MARK: - Stack Position Helpers

    /// Scale for card at given position - all same size (no depth effect)
    private func scaleForPosition(_ position: Int) -> CGFloat {
        return 1.0  // All cards same size, directly behind
    }

    /// Y offset for card at given position - no offset (cards directly behind)
    private func offsetForPosition(_ position: Int) -> CGFloat {
        return 0  // All cards aligned, no depth offset
    }

    /// Opacity for card at given position
    private func opacityForPosition(_ position: Int) -> Double {
        switch position {
        case 0: return 1.0     // Current - fully visible
        case 1: return 1.0     // Next - fully visible (VideoPlayer hidden via internal opacity)
        default: return 0.0    // Others hidden but preloaded
        }
    }

    /// Z-index for card at given position
    private func zIndexForPosition(_ position: Int) -> Double {
        switch position {
        case -1: return -1     // Previous - behind current
        case 0: return 100     // Current - on top
        default: return Double(-position)  // Next cards below
        }
    }

    // MARK: - Gesture Handling

    private func swipeGesture(geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // Ignore gestures during transitions
                guard !viewModel.isTransitioning, !viewModel.isPerformingAction else { return }

                viewModel.isDragging = true
                viewModel.dragOffset = value.translation

                // Update peek progress
                viewModel.updatePeekProgress(
                    translation: value.translation,
                    geometry: geometry,
                    isPortrait: isPortrait
                )

                // Apply boundary resistance
                if !viewModel.canGoNext && viewModel.dragOffset.height < 0 {
                    viewModel.dragOffset.height *= 0.3
                }
                if !viewModel.canGoPrevious && viewModel.dragOffset.height > 0 {
                    viewModel.dragOffset.height *= 0.3
                }
            }
            .onEnded { value in
                // Ignore gestures during transitions
                guard !viewModel.isTransitioning, !viewModel.isPerformingAction else { return }

                viewModel.isDragging = false

                let threshold: CGFloat = 100
                let actionThreshold: CGFloat = 120

                let verticalOffset = viewModel.dragOffset.height
                let horizontalOffset = viewModel.dragOffset.width
                let verticalVelocity = value.velocity.height
                let horizontalVelocity = value.velocity.width

                // Determine dominant direction
                let isVerticalDominant = abs(verticalVelocity) > abs(horizontalVelocity) ||
                                         abs(verticalOffset) > abs(horizontalOffset)

                var didNavigate = false
                var didPerformAction = false

                if isVerticalDominant {
                    // Vertical navigation
                    if abs(verticalVelocity) > 500 || abs(verticalOffset) > threshold {
                        if verticalOffset > 0 && viewModel.canGoPrevious {
                            viewModel.navigateToPrevious()
                            didNavigate = true
                        } else if verticalOffset < 0 && viewModel.canGoNext {
                            viewModel.navigateToNext()
                            didNavigate = true
                        } else if verticalOffset < 0 && !viewModel.canGoNext {
                            // End of rallies - show export
                            viewModel.showExportOptions = true
                        }
                    }
                } else {
                    // Horizontal actions
                    if abs(horizontalVelocity) > 300 || abs(horizontalOffset) > actionThreshold {
                        if horizontalOffset < -actionThreshold {
                            viewModel.performAction(.remove, direction: .left)
                            didPerformAction = true
                        } else if horizontalOffset > actionThreshold {
                            viewModel.performAction(.save, direction: .right)
                            didPerformAction = true
                        }
                    }
                }

                // Reset gesture state
                // If we performed action, reset immediately
                // If we navigated, let navigateTo() handle the animation continuation
                // Otherwise animate back smoothly
                if didPerformAction {
                    viewModel.dragOffset = .zero
                    viewModel.resetPeekProgress()
                } else if didNavigate {
                    // Don't reset - navigateTo() will continue the animation from current position
                    viewModel.resetPeekProgress()
                } else {
                    // No action - animate back to center
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.dragOffset = .zero
                        viewModel.resetPeekProgress()
                    }
                }
            }
    }

    // MARK: - Helpers

    private func performAction(_ action: RallySwipeAction) {
        let direction: RallySwipeDirection = action == .save ? .right : .left
        viewModel.performAction(action, direction: direction)
    }
}

// MARK: - Top Card Drag Modifier

/// Applies drag transforms only to the top card
struct TopCardDragModifier: ViewModifier {
    let isTopCard: Bool
    let dragOffset: CGSize
    let swipeOffset: CGFloat       // Horizontal swipe (actions)
    let swipeOffsetY: CGFloat      // Vertical swipe (navigation)
    let swipeRotation: Double

    func body(content: Content) -> some View {
        if isTopCard {
            content
                .offset(x: swipeOffset + dragOffset.width, y: swipeOffsetY + dragOffset.height)
                .rotationEffect(.degrees(swipeRotation + dragRotation))
        } else {
            content
        }
    }

    private var dragRotation: Double {
        // Slight rotation based on horizontal drag
        let rotation = Double(dragOffset.width) / 20.0
        return max(-15, min(15, rotation))
    }
}

// MARK: - Unified Rally Card

/// Single card component using custom AVPlayerLayer for smooth transitions
/// TikTok-style: adjacent players stay mounted, thumbnail visible until video playing
struct UnifiedRallyCard: View {
    let url: URL
    let rallyIndex: Int
    let size: CGSize
    let position: Int  // -1 = previous, 0 = current, 1+ = next
    let previousRallyIndex: Int?  // Track which rally was just current (for seamless transitions)
    let playerCache: RallyPlayerCache
    let thumbnailCache: RallyThumbnailCache

    @State private var thumbnail: UIImage?
    @State private var isVideoPlaying: Bool = false
    @State private var isLayerReadyForDisplay: Bool = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    private var isCurrent: Bool { position == 0 }
    private var isPreviousRally: Bool {
        guard let prevIndex = previousRallyIndex else { return false }
        return rallyIndex == prevIndex
    }
    private var isPreloaded: Bool { position >= -1 && position <= 1 }

    var body: some View {
        ZStack {
            Color.black

            // Thumbnail layer - ALWAYS visible as base layer (no opacity changes)
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            }

            // Video player layer ON TOP - only visible when first frame is actually rendered
            // This creates zero-gap layering: thumbnail always visible until video covers it
            if isPreloaded, let player = playerCache.getPlayer(for: url) {
                CustomVideoPlayerView(
                    player: player,
                    gravity: isPortrait ? .resizeAspect : .resizeAspectFill,
                    onReadyForDisplay: { isReady in
                        // Layer is ready when first video frame is ACTUALLY RENDERED
                        // Use Task to avoid state modification during view update
                        Task { @MainActor in
                            isLayerReadyForDisplay = isReady
                        }
                    }
                )
                .opacity(showVideo ? 1 : 0)
                .animation(.linear(duration: 0.05), value: showVideo)  // Fast fade-in when ready
                .allowsHitTesting(isCurrent)
                .onReceive(player.publisher(for: \.rate)) { rate in
                    // Video is playing when rate > 0
                    // Use Task to avoid state modification during view update
                    Task { @MainActor in
                        isVideoPlaying = rate > 0
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent {
                playerCache.togglePlayPause()
            }
        }
        .task(id: url) {
            thumbnail = await thumbnailCache.getThumbnailAsync(for: url)
        }
    }

    private var showVideo: Bool {
        // Show video when:
        // 1. Card is current AND video is playing AND first frame rendered (normal case)
        // 2. Card is the previous rally during transition (keeps old video visible until new one plays)
        let isCurrentAndReady = isCurrent && isVideoPlaying && isLayerReadyForDisplay
        let isDuringTransition = isPreviousRally && isVideoPlaying && isLayerReadyForDisplay

        return isCurrentAndReady || isDuringTransition
    }
}

// MARK: - Preview

#Preview {
    RallyPlayerView(
        videoMetadata: VideoMetadata(
            fileName: "test.mp4",
            customName: nil,
            folderPath: "",
            createdDate: Date(),
            fileSize: 0,
            duration: 60.0
        )
    )
}
