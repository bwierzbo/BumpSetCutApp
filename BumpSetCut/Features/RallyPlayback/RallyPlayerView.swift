//
//  RallyPlayerView.swift
//  BumpSetCut
//
//  Unified rally player with vertical swipe navigation
//

import SwiftUI
import AVKit

// MARK: - Rally Player View

struct RallyPlayerView: View {
    // MARK: - Properties

    let videoMetadata: VideoMetadata

    @State private var viewModel: RallyPlayerViewModel
    @State private var showingGestureTips = false
    @State private var showTrimHint = false
    @State private var showTimelineEditor = false
    @State private var showReportMistake = false
    @State private var showAddMissedRallyPrompt = false
    @State private var rallyIndexToShare: ShareableRallyIndex?
    /// Pending "choose which saved rallies" step. Posting and exporting run the
    /// same picker; the target's purpose says which one it is finishing.
    @State private var pendingPicker: RallyPickerTarget?
    /// Which rallies the export sheet should work on. nil means every saved
    /// rally, which is the case when there was only one to begin with.
    @State private var exportSelection: [Int]?
    /// "Send to Friend": the rally on its way to the send sheet, and the
    /// "Sent to @x" toast once it has gone.
    @State private var sendRequest: SendToRequest?
    @State private var sendToast: BSCToastMessage?
    @State private var showPostAnotherPrompt = false
    /// Rotation captured at the start of a two-finger twist (RotationGesture
    /// reports angle relative to its own start).
    @State private var twistBaseRotation: Double?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppNavigationState.self) private var navigationState
    @Environment(AppSettings.self) private var appSettings
    @Environment(AuthenticationService.self) private var authService

    private var currentRallySegment: RallySegment? {
        guard let metadata = viewModel.processingMetadata,
              viewModel.currentRallyIndex < metadata.rallySegments.count else { return nil }
        return metadata.rallySegments[viewModel.currentRallyIndex]
    }

    // MARK: - Initialization

    init(videoMetadata: VideoMetadata, mediaStore: MediaStore) {
        self.videoMetadata = videoMetadata
        self._viewModel = State(wrappedValue: RallyPlayerViewModel(videoMetadata: videoMetadata, mediaStore: mediaStore))
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
                    RallyEmptyView(
                        onAddManually: { showTimelineEditor = true },
                        onDismiss: { dismiss() }
                    )

                case .loaded:
                    rallyContent(geometry: geometry)
                }
            }
            .sheet(isPresented: $viewModel.showExportOptions, onDismiss: { exportSelection = nil }) {
                RallyExportSheet(
                    savedRallies: exportSelection ?? viewModel.savedRalliesArray,
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
                    favoritedRallies: viewModel.favoritedRallies,
                    currentIndex: viewModel.currentRallyIndex,
                    thumbnailCache: viewModel.thumbnailCache,
                    onSelectRally: { index in
                        viewModel.showOverviewSheet = false
                        viewModel.jumpToRally(index)
                    },
                    onExport: {
                        leaveOverview()
                        // Same as posting: more than one saved rally means
                        // choosing which ones, rather than taking them all.
                        if let target = rallyPickerTarget(for: .export) {
                            presentPickerAfterOverview(target)
                        } else {
                            exportSelection = nil
                            viewModel.showExportOptions = true
                        }
                    },
                    onPostToCommunity: { index, postAll in
                        leaveOverview()
                        // More than one saved rally: choose which ones go in
                        // the post rather than posting them all.
                        if postAll, let target = rallyPickerTarget(for: .post) {
                            presentPickerAfterOverview(target)
                        } else {
                            rallyIndexToShare = ShareableRallyIndex(index: index, postAllSaved: false)
                        }
                    },
                    onSaveAll: { viewModel.saveAllRallies() },
                    onDeselectAll: { viewModel.deselectAllRallies() },
                    onEditTimeline: {
                        viewModel.showOverviewSheet = false
                        showTimelineEditor = true
                    },
                    onDismiss: {
                        viewModel.showOverviewSheet = false
                        Task {
                            await viewModel.copyFavoritesToLibrary()
                            dismiss()
                        }
                    }
                )
            }
            .fullScreenCover(isPresented: $showTimelineEditor) {
                RallyTimelineView(
                    videoURL: videoMetadata.originalURL,
                    videoId: videoMetadata.originalVideoId ?? videoMetadata.id,
                    metadataStore: viewModel.metadataStore,
                    onSaved: {
                        Task { await viewModel.reloadAfterTimelineEdit() }
                    }
                )
            }
            .sheet(item: $pendingPicker) { target in
                ClipPickerSheet(
                    title: "Saved rallies",
                    items: target.items,
                    maxSelection: target.purpose.maxSelection(itemCount: target.items.count),
                    confirmTitle: target.purpose.confirmTitle,
                    onConfirm: { indices in
                        pendingPicker = nil
                        guard !indices.isEmpty else { return }
                        // Let the picker finish dismissing before the next
                        // sheet comes up (same pattern as favorites).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            finishPicking(indices, for: target.purpose)
                        }
                    },
                    onCancel: { pendingPicker = nil }
                )
            }
            .sheet(item: $sendRequest) { request in
                SendToSheet(payload: request.payload) { conversationId, username in
                    sendToast = .sent(to: username, conversationId: conversationId, navigationState: navigationState)
                }
            }
            .bscToast($sendToast)
            .sheet(item: $rallyIndexToShare) { item in
                ShareRallySheet(
                    originalVideoURL: viewModel.videoMetadata.originalURL,
                    rallyVideoURLs: viewModel.rallyVideoURLs,
                    savedRallyIndices: item.selectedIndices ?? viewModel.savedRalliesArray,
                    initialRallyIndex: item.index,
                    thumbnailCache: viewModel.thumbnailCache,
                    videoId: viewModel.videoMetadata.id,
                    rallyInfo: viewModel.savedRallyShareInfo,
                    postAllSaved: item.postAllSaved
                )
            }
            // File a favorited rally into a named collection ("Choose Folder" on the toast)
            .sheet(item: $viewModel.collectionPickerTarget) { target in
                CollectionPickerSheet(
                    mediaStore: viewModel.mediaStore,
                    libraryType: .favorites,
                    title: "Save to Collection",
                    rootLabel: "Favorites",
                    confirmLabel: "Save to",
                    initialSelection: viewModel.favoriteCollection(for: target.rallyIndex),
                    onSelect: { name in viewModel.selectFavoriteCollection(name) },
                    onCancel: { viewModel.collectionPickerTarget = nil }
                )
            }
            // Quick share of the current rally via the native share sheet
            .sheet(isPresented: Binding(
                get: { viewModel.shareURL != nil },
                set: { if !$0 { viewModel.shareURL = nil } }
            )) {
                if let url = viewModel.shareURL {
                    ActivityViewController(activityItems: [url])
                }
            }
            .alert("Share Failed", isPresented: Binding(
                get: { viewModel.shareErrorMessage != nil },
                set: { if !$0 { viewModel.shareErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.shareErrorMessage ?? "Couldn't prepare the clip for sharing.")
            }
            .sheet(isPresented: $showReportMistake) {
                ReportMistakeSheet { reason in
                    viewModel.reportCurrentRallyMistake(reason: reason)
                    // "Missed a whole rally" → the user knows where one is;
                    // offer to fix it on the timeline right now.
                    if reason == "missed_rally" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            showAddMissedRallyPrompt = true
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .alert("Report Sent", isPresented: $showAddMissedRallyPrompt) {
                Button("Add It on the Timeline") { showTimelineEditor = true }
                Button("Done", role: .cancel) {}
            } message: {
                Text("Want to add the missed rally yourself? Rallies you add also help train detection.")
            }
            .bscToast(Binding(
                get: { viewModel.favoritesErrorMessage.map { BSCToastMessage(text: $0, style: .error) } },
                set: { if $0 == nil { viewModel.favoritesErrorMessage = nil } }
            ))
        }
        .task(id: videoMetadata.id) {
            await viewModel.loadRallies()
        }
        .onAppear {
            // Show gesture tips on first launch
            if !appSettings.hasSeenRallyTips {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingGestureTips = true
                }
            }
            // Trim coach mark: appears after the video settles, hides after a
            // while, and stops appearing for good once the user has trimmed.
            if !appSettings.hasUsedRallyTrim {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.bscSpring) { showTrimHint = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    withAnimation(.bscQuick) { showTrimHint = false }
                }
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .onChange(of: navigationState.postedHighlight) { _, highlight in
            guard highlight != nil else { return }
            // Remember what just went up, then offer another post from this
            // same game rather than dropping the user straight into the feed.
            let justPosted = rallyIndexToShare.map { $0.selectedIndices ?? [$0.index] } ?? []
            rallyIndexToShare = nil
            viewModel.markRalliesPosted(justPosted)

            if rallyPickerTarget(for: .post) != nil {
                showPostAnotherPrompt = true
            } else {
                dismiss()
            }
        }
        .alert("Posted", isPresented: $showPostAnotherPrompt) {
            Button("Post Another") {
                // Fresh target so the picker reflects what's now posted.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pendingPicker = rallyPickerTarget(for: .post)
                }
            }
            Button("Done", role: .cancel) { dismiss() }
        } message: {
            Text("Your rally is live. Post another from this game?")
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
                // Current card reads live gesture zoom (seeded from the saved
                // framing, edited by pinch/pan in trim mode); other cards read
                // their persisted zoom/pan directly.
                let cardZoom = position == 0 ? viewModel.zoomScale : viewModel.zoom(for: rallyIndex)
                let cardOffset = position == 0 ? viewModel.zoomOffset : viewModel.panOffset(for: rallyIndex)

                // Unified card - no component swapping for smooth transitions
                UnifiedRallyCard(
                    url: url,
                    rallyIndex: rallyIndex,
                    size: geometry.size,
                    position: position,
                    previousRallyIndex: viewModel.previousRallyIndex,
                    playerCache: viewModel.playerCache,
                    thumbnailCache: viewModel.thumbnailCache,
                    videoDisplaySize: viewModel.videoDisplaySize,
                    rotationDegrees: viewModel.rotationDegrees(for: rallyIndex),
                    zoomScale: cardZoom,
                    zoomOffset: cardOffset,
                    onDoubleTap: position == 0 ? { toggleZoom(cardSize: geometry.size) } : nil
                )
                .scaleEffect(scaleForPosition(position))
                .offset(y: offsetForPosition(position))
                .opacity(opacityForPosition(position, rallyIndex: rallyIndex))
                .zIndex(zIndexForPosition(position, rallyIndex: rallyIndex))
                // Apply drag/swipe transforms (vertical scroll)
                .modifier(TopCardDragModifier(
                    isTopCard: position == 0 && viewModel.previousRallyIndex == nil,
                    isSlidingOut: rallyIndex == viewModel.previousRallyIndex,
                    isSlidingIn: position == 0 && viewModel.previousRallyIndex != nil,
                    dragOffset: viewModel.dragOffset,
                    swipeOffset: viewModel.swipeOffset,
                    swipeOffsetY: viewModel.swipeOffsetY,
                    swipeRotation: viewModel.swipeRotation,
                    slideInOffset: viewModel.transitionDirection == .down
                        ? geometry.size.height : -geometry.size.height,
                    actionSwipeOffsetY: viewModel.actionSwipeOffsetY
                ))
            }

            // Navigation overlay (above all cards)
            RallyPlayerOverlay(
                currentIndex: viewModel.currentRallyIndex,
                totalCount: viewModel.totalRallies,
                isSaved: viewModel.currentRallyIsSaved,
                isRemoved: viewModel.currentRallyIsRemoved,
                isFavorited: viewModel.currentRallyIsFavorited,
                onDismiss: {
                    Task {
                        await viewModel.copyFavoritesToLibrary()
                        dismiss()
                    }
                },
                onShowTips: { showingGestureTips = true },
                onShowOverview: { viewModel.showOverviewSheet = true },
                onShare: { viewModel.shareCurrentRally() },
                // Sending needs an account; signed out, the button is just
                // the system share sheet.
                onSendToFriend: authService.isAuthenticated
                    ? { sendRequest = sendRequestForRally(viewModel.currentRallyIndex) }
                    : nil,
                isPreparingShare: viewModel.isPreparingShare
            )
            .zIndex(200)

            // Action buttons (above all cards) - hidden while trimming or while
            // the rotation-propagation prompt is up.
            if !interactionBlocked {
                RallyActionButtons(
                    isSaved: viewModel.currentRallyIsSaved,
                    isRemoved: viewModel.currentRallyIsRemoved,
                    isFavorited: viewModel.currentRallyIsFavorited,
                    canUndo: viewModel.canUndo,
                    onRemove: { performAction(.remove) },
                    onUndo: { viewModel.undoLastAction() },
                    onFavorite: { viewModel.performAction(.favorite, direction: .up) },
                    onSave: { performAction(.save) }
                )
                .zIndex(200)
                .transition(.opacity)
            }

            // Report-a-mistake affordance (data flywheel, opted-in users only).
            // Top-trailing, below the overlay chrome — tester feedback: at the
            // bottom it sat nearly on top of the Save action button.
            if viewModel.isFlywheelEnabled && !interactionBlocked {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showReportMistake = true
                        } label: {
                            Image(systemName: viewModel.currentVideoIsReported ? "flag.fill" : "flag")
                                .bscFont(size: 14, weight: .semibold)
                                .foregroundColor(viewModel.currentVideoIsReported ? .bscOrange : .bscOnMedia)
                                .padding(BSCSpacing.sm)
                                .background(Color.bscMediaScrimBase.opacity(0.35))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.bscOrange,
                                                    lineWidth: viewModel.currentVideoIsReported ? 1.5 : 0)
                                )
                                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(viewModel.currentVideoIsReported ? "Video reported" : "Report a detection mistake")
                        .padding(.trailing, BSCSpacing.lg)
                        .padding(.top, verticalSizeClass == .compact ? 76 : 120)
                    }
                    Spacer()
                }
                .zIndex(200)
                .transition(.opacity)
            }

            // "Hold to trim" coach mark — shows every session until the user
            // actually enters trim mode once (tester feedback: the one-time
            // tips overlay wasn't enough to make trimming discoverable).
            if showTrimHint && !appSettings.hasUsedRallyTrim && !showingGestureTips && !interactionBlocked {
                VStack {
                    Spacer()
                    TrimCoachMark()
                        .padding(.bottom, verticalSizeClass == .compact ? 130 : 170)
                }
                .allowsHitTesting(false)
                .zIndex(210)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Trim overlay
            if viewModel.isTrimmingMode, let segment = currentRallySegment {
                RallyTrimOverlay(
                    trimBefore: $viewModel.currentTrimBefore,
                    trimAfter: $viewModel.currentTrimAfter,
                    trimRotation: $viewModel.currentTrimRotation,
                    trimZoom: $viewModel.currentTrimZoom,
                    rallyStartTime: segment.startTime,
                    rallyEndTime: segment.endTime,
                    videoURL: videoMetadata.originalURL,
                    videoDuration: viewModel.actualVideoDuration,
                    onScrub: { time in viewModel.scrubTo(time: time) },
                    onConfirm: { viewModel.confirmTrim() },
                    onCancel: { viewModel.cancelTrim() },
                    onResetZoom: { resetTrimZoom() },
                    onExtendPlaybackStart: { time in viewModel.beginTrimExtendPlayback(from: time) },
                    onExtendPlaybackEnd: { time in viewModel.endTrimExtendPlayback(at: time) },
                    showsZoomControl: true
                )
                .zIndex(250)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Action feedback (topmost)
            if let feedback = viewModel.actionFeedback {
                let favoriteIndex = feedback.type == .favorite ? feedback.rallyIndex : nil
                RallyActionFeedbackView(
                    feedback: feedback,
                    isShowing: viewModel.showActionFeedback,
                    actionLabel: favoriteIndex != nil ? "Choose Folder" : nil,
                    onAction: favoriteIndex.map { index in
                        { viewModel.presentCollectionPicker(for: index) }
                    }
                )
                .zIndex(300)
            }

            // Adjustment propagation prompt - video stays paused & dimmed behind it
            if let pending = viewModel.pendingPropagation {
                AdjustmentPropagationPrompt(
                    rotation: pending.rotation,
                    zoom: pending.zoom,
                    onYes: { viewModel.resolvePropagation(applyToRest: true) },
                    onNo: { viewModel.resolvePropagation(applyToRest: false) }
                )
                .zIndex(350)
                .transition(.opacity)
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
                    .allowsHitTesting(false)
                    .zIndex(500)
            }

            // Saving favorites overlay — favorite clips export to the library on
            // exit/export/share, which can take a few seconds. Show progress so the
            // back button doesn't appear frozen.
            if viewModel.isSavingFavorites {
                RallyBufferingOverlay(message: "Saving favorites…")
                    .zIndex(550)
            }
        }
        // Navigation swipe — disabled while trimming or while the prompt is up.
        .gesture(interactionBlocked ? nil : swipeGesture(geometry: geometry))
        // Trim-mode direct manipulation: pinch zoom, twist angle, drag pan.
        .simultaneousGesture(viewModel.isTrimmingMode ? trimEditGesture(geometry: geometry) : nil)
        // Free pinch for normal viewing (disabled in trim mode / prompt).
        .simultaneousGesture(interactionBlocked ? nil : pinchGesture())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard !viewModel.isTransitioning, !viewModel.isPerformingAction,
                          !viewModel.isTrimmingMode, !viewModel.isAwaitingPropagationChoice else { return }
                    appSettings.hasUsedRallyTrim = true
                    withAnimation(.bscQuick) { showTrimHint = false }
                    viewModel.enterTrimMode()
                }
        )
        .onAppear {
            viewModel.updateCardSize(geometry.size, isPortrait: isPortrait)
            viewModel.seedZoomForCurrentRally()
        }
        .onChange(of: geometry.size) { _, newSize in
            // Outside any animation: this is a correction, not a move the user
            // asked for. Left inside the rotation's transaction, SwiftUI
            // animates the pan from its stale value to the right one, which is
            // the slide-to-centre you see after the device turns.
            withTransaction(Transaction(animation: nil)) {
                viewModel.updateCardSize(newSize, isPortrait: isPortrait)
                if !viewModel.isTrimmingMode {
                    viewModel.seedZoomForCurrentRally()
                }
            }
        }
        // The size class flips as part of the rotation rather than after the
        // size settles, so re-measuring here lands the correct framing earlier.
        // Fit vs fill follows the size class, so the video rect changes now
        // even though the card's points haven't yet.
        .onChange(of: verticalSizeClass) { _, _ in
            withTransaction(Transaction(animation: nil)) {
                viewModel.updateCardSize(geometry.size, isPortrait: isPortrait)
                if !viewModel.isTrimmingMode {
                    viewModel.seedZoomForCurrentRally()
                }
            }
        }
    }

    /// Same rule the card uses to choose fit (portrait) or fill (landscape).
    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    /// Trimming, or the propagation prompt waiting for an answer: swiping and
    /// long-pressing are disabled, and the normal chrome stays hidden.
    private var interactionBlocked: Bool {
        viewModel.isTrimmingMode || viewModel.isAwaitingPropagationChoice
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
                    // Lock drag axis after initial movement exceeds threshold
                    if viewModel.dragAxis == nil {
                        let absW = abs(value.translation.width)
                        let absH = abs(value.translation.height)
                        if absW > 10 || absH > 10 {
                            viewModel.dragAxis = absW >= absH ? .horizontal : .vertical
                            // Subtle tick the moment the swipe direction is committed.
                            UIImpactFeedbackGenerator.light()
                        }
                    }

                    switch viewModel.dragAxis {
                    case .horizontal, .none:
                        viewModel.dragOffset = CGSize(width: value.translation.width, height: 0)
                    case .vertical:
                        // Only track upward drags (negative height)
                        let clampedHeight = min(value.translation.height, 0)
                        viewModel.dragOffset = CGSize(width: 0, height: clampedHeight)
                    }
                }
            }
            .onEnded { value in
                // Ignore gestures during transitions
                guard !viewModel.isTransitioning, !viewModel.isPerformingAction else { return }

                let lockedAxis = viewModel.dragAxis
                viewModel.isDragging = false
                viewModel.dragAxis = nil

                if viewModel.isZoomed {
                    // Snap offset to bounds
                    viewModel.baseZoomOffset = viewModel.zoomOffset
                    return
                }

                let actionThreshold: CGFloat = 150

                if lockedAxis == .vertical {
                    // Vertical swipe-up → favorite
                    let verticalOffset = viewModel.dragOffset.height  // negative = up
                    let verticalVelocity = value.velocity.height       // negative = up
                    let triggeredByVelocity = verticalVelocity < -300
                    let triggeredByDistance = verticalOffset < -actionThreshold

                    if triggeredByVelocity || triggeredByDistance {
                        viewModel.performAction(.favorite, direction: .up, fromDragOffset: viewModel.dragOffset.height)
                        return
                    }
                } else {
                    // Horizontal swipe → save/remove
                    let horizontalOffset = viewModel.dragOffset.width
                    let horizontalVelocity = value.velocity.width
                    let dragWidth = viewModel.dragOffset.width

                    let triggeredByVelocity = abs(horizontalVelocity) > 300
                    let triggeredByDistance = abs(horizontalOffset) > actionThreshold

                    if triggeredByVelocity || triggeredByDistance {
                        if horizontalOffset < 0 || (triggeredByVelocity && horizontalVelocity < -300) {
                            viewModel.performAction(.remove, direction: .left, fromDragOffset: dragWidth)
                            return
                        } else if horizontalOffset > 0 || (triggeredByVelocity && horizontalVelocity > 300) {
                            viewModel.performAction(.save, direction: .right, fromDragOffset: dragWidth)
                            return
                        }
                    }
                }

                // No action - animate back to center
                withAnimation(.bscSwipe) {
                    viewModel.dragOffset = .zero
                }
            }
    }

    // MARK: - Pinch-to-Zoom

    private func pinchGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let clamped = min(max(viewModel.baseZoomScale * value, 1.0), 5.0)
                // Tick once when first reaching the zoom cap.
                if clamped == 5.0 && viewModel.zoomScale < 5.0 {
                    UIImpactFeedbackGenerator.light()
                }
                viewModel.zoomScale = clamped
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
            withAnimation(.bscSnappy) {
                viewModel.zoomScale = 2.5
                viewModel.zoomOffset = .zero
            }
            viewModel.baseZoomScale = 2.5
            viewModel.baseZoomOffset = .zero
        }
    }

    // MARK: - Trim-Mode Editing (pinch zoom · twist angle · drag pan)

    private func trimEditGesture(geometry: GeometryProxy) -> some Gesture {
        let zoomLimit: CGFloat = 3.0
        let angleLimit: Double = 10.0

        let magnify = MagnificationGesture()
            .onChanged { value in
                let newScale = min(max(viewModel.baseZoomScale * value, 1.0), zoomLimit)
                // Tick once when first reaching the zoom cap.
                if newScale == zoomLimit && viewModel.zoomScale < zoomLimit {
                    UIImpactFeedbackGenerator.light()
                }
                viewModel.zoomScale = newScale
                viewModel.zoomOffset = clampedOffset(viewModel.zoomOffset, scale: newScale, cardSize: geometry.size)
            }
            .onEnded { _ in
                viewModel.baseZoomScale = viewModel.zoomScale
                viewModel.baseZoomOffset = viewModel.zoomOffset
            }

        let twist = RotationGesture()
            .onChanged { angle in
                if twistBaseRotation == nil { twistBaseRotation = viewModel.currentTrimRotation }
                let proposed = (twistBaseRotation ?? 0) + angle.degrees
                viewModel.currentTrimRotation = min(max(proposed, -angleLimit), angleLimit)
            }
            .onEnded { _ in
                twistBaseRotation = nil
            }

        let pan = DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: viewModel.baseZoomOffset.width + value.translation.width,
                    height: viewModel.baseZoomOffset.height + value.translation.height
                )
                viewModel.zoomOffset = clampedOffset(proposed, scale: viewModel.zoomScale, cardSize: geometry.size)
            }
            .onEnded { _ in
                viewModel.baseZoomOffset = viewModel.zoomOffset
            }

        return magnify.simultaneously(with: twist).simultaneously(with: pan)
    }

    /// Reset the live editing zoom/pan to 1× / centered (overlay reset button).
    private func resetTrimZoom() {
        withAnimation(.bscSnappy) {
            viewModel.zoomScale = 1.0
            viewModel.zoomOffset = .zero
        }
        viewModel.baseZoomScale = 1.0
        viewModel.baseZoomOffset = .zero
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

    // MARK: - Saved-Rally Picker (posting & exporting)

    /// Shared prelude to posting or exporting from the overview.
    private func leaveOverview() {
        viewModel.showOverviewSheet = false
        Task { await viewModel.copyFavoritesToLibrary() }
    }

    /// Put the picker up once the overview has finished animating out —
    /// chaining one sheet straight onto another is flaky in SwiftUI.
    private func presentPickerAfterOverview(_ target: RallyPickerTarget) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pendingPicker = target }
    }

    /// Hand the chosen rallies to whichever flow opened the picker.
    private func finishPicking(_ indices: [Int], for purpose: RallyPickerPurpose) {
        switch purpose {
        case .post:
            rallyIndexToShare = ShareableRallyIndex(
                index: indices[0],
                postAllSaved: indices.count > 1,
                selectedIndices: indices
            )
        case .export:
            exportSelection = indices.sorted()
            viewModel.showExportOptions = true
        }
    }

    /// The rally on screen as a private clip: the source file plus this
    /// rally's trim-aware time range — the same slice the share sheet exports.
    /// It needn't be saved; sending is a share, not a review decision.
    private func sendRequestForRally(_ index: Int) -> SendToRequest? {
        let start = viewModel.effectiveStartTime(for: index)
        let end = viewModel.effectiveEndTime(for: index)
        guard end > start else { return nil }
        let clip = FavoriteShareClip(
            url: viewModel.videoMetadata.originalURL,
            timeRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            ),
            duration: end - start,
            displayName: "Rally \(index + 1)"
        )
        return SendToRequest(payload: .clip(clip))
    }

    /// Saved rallies as picker items. All rallies live in the one source
    /// video, so each item is that file plus the rally's time range — which
    /// is also what the hold-to-preview player uses. Nil when there's
    /// nothing to choose between.
    private func rallyPickerTarget(for purpose: RallyPickerPurpose) -> RallyPickerTarget? {
        let info = viewModel.savedRallyShareInfo
        let items: [ClipPickerItem<Int>] = viewModel.savedRalliesArray.sorted().compactMap { index in
            guard let rally = info[index] else { return nil }
            let duration = max(0, rally.endTime - rally.startTime)
            return ClipPickerItem(
                id: UUID(),
                payload: index,
                url: viewModel.videoMetadata.originalURL,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: rally.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600)
                ),
                displayName: "Rally \(index + 1)",
                duration: duration,
                isPosted: viewModel.postedRallies.contains(index)
            )
        }
        guard items.count > 1 else { return nil }
        return RallyPickerTarget(items: items, purpose: purpose)
    }
}

