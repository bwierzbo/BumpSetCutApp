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
    @State private var rallyIndexToShare: ShareableRallyIndex?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppNavigationState.self) private var navigationState
    @EnvironmentObject private var appSettings: AppSettings

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    private var currentRallySegment: RallySegment? {
        guard let metadata = viewModel.processingMetadata,
              viewModel.currentRallyIndex < metadata.rallySegments.count else { return nil }
        return metadata.rallySegments[viewModel.currentRallyIndex]
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
                Color.bscMediaBackground.ignoresSafeArea()

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
                    trimAdjustments: viewModel.trimAdjustments,
                    onDismiss: { viewModel.showExportOptions = false }
                )
            }
            .sheet(isPresented: $viewModel.showOverviewSheet) {
                RallyOverviewSheet(
                    rallyVideoURLs: viewModel.rallyVideoURLs,
                    savedRallies: viewModel.savedRallies,
                    removedRallies: viewModel.removedRallies,
                    currentIndex: viewModel.currentRallyIndex,
                    thumbnailCache: viewModel.thumbnailCache,
                    onSelectRally: { index in
                        viewModel.jumpToRally(index)
                    },
                    onExport: {
                        viewModel.showOverviewSheet = false
                        viewModel.showExportOptions = true
                    },
                    onPostToCommunity: { index in
                        viewModel.showOverviewSheet = false
                        rallyIndexToShare = ShareableRallyIndex(index: index)
                    },
                    onDismiss: { viewModel.showOverviewSheet = false }
                )
            }
            .sheet(item: $rallyIndexToShare) { item in
                ShareRallySheet(
                    originalVideoURL: viewModel.videoMetadata.originalURL,
                    rallyVideoURLs: viewModel.rallyVideoURLs,
                    savedRallyIndices: viewModel.savedRalliesArray,
                    initialRallyIndex: item.index,
                    thumbnailCache: viewModel.thumbnailCache,
                    videoId: viewModel.videoMetadata.id,
                    rallyInfo: viewModel.savedRallyShareInfo
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
        .onChange(of: navigationState.postedHighlight) { _, highlight in
            if highlight != nil {
                rallyIndexToShare = nil
                dismiss()
            }
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
                    thumbnailCache: viewModel.thumbnailCache,
                    zoomScale: position == 0 ? viewModel.zoomScale : 1.0,
                    zoomOffset: position == 0 ? viewModel.zoomOffset : .zero,
                    onDoubleTap: position == 0 ? { toggleZoom(cardSize: geometry.size) } : nil
                )
                .scaleEffect(scaleForPosition(position))
                .offset(y: offsetForPosition(position))
                .opacity(opacityForPosition(position, rallyIndex: rallyIndex))
                .zIndex(zIndexForPosition(position, rallyIndex: rallyIndex))
                // Apply drag/swipe transforms (TikTok-style scroll)
                .modifier(TopCardDragModifier(
                    isTopCard: position == 0 && viewModel.previousRallyIndex == nil,
                    isSlidingOut: rallyIndex == viewModel.previousRallyIndex,
                    isSlidingIn: position == 0 && viewModel.previousRallyIndex != nil,
                    dragOffset: viewModel.dragOffset,
                    swipeOffset: viewModel.swipeOffset,
                    swipeOffsetY: viewModel.swipeOffsetY,
                    swipeRotation: viewModel.swipeRotation,
                    slideInOffset: viewModel.transitionDirection == .down
                        ? geometry.size.height : -geometry.size.height
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
                canUndo: viewModel.canUndo,
                onRemove: { performAction(.remove) },
                onUndo: { viewModel.undoLastAction() },
                onSave: { performAction(.save) }
            )
            .zIndex(200)

            // Trim overlay
            if viewModel.isTrimmingMode, let segment = currentRallySegment {
                RallyTrimOverlay(
                    trimBefore: $viewModel.currentTrimBefore,
                    trimAfter: $viewModel.currentTrimAfter,
                    rallyStartTime: segment.startTime,
                    rallyEndTime: segment.endTime,
                    videoURL: videoMetadata.originalURL,
                    videoDuration: viewModel.actualVideoDuration,
                    onScrub: { time in viewModel.scrubTo(time: time) },
                    onConfirm: { viewModel.confirmTrim() },
                    onCancel: { viewModel.cancelTrim() }
                )
                .zIndex(250)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
        .gesture(viewModel.isTrimmingMode ? nil : swipeGesture(geometry: geometry))
        .simultaneousGesture(pinchGesture())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard !viewModel.isTransitioning, !viewModel.isPerformingAction,
                          !viewModel.isTrimmingMode else { return }
                    viewModel.enterTrimMode()
                }
        )
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
    private func opacityForPosition(_ position: Int, rallyIndex: Int) -> Double {
        // Previous rally must be visible during transition (it's sliding out)
        if rallyIndex == viewModel.previousRallyIndex {
            return 1.0
        }

        switch position {
        case 0: return 1.0     // Current - fully visible
        case 1: return 1.0     // Next - fully visible (VideoPlayer hidden via internal opacity)
        default: return 0.0    // Others hidden but preloaded
        }
    }

    /// Z-index for card at given position
    private func zIndexForPosition(_ position: Int, rallyIndex: Int) -> Double {
        // Previous rally slides out ON TOP of everything except overlay
        if rallyIndex == viewModel.previousRallyIndex {
            return 150
        }

        switch position {
        case 0: return 100     // Current - below sliding-out card
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

                if viewModel.isZoomed {
                    // Pan within zoomed content
                    let newOffset = CGSize(
                        width: viewModel.baseZoomOffset.width + value.translation.width,
                        height: viewModel.baseZoomOffset.height + value.translation.height
                    )
                    viewModel.zoomOffset = clampedOffset(newOffset, scale: viewModel.zoomScale, cardSize: geometry.size)
                } else {
                    // Horizontal-only drag (no vertical navigation)
                    viewModel.dragOffset = CGSize(width: value.translation.width, height: 0)
                }
            }
            .onEnded { value in
                // Ignore gestures during transitions
                guard !viewModel.isTransitioning, !viewModel.isPerformingAction else { return }

                viewModel.isDragging = false

                if viewModel.isZoomed {
                    // Snap offset to bounds
                    viewModel.baseZoomOffset = viewModel.zoomOffset
                    return
                }

                let actionThreshold: CGFloat = 100
                let horizontalOffset = viewModel.dragOffset.width
                let horizontalVelocity = value.velocity.width
                let dragWidth = viewModel.dragOffset.width

                // Velocity-based or distance-based trigger
                let triggeredByVelocity = abs(horizontalVelocity) > 200
                let triggeredByDistance = abs(horizontalOffset) > actionThreshold

                if triggeredByVelocity || triggeredByDistance {
                    if horizontalOffset < 0 || (triggeredByVelocity && horizontalVelocity < -200) {
                        viewModel.performAction(.remove, direction: .left, fromDragOffset: dragWidth)
                        return
                    } else if horizontalOffset > 0 || (triggeredByVelocity && horizontalVelocity > 200) {
                        viewModel.performAction(.save, direction: .right, fromDragOffset: dragWidth)
                        return
                    }
                }

                // No action - animate back to center
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 25)) {
                    viewModel.dragOffset = .zero
                }
            }
    }

    // MARK: - Pinch-to-Zoom

    private func pinchGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = viewModel.baseZoomScale * value
                viewModel.zoomScale = min(max(newScale, 1.0), 5.0)
            }
            .onEnded { value in
                let newScale = viewModel.baseZoomScale * value
                viewModel.zoomScale = min(max(newScale, 1.0), 5.0)
                viewModel.baseZoomScale = viewModel.zoomScale

                if viewModel.zoomScale <= 1.01 {
                    viewModel.resetZoom()
                }
            }
    }

    private func toggleZoom(cardSize: CGSize) {
        if viewModel.isZoomed {
            viewModel.resetZoom()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                viewModel.zoomScale = 2.5
                viewModel.zoomOffset = .zero
            }
            viewModel.baseZoomScale = 2.5
            viewModel.baseZoomOffset = .zero
        }
    }

    /// Clamp pan offset so zoomed content stays visible
    private func clampedOffset(_ offset: CGSize, scale: CGFloat, cardSize: CGSize) -> CGSize {
        let maxX = max(0, (cardSize.width * scale - cardSize.width) / 2)
        let maxY = max(0, (cardSize.height * scale - cardSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    // MARK: - Helpers

    private func performAction(_ action: RallySwipeAction) {
        let direction: RallySwipeDirection = action == .save ? .right : .left
        viewModel.performAction(action, direction: direction)
    }
}

// MARK: - Top Card Drag Modifier

/// Applies drag/transition transforms for TikTok-style scroll navigation.
/// During transitions, old and new cards move together (connected edge-to-edge) like a continuous scroll.
///
/// IMPORTANT: Uses a single modifier chain (offset + rotation) for ALL states to preserve
/// SwiftUI structural identity. Using if/else branches causes view tree destruction/recreation,
/// which tears down AVPlayerLayer and causes black flash artifacts.
struct TopCardDragModifier: ViewModifier {
    let isTopCard: Bool        // Current card during normal drag (not during transition)
    let isSlidingOut: Bool     // Previous card sliding off-screen during transition
    let isSlidingIn: Bool      // New current card sliding in from off-screen during transition
    let dragOffset: CGSize
    let swipeOffset: CGFloat       // Horizontal swipe (actions)
    let swipeOffsetY: CGFloat      // Vertical swipe (navigation)
    let swipeRotation: Double
    let slideInOffset: CGFloat     // Card height offset for sliding-in card (+height or -height)

    func body(content: Content) -> some View {
        content
            .offset(x: computedOffsetX, y: computedOffsetY)
            .rotationEffect(.degrees(computedRotation))
    }

    private var computedOffsetX: CGFloat {
        if isTopCard {
            return swipeOffset + dragOffset.width
        }
        return 0
    }

    private var computedOffsetY: CGFloat {
        if isTopCard {
            return dragOffset.height
        } else if isSlidingOut {
            return swipeOffsetY
        } else if isSlidingIn {
            return swipeOffsetY + slideInOffset
        }
        return 0
    }

    private var computedRotation: Double {
        if isTopCard {
            return swipeRotation + dragRotation
        }
        return 0
    }

    private var dragRotation: Double {
        let rotation = Double(dragOffset.width) / 30.0
        return max(-10, min(10, rotation))
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
    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var onDoubleTap: (() -> Void)?

    @State private var thumbnail: UIImage?
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
            Color.bscMediaBackground

            // Thumbnail layer - fallback behind the video layer
            // Match video gravity: .fit in portrait, .fill in landscape
            if let thumbnail = thumbnail, showThumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: isPortrait ? .fit : .fill)
            }

            // Video player layer - always at full opacity for preloaded cards.
            // AVPlayerLayer has clear background, so it's transparent when no content
            // and shows the video frame when content is rendered. No opacity toggling
            // eliminates any flash from layer compositing delays.
            if isPreloaded, let player = playerCache.getPlayer(for: url) {
                CustomVideoPlayerView(
                    player: player,
                    gravity: isPortrait ? .resizeAspect : .resizeAspectFill,
                    onReadyForDisplay: { _ in }
                )
                .allowsHitTesting(isCurrent)
            }
        }
        .scaleEffect(zoomScale)
        .offset(zoomOffset)
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if isCurrent {
                onDoubleTap?()
            }
        }
        .onTapGesture(count: 1) {
            if isCurrent {
                playerCache.togglePlayPause()
            }
        }
        .task(id: url) {
            thumbnail = await thumbnailCache.getThumbnailAsync(for: url)
        }
    }

    private var showThumbnail: Bool {
        if isCurrent { return true }
        return isPreviousRally || position == 1
    }
}

// MARK: - Shareable Rally Index

/// Identifiable wrapper so `.sheet(item:)` works with an Int index.
struct ShareableRallyIndex: Identifiable {
    let id = UUID()
    let index: Int
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
