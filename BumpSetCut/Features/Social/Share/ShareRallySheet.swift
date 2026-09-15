//
//  ShareRallySheet.swift
//  BumpSetCut
//
//  Sheet for sharing a local rally as a highlight to the social feed.
//

import SwiftUI
import AVFoundation

struct ShareRallySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigationState.self) private var navigationState
    @Environment(AuthenticationService.self) private var authService
    @State private var viewModel: ShareRallyViewModel
    @State private var playerPool: [Int: AVPlayer] = [:]
    @State private var loopObservers: [Int: Any] = [:]
    @State private var carouselSelection: Int = 0
    @State private var showAuthGate = false
    @State private var showLocationPicker = false
    @FocusState private var isCaptionFocused: Bool

    // Crop mode: pinch/drag reframes the CURRENT page; saved per page and
    // burned in at upload.
    @State private var isCropMode = false
    @State private var liveCropZoom: CGFloat = 1
    @State private var lastCropZoom: CGFloat = 1
    @State private var liveCropOffset: CGSize = .zero
    @State private var lastCropOffset: CGSize = .zero
    @State private var previewSize: CGSize = .zero

    private let preloadRadius = 4
    private let maxCropZoom: CGFloat = 3

    init(originalVideoURL: URL, rallyVideoURLs: [URL], savedRallyIndices: [Int],
         initialRallyIndex: Int, thumbnailCache: RallyThumbnailCache,
         videoId: UUID, rallyInfo: [Int: RallyShareInfo], postAllSaved: Bool = false) {
        let initialPage = savedRallyIndices.firstIndex(of: initialRallyIndex) ?? 0
        _carouselSelection = State(initialValue: initialPage)
        _viewModel = State(initialValue: ShareRallyViewModel(
            originalVideoURL: originalVideoURL,
            rallyVideoURLs: rallyVideoURLs,
            savedRallyIndices: savedRallyIndices,
            initialPage: initialPage,
            thumbnailCache: thumbnailCache,
            videoId: videoId,
            rallyInfo: rallyInfo,
            postAllSaved: postAllSaved
        ))
    }

    /// Post favorites clips (separate files) as ONE swipeable multi-rally post.
    init(favoriteClips: [FavoriteShareClip], title: String) {
        _viewModel = State(initialValue: ShareRallyViewModel(
            favoriteClips: favoriteClips,
            title: title
        ))
    }

    private var isFavoriteClips: Bool {
        if case .favoriteClips = viewModel.source { return true }
        return false
    }

    /// Pages in the preview carousel, source-agnostic.
    private var pageCount: Int {
        isFavoriteClips ? viewModel.favoriteClips.count : viewModel.savedRallyIndices.count
    }

    /// Per-page playback: which file, and the loop window inside it.
    private func playbackConfig(forPage page: Int) -> (url: URL, start: Double, end: Double)? {
        if isFavoriteClips {
            guard page < viewModel.favoriteClips.count else { return nil }
            let clip = viewModel.favoriteClips[page]
            let start = clip.timeRange.map { CMTimeGetSeconds($0.start) } ?? 0
            let end = clip.timeRange.map { CMTimeGetSeconds($0.end) } ?? clip.duration
            return (clip.url, start, max(end, start + 0.1))
        }
        guard page < viewModel.savedRallyIndices.count else { return nil }
        let rallyIndex = viewModel.savedRallyIndices[page]
        guard let info = viewModel.rallyInfo[rallyIndex] else { return nil }
        return (viewModel.originalVideoURL, info.startTime, info.endTime)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.lg) {
                        // Rally video carousel (source video rallies, or
                        // favorites clips as one swipeable post)
                        if isFavoriteClips {
                            favoriteClipsCarousel
                        } else {
                            rallyCarousel
                        }

                        // Caption with hashtags
                        captionField

                        // Location tag
                        locationField

                        // Post options
                        postOptions

                        // Poll editor
                        pollEditor

                        // Rally info for selected rally
                        rallyInfo
                    }
                    .padding(BSCSpacing.lg)
                }

                // Blocking upload overlay (modal — user waits until done)
                if viewModel.state != .idle {
                    uploadOverlay
                }
            }
            .navigationTitle(isFavoriteClips ? "Share Rallies" : "Share Rally")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                    .disabled(isUploadBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    postButton
                }
            }
            .interactiveDismissDisabled(isUploadBusy)
        }
        .onAppear {
            carouselSelection = viewModel.selectedPage
            updatePlayerPool(activePage: viewModel.selectedPage)
        }
        .onDisappear { cleanupAllPlayers() }
        .onChange(of: carouselSelection) { _, newPage in
            viewModel.selectedPage = newPage
            updatePlayerPool(activePage: newPage)
        }
        .onChange(of: isCaptionFocused) { _, focused in
            if focused {
                playerPool[viewModel.selectedPage]?.pause()
            } else {
                playerPool[viewModel.selectedPage]?.play()
            }
        }
        .onChange(of: viewModel.state) { _, newState in
            if case .complete(let highlight) = newState {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    navigationState.postedHighlight = highlight
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showAuthGate) {
            AuthGateView()
        }
        .onChange(of: authService.authState) { _, newState in
            if newState == .authenticated {
                showAuthGate = false
                // Auto-upload after signing in
                viewModel.upload()
            }
        }
    }

    // MARK: - Favorite Clips Carousel (multi-rally post preview)

    private var favoriteClipsCarousel: some View {
        VStack(spacing: BSCSpacing.sm) {
            TabView(selection: $carouselSelection) {
                ForEach(Array(viewModel.favoriteClips.enumerated()), id: \.element.id) { pageIndex, clip in
                    let isCurrent = pageIndex == viewModel.selectedPage

                    ZStack(alignment: .bottomLeading) {
                        // Video content gets the crop transform; the badge stays put.
                        ZStack {
                            // File-based thumbnail while the player warms up
                            VideoThumbnailView(thumbnailURL: nil, videoURL: clip.url)

                            if let pagePlayer = playerPool[pageIndex] {
                                CustomVideoPlayerView(
                                    player: pagePlayer,
                                    gravity: .resizeAspectFill,
                                    onReadyForDisplay: { _ in }
                                )
                                .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(displayCropZoom(for: pageIndex))
                        .offset(displayCropOffset(for: pageIndex))

                        Text(clip.displayName)
                            .bscFont(size: 13, weight: .bold)
                            .foregroundColor(.bscOnMedia)
                            .lineLimit(1)
                            .padding(.horizontal, BSCSpacing.sm)
                            .padding(.vertical, BSCSpacing.xxs)
                            .background(Capsule().fill(Color.bscMediaScrimBase.opacity(0.7)))
                            .padding(BSCSpacing.sm)
                    }
                    .clipped()
                    .opacity(isCurrent ? 1.0 : 0.85)
                    .animation(.bscQuick, value: isCurrent)
                    .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .background(cropSizeReader)
            .highPriorityGesture(cropDragGesture, including: isCropMode ? .gesture : .subviews)
            .simultaneousGesture(cropPinchGesture, including: isCropMode ? .all : .subviews)

            cropControls

            // Page dots
            if viewModel.favoriteClips.count > 1 {
                HStack(spacing: BSCSpacing.xs) {
                    ForEach(viewModel.favoriteClips.indices, id: \.self) { i in
                        Circle()
                            .fill(i == viewModel.selectedPage ? Color.bscPrimary : Color.bscTextSecondary.opacity(0.6))
                            .frame(width: 8, height: 8)
                            .animation(.bscQuick, value: viewModel.selectedPage)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rally \(viewModel.selectedPage + 1) of \(viewModel.favoriteClips.count)")
            }
        }
    }

    // MARK: - Rally Carousel

    private var rallyCarousel: some View {
        VStack(spacing: BSCSpacing.sm) {
            TabView(selection: $carouselSelection) {
                ForEach(viewModel.savedRallyIndices.indices, id: \.self) { pageIndex in
                    let rallyIndex = viewModel.savedRallyIndices[pageIndex]
                    let url = viewModel.rallyVideoURLs[rallyIndex]
                    let isCurrent = pageIndex == viewModel.selectedPage

                    ZStack(alignment: .bottomLeading) {
                        // Video content gets the crop transform; the badge stays put.
                        ZStack {
                            // Thumbnail (always visible — instant, no loading)
                            if let thumb = viewModel.thumbnailCache.getThumbnail(for: url) {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.bscSurfaceGlass
                            }

                            // Preloaded video player (current ±4 pages have players)
                            if let pagePlayer = playerPool[pageIndex] {
                                CustomVideoPlayerView(
                                    player: pagePlayer,
                                    gravity: .resizeAspectFill,
                                    onReadyForDisplay: { _ in }
                                )
                                .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(displayCropZoom(for: pageIndex))
                        .offset(displayCropOffset(for: pageIndex))

                        // Rally badge
                        rallyBadge(pageIndex: pageIndex)
                    }
                    .clipped()
                    .opacity(isCurrent ? 1.0 : 0.85)
                    .animation(.bscQuick, value: isCurrent)
                    .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .background(cropSizeReader)
            .highPriorityGesture(cropDragGesture, including: isCropMode ? .gesture : .subviews)
            .simultaneousGesture(cropPinchGesture, including: isCropMode ? .all : .subviews)

            cropControls

            // Page dots
            if viewModel.savedRallyIndices.count > 1 {
                HStack(spacing: BSCSpacing.xs) {
                    ForEach(viewModel.savedRallyIndices.indices, id: \.self) { i in
                        Circle()
                            .fill(i == viewModel.selectedPage ? Color.bscPrimary : Color.bscTextSecondary.opacity(0.6))
                            .frame(width: 8, height: 8)
                            .animation(.bscQuick, value: viewModel.selectedPage)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rally \(viewModel.selectedPage + 1) of \(viewModel.savedRallyIndices.count)")
            }
        }
    }

    // MARK: - Crop

    /// Captures the carousel's on-screen size so crop offsets can be
    /// normalized (and denormalized) against it.
    private var cropSizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { previewSize = geo.size }
                .onChange(of: geo.size) { _, size in previewSize = size }
        }
    }

    private func displayCropZoom(for page: Int) -> CGFloat {
        if isCropMode && page == viewModel.selectedPage { return liveCropZoom }
        return viewModel.crops[page]?.zoom ?? 1
    }

    private func displayCropOffset(for page: Int) -> CGSize {
        if isCropMode && page == viewModel.selectedPage { return liveCropOffset }
        guard let crop = viewModel.crops[page], previewSize != .zero else { return .zero }
        return CGSize(width: crop.offsetXNorm * previewSize.width,
                      height: crop.offsetYNorm * previewSize.height)
    }

    private var cropPinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isCropMode else { return }
                liveCropZoom = min(max(lastCropZoom * value.magnification, 1), maxCropZoom)
            }
            .onEnded { _ in
                guard isCropMode else { return }
                lastCropZoom = liveCropZoom
                clampCropOffset()
            }
    }

    private var cropDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isCropMode else { return }
                liveCropOffset = CGSize(
                    width: lastCropOffset.width + value.translation.width,
                    height: lastCropOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard isCropMode else { return }
                clampCropOffset()
            }
    }

    /// Keep the pan inside what the zoom exposes, so the crop can't drift
    /// into empty space.
    private func clampCropOffset() {
        let maxX = (liveCropZoom - 1) / 2 * previewSize.width
        let maxY = (liveCropZoom - 1) / 2 * previewSize.height
        withAnimation(.bscQuick) {
            liveCropOffset.width = min(max(liveCropOffset.width, -maxX), maxX)
            liveCropOffset.height = min(max(liveCropOffset.height, -maxY), maxY)
        }
        lastCropOffset = liveCropOffset
    }

    private var currentPageHasCrop: Bool {
        viewModel.crops[viewModel.selectedPage].map { !$0.isIdentity } ?? false
    }

    /// Crop toggle / editing controls under the carousel.
    private var cropControls: some View {
        HStack(spacing: BSCSpacing.lg) {
            if isCropMode {
                Button {
                    withAnimation(.bscQuick) {
                        liveCropZoom = 1
                        liveCropOffset = .zero
                    }
                    lastCropZoom = 1
                    lastCropOffset = .zero
                } label: {
                    Text("Reset")
                        .bscFont(size: 14, weight: .medium)
                        .foregroundColor(.bscTextSecondary)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }

                Spacer()

                Text("Pinch & drag to reframe")
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextTertiary)

                Spacer()

                Button {
                    saveCrop()
                } label: {
                    Text("Done")
                        .bscFont(size: 14, weight: .bold)
                        .foregroundColor(.bscPrimaryText)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier(AccessibilityID.Share.cropDone)
            } else {
                Button {
                    enterCropMode()
                } label: {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: "crop")
                            .bscFont(size: 13, weight: .semibold)
                        Text(currentPageHasCrop ? "Cropped" : "Crop")
                            .bscFont(size: 13, weight: .semibold)
                    }
                    .foregroundColor(currentPageHasCrop ? .bscPrimaryText : .bscTextSecondary)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
                }
                .disabled(isUploadBusy)
                .accessibilityIdentifier(AccessibilityID.Share.cropButton)

                Spacer()

                if pageCount > 1 {
                    Text("Crops apply per rally")
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextTertiary)
                }
            }
        }
        .animation(.bscQuick, value: isCropMode)
    }

    private func enterCropMode() {
        let existing = viewModel.crops[viewModel.selectedPage]
        liveCropZoom = existing?.zoom ?? 1
        liveCropOffset = CGSize(
            width: (existing?.offsetXNorm ?? 0) * previewSize.width,
            height: (existing?.offsetYNorm ?? 0) * previewSize.height
        )
        lastCropZoom = liveCropZoom
        lastCropOffset = liveCropOffset
        isCropMode = true
    }

    private func saveCrop() {
        if previewSize != .zero {
            let crop = ShareCrop(
                zoom: liveCropZoom,
                offsetXNorm: liveCropOffset.width / previewSize.width,
                offsetYNorm: liveCropOffset.height / previewSize.height
            )
            if crop.isIdentity {
                viewModel.crops.removeValue(forKey: viewModel.selectedPage)
            } else {
                viewModel.crops[viewModel.selectedPage] = crop
            }
        }
        isCropMode = false
    }

    @ViewBuilder
    private func rallyBadge(pageIndex: Int) -> some View {
        if viewModel.postAllSaved && viewModel.savedRallyIndices.count > 1 {
            HStack(spacing: BSCSpacing.xs) {
                Image(systemName: "square.stack.fill")
                    .bscFont(size: 11, weight: .bold)
                Text("\(viewModel.savedRallyIndices.count) Rallies")
                    .bscFont(size: 13, weight: .bold)
            }
            .foregroundColor(.bscOnMedia)
            .padding(.horizontal, BSCSpacing.sm)
            .padding(.vertical, BSCSpacing.xxs)
            .background(Capsule().fill(Color.bscMediaScrimBase.opacity(0.7)))
            .padding(BSCSpacing.sm)
        } else {
            let rallyIndex = viewModel.savedRallyIndices[pageIndex]
            Text("Rally \(rallyIndex + 1)")
                .bscFont(size: 13, weight: .bold)
                .foregroundColor(.bscOnMedia)
                .padding(.horizontal, BSCSpacing.sm)
                .padding(.vertical, BSCSpacing.xxs)
                .background(Capsule().fill(Color.bscMediaScrimBase.opacity(0.7)))
                .padding(BSCSpacing.sm)
        }
    }

    // MARK: - Player Pool Management

    private func updatePlayerPool(activePage: Int) {
        guard pageCount > 0 else { return }
        let lo = max(0, activePage - preloadRadius)
        let hi = min(pageCount - 1, activePage + preloadRadius)
        let visibleRange = lo...hi

        // Remove players outside the window
        for pageIndex in playerPool.keys where !visibleRange.contains(pageIndex) {
            if let observer = loopObservers.removeValue(forKey: pageIndex) {
                playerPool[pageIndex]?.removeTimeObserver(observer)
            }
            playerPool[pageIndex]?.pause()
            playerPool[pageIndex]?.replaceCurrentItem(with: nil)
            playerPool.removeValue(forKey: pageIndex)
        }

        // Create players for pages in the window that don't have one
        for pageIndex in visibleRange {
            guard let config = playbackConfig(forPage: pageIndex) else { continue }

            if playerPool[pageIndex] == nil {
                let player = AVPlayer(url: config.url)
                player.automaticallyWaitsToMinimizeStalling = false
                let startTime = CMTimeMakeWithSeconds(config.start, preferredTimescale: 600)
                let endTime = CMTimeMakeWithSeconds(config.end, preferredTimescale: 600)

                player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)

                // Set up looping
                let observer = player.addBoundaryTimeObserver(
                    forTimes: [NSValue(time: endTime)],
                    queue: .main
                ) { [weak player] in
                    player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                loopObservers[pageIndex] = observer

                // Only play the active page
                if pageIndex == activePage {
                    player.play()
                } else {
                    player.pause()
                }

                playerPool[pageIndex] = player
            } else {
                // Player exists — play/pause based on active page
                if pageIndex == activePage {
                    playerPool[pageIndex]?.play()
                } else {
                    playerPool[pageIndex]?.pause()
                }
            }
        }
    }

    private func cleanupAllPlayers() {
        for (pageIndex, player) in playerPool {
            if let observer = loopObservers[pageIndex] {
                player.removeTimeObserver(observer)
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        playerPool.removeAll()
        loopObservers.removeAll()
    }

    // MARK: - Caption

    private var captionField: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            Text("Caption")
                .bscFont(size: 14, weight: .medium)
                .foregroundColor(.bscTextSecondary)

            TextField("Describe this rally... use #hashtags", text: $viewModel.caption, axis: .vertical)
                .textFieldStyle(.plain)
                .bscFont(size: 16)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(3...6)
                .padding(BSCSpacing.sm)
                .background(Color.bscSurfaceGlass)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                .focused($isCaptionFocused)

            if !viewModel.extractedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BSCSpacing.xs) {
                        ForEach(viewModel.extractedTags, id: \.self) { tag in
                            Text("#\(tag)")
                                .bscFont(size: 12, weight: .medium)
                                .foregroundColor(.bscPrimaryText)
                                .padding(.horizontal, BSCSpacing.sm)
                                .padding(.vertical, BSCSpacing.xxs)
                                .background(Color.bscPrimary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Location

    private var locationField: some View {
        HStack(spacing: BSCSpacing.sm) {
            Button {
                isCaptionFocused = false
                showLocationPicker = true
            } label: {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "mappin.circle.fill")
                        .bscFont(size: 18)
                        .foregroundColor(viewModel.pickedLocation == nil ? .bscTextSecondary : .bscPrimary)

                    if let location = viewModel.pickedLocation {
                        Text(location.name)
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscTextPrimary)
                            .lineLimit(1)
                    } else {
                        Text("Add location")
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscTextSecondary)
                    }

                    Spacer()

                    if viewModel.pickedLocation == nil {
                        Image(systemName: "chevron.right")
                            .bscFont(size: 12, weight: .semibold)
                            .foregroundColor(.bscTextSecondary)
                    }
                }
                .frame(minHeight: BSCTouchTarget.standard)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if viewModel.pickedLocation != nil {
                Button {
                    viewModel.pickedLocation = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .bscFont(size: 16)
                        .foregroundColor(.bscTextSecondary)
                        .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove location")
            }
        }
        .padding(.horizontal, BSCSpacing.sm)
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerView { picked in
                viewModel.pickedLocation = picked
            }
        }
    }

    // MARK: - Post Options

    private var postOptions: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $viewModel.hideLikes) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "heart.slash")
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                    VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                        Text("Hide like count")
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscTextPrimary)
                        Text("Others won't see how many likes this post has")
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)
                    }
                }
            }
            .tint(.bscPrimary)
            .padding(BSCSpacing.sm)
        }
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
    }

    // MARK: - Poll Editor

    private var pollEditor: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $viewModel.includePoll) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "chart.bar.xaxis")
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                    VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                        Text("Add a poll")
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscTextPrimary)
                        Text("Let viewers vote on your rally")
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)
                    }
                }
            }
            .tint(.bscPrimary)
            .padding(BSCSpacing.sm)

            if viewModel.includePoll {
                Divider().overlay(Color.bscSurfaceBorder)

                VStack(spacing: BSCSpacing.sm) {
                    TextField("Ask a question...", text: $viewModel.pollQuestion)
                        .textFieldStyle(.plain)
                        .bscFont(size: 15, weight: .medium)
                        .foregroundColor(.bscTextPrimary)
                        .padding(BSCSpacing.sm)
                        .background(Color.bscSurfaceGlass.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

                    ForEach(viewModel.pollOptions.indices, id: \.self) { index in
                        HStack(spacing: BSCSpacing.xs) {
                            Circle()
                                .stroke(Color.bscTextSecondary, lineWidth: 1.5)
                                .frame(width: 16, height: 16)

                            TextField("Option \(index + 1)", text: $viewModel.pollOptions[index])
                                .textFieldStyle(.plain)
                                .bscFont(size: 14)
                                .foregroundColor(.bscTextPrimary)

                            if viewModel.pollOptions.count > 2 {
                                Button {
                                    viewModel.removePollOption(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .bscFont(size: 16)
                                        .foregroundColor(.bscTextSecondary)
                                        .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Remove option \(index + 1)")
                            }
                        }
                        .padding(.horizontal, BSCSpacing.sm)
                        .padding(.vertical, BSCSpacing.xs)
                        .background(Color.bscSurfaceGlass.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
                    }

                    if viewModel.pollOptions.count < 5 {
                        Button {
                            viewModel.addPollOption()
                        } label: {
                            HStack(spacing: BSCSpacing.xs) {
                                Image(systemName: "plus.circle.fill")
                                    .bscFont(size: 14)
                                Text("Add option")
                                    .bscFont(size: 13, weight: .medium)
                            }
                            .foregroundColor(.bscPrimaryText)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                        }
                    }
                }
                .padding(BSCSpacing.sm)
            }
        }
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
    }

    // MARK: - Rally Info

    private var rallyInfo: some View {
        VStack(spacing: BSCSpacing.xs) {
            if isFavoriteClips {
                HStack(spacing: BSCSpacing.lg) {
                    Label("\(viewModel.postCount) \(viewModel.postCount == 1 ? "rally" : "rallies")", systemImage: "square.stack")
                    Label("\(String(format: "%.1f", viewModel.totalDuration))s total", systemImage: "timer")
                }
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
            } else if viewModel.postAllSaved && viewModel.savedRallyIndices.count > 1 {
                HStack(spacing: BSCSpacing.lg) {
                    Label("\(viewModel.postCount) rallies", systemImage: "square.stack")
                    Label("\(String(format: "%.1f", viewModel.totalDuration))s total", systemImage: "timer")
                }
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
            } else {
                let meta = viewModel.currentMetadata
                HStack(spacing: BSCSpacing.lg) {
                    Label("\(String(format: "%.1f", meta.duration))s", systemImage: "timer")
                    Label("\(meta.detectionCount) detections", systemImage: "eye")
                }
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)

                if viewModel.isTooLong {
                    Label("Rally must be under 1 minute to share", systemImage: "exclamationmark.triangle.fill")
                        .bscFont(size: 12, weight: .medium)
                        .foregroundColor(.bscErrorText)
                }
            }
        }
    }

    // MARK: - Upload State

    /// True while an upload is in flight (and during the brief success state) —
    /// used to block Cancel / swipe-to-dismiss so the user waits it out.
    private var isUploadBusy: Bool {
        switch viewModel.state {
        case .uploading, .processing, .complete: return true
        case .idle, .failed: return false
        }
    }

    /// Full-screen blocking modal shown during posting. Reuses `uploadStateView`
    /// for the per-state content inside a centered card.
    private var uploadOverlay: some View {
        ZStack {
            Color.bscMediaScrim
                .ignoresSafeArea()
                .onTapGesture {
                    // Only a failed upload can be dismissed (back to editing) by tapping out.
                    if case .failed = viewModel.state { viewModel.cancel() }
                }

            VStack(spacing: BSCSpacing.md) {
                uploadStateView
            }
            .frame(maxWidth: BSCContentWidth.compact)
            .padding(BSCSpacing.xl)
            .bscSurfaceChrome(cornerRadius: BSCRadius.xl, shadow: BSCShadow.xl)
            .padding(BSCSpacing.xl)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var uploadStateView: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .uploading(let progress):
            VStack(spacing: BSCSpacing.sm) {
                ProgressView(value: progress)
                    .tint(.bscPrimary)
                Text(viewModel.postAllSaved && viewModel.postCount > 1
                     ? "Uploading \(viewModel.postCount) rallies... \(Int(progress * 100))%"
                     : "Uploading... \(Int(progress * 100))%")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }

        case .processing:
            HStack(spacing: BSCSpacing.sm) {
                ProgressView()
                    .tint(.bscPrimary)
                Text("Processing...")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }

        case .complete:
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .bscFont(size: 36)
                    .foregroundColor(.bscSuccessText)
                Text("Shared successfully!")
                    .bscFont(size: 15, weight: .medium)
                    .foregroundColor(.bscTextPrimary)
                Text("Opening in feed...")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }

        case .failed(let message):
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .bscFont(size: 36)
                    .foregroundColor(.bscError)
                Text(message)
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.retry() }
                    .bscFont(size: 15, weight: .medium)
                    .foregroundColor(.bscPrimaryText)
            }
        }
    }

    // MARK: - Post Button

    private var postButton: some View {
        let canPost = viewModel.state == .idle && (!viewModel.isTooLong || viewModel.postAllSaved)
            && viewModel.isPollValid && !isCropMode
        return Button("Post") {
            isCaptionFocused = false
            if authService.isAuthenticated {
                viewModel.upload()
            } else {
                showAuthGate = true
            }
        }
        .disabled(!canPost)
        .fontWeight(.semibold)
        .foregroundColor(canPost ? .bscPrimaryText : .bscTextTertiary)
    }
}