// MARK: - Top Card Drag Modifier

/// Applies drag/transition transforms for vertical scroll navigation.
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
    var actionSwipeOffsetY: CGFloat = 0  // Vertical swipe for favorite action

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
            return dragOffset.height + actionSwipeOffsetY
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
/// Adjacent players stay mounted, thumbnail visible until video playing
struct UnifiedRallyCard: View {
    let url: URL
    let rallyIndex: Int
    let size: CGSize
    let position: Int  // -1 = previous, 0 = current, 1+ = next
    let previousRallyIndex: Int?  // Track which rally was just current (for seamless transitions)
    let playerCache: RallyPlayerCache
    let thumbnailCache: RallyThumbnailCache
    var videoDisplaySize: CGSize?
    var rotationDegrees: Double = 0
    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var onDoubleTap: (() -> Void)?

    @State private var thumbnail: UIImage?
    // First video frame rendered — the thumbnail then unmounts. Keeping it
    // mounted behind a live video causes rotation artifacts: the SwiftUI image
    // animates with the rotation while the AVPlayerLayer resizes on UIKit's
    // schedule, so the mismatched thumbnail peeks out around the video.
    @State private var isVideoReady = false
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

    /// Clamp the pan offset to the current zoom so the video can never be pushed
    /// off-screen (which would expose the black background — the "zoom-out went
    /// black" bug). At zoom 1.0 the max is 0, forcing a centered frame.
    private var safeZoomOffset: CGSize {
        let maxX = max(0, (size.width * zoomScale - size.width) / 2)
        let maxY = max(0, (size.height * zoomScale - size.height) / 2)
        return CGSize(
            width: min(max(zoomOffset.width, -maxX), maxX),
            height: min(max(zoomOffset.height, -maxY), maxY)
        )
    }

