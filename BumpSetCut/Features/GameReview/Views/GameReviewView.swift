//
//  GameReviewView.swift
//  BumpSetCut
//
//  Full-screen Game Review player styled like Rally Viewer with score overlay.
//

import SwiftUI
import AVKit

struct GameReviewView: View {
    let videoMetadata: VideoMetadata

    @State private var viewModel: GameReviewViewModel
    @State private var dragOffset: CGSize = .zero
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool { verticalSizeClass == .regular }

    // MARK: - Initialization

    init(videoMetadata: VideoMetadata, setup: GameSetup) {
        self.videoMetadata = videoMetadata
        self._viewModel = State(wrappedValue: GameReviewViewModel(videoMetadata: videoMetadata, setup: setup))
    }

    init(videoMetadata: VideoMetadata, state: GameReviewState) {
        self.videoMetadata = videoMetadata
        self._viewModel = State(wrappedValue: GameReviewViewModel(videoMetadata: videoMetadata, state: state))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.bscMediaBackground.ignoresSafeArea()

                switch viewModel.loadingState {
                case .loading:
                    ProgressView("Loading rallies...")
                        .foregroundStyle(.white)

                case .error(let message):
                    VStack(spacing: BSCSpacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.bscWarning)
                        Text(message)
                            .foregroundStyle(.white)
                        Button("Dismiss") { dismiss() }
                            .buttonStyle(.bordered)
                    }

                case .empty:
                    VStack(spacing: BSCSpacing.md) {
                        Text("No rallies found")
                            .foregroundStyle(.white)
                        Button("Dismiss") { dismiss() }
                            .buttonStyle(.bordered)
                    }

                case .loaded:
                    gameReviewContent(geometry: geometry)
                }
            }
        }
        .task { await viewModel.loadRallies() }
        .onDisappear { viewModel.cleanup() }
        .sheet(isPresented: $viewModel.showCorrectionSheet) {
            GameCorrectionSheet(
                currentServer: viewModel.currentServer,
                onConfirm: { winner, server, applyToRest in
                    viewModel.applyCorrection(winner: winner, server: server, applyToRest: applyToRest)
                },
                onCancel: {
                    viewModel.showCorrectionSheet = false
                    viewModel.playerCache.play()
                }
            )
        }
        .sheet(isPresented: $viewModel.showSummary) {
            GameSummaryView(
                score: viewModel.currentScore,
                decisions: viewModel.decisions,
                isExporting: viewModel.isExporting,
                exportProgress: viewModel.exportProgress,
                exportedURL: viewModel.exportedURL,
                exportError: viewModel.exportError,
                showShareSheet: $viewModel.showShareSheet,
                onExport: { viewModel.exportGameVideo() },
                onClose: { dismiss() }
            )
        }
    }

    // MARK: - Game Review Content

    private func gameReviewContent(geometry: GeometryProxy) -> some View {
        ZStack {
            // Video Player
            if let player = viewModel.playerCache.currentPlayer {
                CustomVideoPlayerView(
                    player: player,
                    gravity: isPortrait ? .resizeAspect : .resizeAspectFill,
                    onReadyForDisplay: { _ in }
                )
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.playerCache.togglePlayPause()
                }
            }

            // Top bar — back button + rally counter
            VStack {
                HStack(alignment: .top) {
                    // Back button (matches Rally Viewer style)
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color.bscSurfaceGlass)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                    )
                            )
                    }

                    Spacer()

                    // Undo button
                    if !viewModel.decisions.isEmpty {
                        Button { viewModel.undoLastDecision() } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(
                                    Circle()
                                        .fill(Color.bscSurfaceGlass)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                        )
                                )
                        }
                    }
                }
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.top, BSCSpacing.md)

                Spacer()
            }
            .zIndex(200)

            // Bottom section — score + swipe hints
            VStack {
                Spacer()

                // Swipe hints
                swipeHints
                    .padding(.bottom, BSCSpacing.sm)

                // Score overlay at bottom
                GameScoreOverlay(
                    score: viewModel.currentScore,
                    currentServer: viewModel.currentServer,
                    nearMappedTo: viewModel.nearMappedTo,
                    currentRallyIndex: viewModel.currentRallyIndex,
                    totalRallies: viewModel.totalRallies
                )
                .padding(.bottom, BSCSpacing.lg)
            }
            .zIndex(200)

            // Drag feedback overlay
            if dragOffset.width != 0 {
                dragFeedbackOverlay
                    .zIndex(300)
            }
        }
        .gesture(swipeGesture(geometry: geometry))
        .onLongPressGesture(minimumDuration: 0.5) {
            viewModel.enterTrimMode()
        }
    }

    // MARK: - Swipe Hints

    private var swipeHints: some View {
        HStack {
            VStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                Text("Correct")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.3))
            .padding(.leading, BSCSpacing.xl)

            Spacer()

            VStack(spacing: 2) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                Text("Confirm")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.3))
            .padding(.trailing, BSCSpacing.xl)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drag Feedback Overlay

    private var dragFeedbackOverlay: some View {
        Group {
            if dragOffset.width > 40 {
                // Swiping right — confirm (green edge glow)
                HStack {
                    Spacer()
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.bscSuccess.opacity(0.4), Color.clear],
                                startPoint: .trailing,
                                endPoint: .leading
                            )
                        )
                        .frame(width: min(abs(dragOffset.width), 120))
                        .ignoresSafeArea()
                }
            } else if dragOffset.width < -40 {
                // Swiping left — correct (orange edge glow)
                HStack {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.bscOrange.opacity(0.4), Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: min(abs(dragOffset.width), 120))
                        .ignoresSafeArea()
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Swipe Gesture

    private func swipeGesture(geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                withAnimation(.interactiveSpring()) {
                    dragOffset = value.translation
                }
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let velocity = value.velocity.width
                let threshold: CGFloat = 80
                let velocityThreshold: CGFloat = 300

                let triggeredByDistance = abs(horizontal) > threshold
                let triggeredByVelocity = abs(velocity) > velocityThreshold

                if (triggeredByDistance || triggeredByVelocity) && horizontal > 0 {
                    // Swipe right = confirm
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                    viewModel.confirmRally()
                } else if (triggeredByDistance || triggeredByVelocity) && horizontal < 0 {
                    // Swipe left = correct
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                    viewModel.openCorrection()
                } else {
                    // Snap back
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                }
            }
    }
}
