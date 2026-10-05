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

    // Internal (not private) for the gesture builders in RallyPlayerView+Gestures.
    @State var viewModel: RallyPlayerViewModel
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
    @State private var showPostAnotherPrompt = false
    /// Rotation captured at the start of a two-finger twist (RotationGesture
    /// reports angle relative to its own start).
    @State var twistBaseRotation: Double?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppNavigationState.self) private var navigationState
    @Environment(AppSettings.self) private var appSettings

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
                    title: String(localized: "Saved rallies", comment: "Name of the rally set in the post picker's limit message"),
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
                    confirmTitle: { "Save to \($0)" },
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
                viewModel.shareErrorMessage.map { Text(verbatim: $0) } ?? Text("Couldn't prepare the clip for sharing.")
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
                get: { viewModel.favoritesErrorMessage.map { BSCToastMessage(verbatim: $0, style: .error) } },
                set: { if $0 == nil { viewModel.favoritesErrorMessage = nil } }
            ))
        }
        // Full-screen video: hide the status bar and home indicator, and make
        // edge swipes need a second swipe so they don't fight the card gestures.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .vertical)
        .task(id: videoMetadata.id) {
            await viewModel.loadRallies()
        }
        .task {
            await showIntroHints()
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
            ZStack {
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
                        onDoubleTap: position == 0 ? { toggleZoom(cardSize: geometry.size) } : nil,
                        onTrim: position == 0 && !interactionBlocked ? { beginTrim() } : nil
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
            }
            // Trim-mode direct manipulation: pinch zoom, twist angle, drag pan.
            // Attached to the cards only — on the outer stack it fired alongside
            // the trim bar's handle drags and moved the crop while trimming.
            .contentShape(Rectangle())
            .simultaneousGesture(viewModel.isTrimmingMode ? trimEditGesture(geometry: geometry) : nil)

            // Player chrome (above all cards), stacked top to bottom so each
            // piece is anchored to its neighbour instead of a hand-tuned offset.
            // Empty space passes touches through to the cards.
            VStack(spacing: BSCSpacing.sm) {
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
                    isPreparingShare: viewModel.isPreparingShare
                )

                // Report-a-mistake affordance (data flywheel, opted-in users
                // only), directly under the top bar — tester feedback: at the
                // bottom it sat nearly on top of the Save action button.
                if viewModel.isFlywheelEnabled && !interactionBlocked {
                    reportMistakeButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, BSCSpacing.lg)
                        .transition(.opacity)
                }

                Spacer(minLength: 0)

                // "Hold to trim" coach mark — shows every session until the user
                // actually enters trim mode once (tester feedback: the one-time
                // tips overlay wasn't enough to make trimming discoverable).
                if showTrimHint && !appSettings.hasUsedRallyTrim && !showingGestureTips && !interactionBlocked {
                    TrimCoachMark()
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Action feedback, just above the action row.
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
                }

                // Hidden while trimming or while the rotation-propagation
                // prompt is up.
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
                    .transition(.opacity)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .zIndex(200)

            // Trim overlay
            if viewModel.isTrimmingMode, let segment = currentRallySegment {
                RallyTrimOverlay(
                    trimBefore: $viewModel.currentTrimBefore,
                    trimAfter: $viewModel.currentTrimAfter,
                    trimRotation: $viewModel.currentTrimRotation,
                    trimZoom: liveTrimZoom(cardSize: geometry.size),
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
        // Free pinch for normal viewing (disabled in trim mode / prompt).
        .simultaneousGesture(interactionBlocked ? nil : pinchGesture())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in beginTrim() }
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

    /// First-run hints, timed from when the player appears. Runs in the view's
    /// `.task`, so leaving the player cancels any that haven't fired yet.
    private func showIntroHints() async {
        let start = ContinuousClock.now
        func wait(until offset: Duration) async -> Bool {
            (try? await Task.sleep(until: start + offset, clock: .continuous)) != nil
        }

        // Gesture tips on first launch.
        if !appSettings.hasSeenRallyTips {
            guard await wait(until: .seconds(0.5)) else { return }
            showingGestureTips = true
        }

        // Trim coach mark: appears after the video settles, hides after a
        // while, and stops appearing for good once the user has trimmed.
        guard !appSettings.hasUsedRallyTrim, await wait(until: .seconds(2)) else { return }
        withAnimation(.bscSpring) { showTrimHint = true }
        guard await wait(until: .seconds(10)) else { return }
        withAnimation(.bscQuick) { showTrimHint = false }
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

    private var reportMistakeButton: some View {
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
                .frame(minWidth: BSCTouchTarget.standard, minHeight: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(viewModel.currentVideoIsReported ? "Video reported" : "Report a detection mistake")
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

    // MARK: - Helpers

    /// Long-press (or the card's "Trim rally" accessibility action) enters trim mode.
    private func beginTrim() {
        guard !viewModel.isTransitioning, !viewModel.isPerformingAction,
              !viewModel.isTrimmingMode, !viewModel.isAwaitingPropagationChoice else { return }
        appSettings.hasUsedRallyTrim = true
        withAnimation(.bscQuick) { showTrimHint = false }
        viewModel.enterTrimMode()
    }

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
                displayName: String(localized: "Rally \(index + 1)", comment: "Name of a rally clip; the number is its position in the video"),
                duration: duration,
                isPosted: viewModel.postedRallies.contains(index)
            )
        }
        guard items.count > 1 else { return nil }
        return RallyPickerTarget(items: items, purpose: purpose)
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
        switch self {
        case .post: return String(localized: "Post \(count) Rallies", comment: "Picker confirm button; plural on the count")
        case .export: return String(localized: "Export \(count) Rallies", comment: "Picker confirm button; plural on the count")
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