    /// The rectangle the video content occupies. In portrait a non-square video
    /// is letterboxed, so rotation must happen inside this fitted rect (filled,
    /// not the whole screen-shaped card) to crop & scale like Apple's editor
    /// instead of tilting the letterbox bars. In landscape the video already
    /// fills the card, so the rect is the full card.
    private var videoRect: CGSize {
        if isPortrait {
            // Prefer the source video's true display size (reliable, available
            // immediately); fall back to the thumbnail's size, then the card.
            let content = videoDisplaySize ?? thumbnail?.size ?? size
            return RotationGeometry.aspectFitSize(content: content, in: size)
        }
        return size
    }

    var body: some View {
        let rect = videoRect
        return ZStack {
            Color.bscMediaBackground

            // Content layer (thumbnail + video) — rotated within the video rect.
            ZStack {
                // Thumbnail fallback behind the video layer.
                if let thumbnail = thumbnail, showThumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }

                // Video player layer - always at full opacity for preloaded cards.
                // AVPlayerLayer has clear background, so it's transparent when no content
                // and shows the video frame when content is rendered. No opacity toggling
                // eliminates any flash from layer compositing delays.
                if isPreloaded, let player = playerCache.getPlayer(for: url) {
                    CustomVideoPlayerView(
                        player: player,
                        gravity: .resizeAspectFill,
                        onReadyForDisplay: { ready in
                            guard ready != isVideoReady else { return }
                            // Async: updateUIView reports synchronously during view updates
                            DispatchQueue.main.async { isVideoReady = ready }
                        }
                    )
                    .allowsHitTesting(isCurrent)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(rotationDegrees))
            .scaleEffect(RotationGeometry.coverScale(angleDegrees: rotationDegrees, size: rect))
            .frame(width: rect.width, height: rect.height)
            .clipped()
        }
        .scaleEffect(zoomScale)
        .offset(safeZoomOffset)
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
        .accessibilityAction(named: "Play or pause") {
            if isCurrent {
                playerCache.togglePlayPause()
            }
        }
        .accessibilityAction(named: "Toggle zoom") {
            if isCurrent {
                onDoubleTap?()
            }
        }
        .task(id: url) {
            isVideoReady = false
            thumbnail = await thumbnailCache.getThumbnailAsync(for: url)
        }
    }

