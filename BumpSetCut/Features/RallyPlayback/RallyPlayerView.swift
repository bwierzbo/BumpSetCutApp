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
                    size: geometry.size,
                    isCurrent: position == 0,
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
                    swipeRotation: viewModel.swipeRotation,
                    transitionOpacity: viewModel.transitionOpacity
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
        }
        .gesture(swipeGesture(geometry: geometry))
    }

    // MARK: - Stack Position Helpers

    /// Scale for card at given position (-1 = previous, 0 = current, 1 = next)
    private func scaleForPosition(_ position: Int) -> CGFloat {
        switch position {
        case 0: return 1.0     // Current - full size
        case 1: return 0.92    // Next - slightly smaller (peek effect)
        default: return 1.0    // Others hidden
        }
    }

    /// Y offset for card at given position
    private func offsetForPosition(_ position: Int) -> CGFloat {
        switch position {
        case 0: return 0       // Current - no offset
        case 1: return 30      // Next - peek from behind
        default: return 0      // Others hidden
        }
    }

    /// Opacity for card at given position
    private func opacityForPosition(_ position: Int) -> Double {
        switch position {
        case 0: return 1.0     // Current - fully visible
        case 1: return 0.85    // Next - slightly faded (peek)
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

                if isVerticalDominant {
                    // Vertical navigation
                    if abs(verticalVelocity) > 500 || abs(verticalOffset) > threshold {
                        if verticalOffset > 0 && viewModel.canGoPrevious {
                            viewModel.navigateToPrevious()
                        } else if verticalOffset < 0 && viewModel.canGoNext {
                            viewModel.navigateToNext()
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
                        } else if horizontalOffset > actionThreshold {
                            viewModel.performAction(.save, direction: .right)
                        }
                    }
                }

                // Reset gesture state
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    viewModel.dragOffset = .zero
                    viewModel.resetPeekProgress()
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
    let swipeOffset: CGFloat
    let swipeRotation: Double
    let transitionOpacity: Double

    func body(content: Content) -> some View {
        if isTopCard {
            content
                .offset(x: swipeOffset + dragOffset.width, y: dragOffset.height)
                .rotationEffect(.degrees(swipeRotation + dragRotation))
                .opacity(transitionOpacity)
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

/// Single card component that shows thumbnail or video based on position
/// Avoids component swapping for smoother transitions
struct UnifiedRallyCard: View {
    let url: URL
    let size: CGSize
    let isCurrent: Bool
    let playerCache: RallyPlayerCache
    let thumbnailCache: RallyThumbnailCache

    @State private var thumbnail: UIImage?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            Color.black

            // Always show thumbnail as base layer
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            }

            // Overlay video player only when current (covers thumbnail)
            if isCurrent {
                VideoPlayer(player: playerCache.getOrCreatePlayer(for: url))
                    .disabled(true)
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