    private var showThumbnail: Bool {
        // Only until the player has rendered its first frame — after that the
        // video fully covers the card and the thumbnail must not linger behind it.
        guard !isVideoReady else { return false }
        if isCurrent { return true }
        return isPreviousRally || position == 1
    }
}

// MARK: - Shareable Rally Index

/// Identifiable wrapper so `.sheet(item:)` works with an Int index.
struct ShareableRallyIndex: Identifiable {
    let id = UUID()
    let index: Int
    var postAllSaved: Bool = false
    /// Rallies chosen in the picker, in post order. Nil posts every saved
    /// rally (the single-rally path, where there's nothing to choose).
    var selectedIndices: [Int]? = nil
}

/// What a run of the saved-rally picker is choosing clips for.
enum RallyPickerPurpose {
    case post
    case export

    /// A post holds a limited number of clips; an export can take every rally.
    func maxSelection(itemCount: Int) -> Int {
        switch self {
        case .post: return ShareRallyViewModel.maxClipsPerPost
        case .export: return itemCount
        }
    }

    /// Confirm-button label — the flows finish with different verbs.
    func confirmTitle(_ count: Int) -> String {
        let noun = count == 1 ? "Rally" : "Rallies"
        switch self {
        case .post: return "Post \(count) \(noun)"
        case .export: return "Export \(count) \(noun)"
        }
    }
}

/// Pending "choose which saved rallies" step.
struct RallyPickerTarget: Identifiable {
    let id = UUID()
    let items: [ClipPickerItem<Int>]
    let purpose: RallyPickerPurpose
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
        ),
        mediaStore: MediaStore()
    )
}
