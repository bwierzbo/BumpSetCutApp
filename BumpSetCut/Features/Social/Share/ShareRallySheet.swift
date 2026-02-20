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
    @FocusState private var isCaptionFocused: Bool

    private let preloadRadius = 4

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

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.lg) {
                        // Rally video carousel
                        rallyCarousel

                        // Caption with hashtags
                        captionField

                        // Post options
                        postOptions

                        // Poll editor
                        pollEditor

                        // Rally info for selected rally
                        rallyInfo

                        // Upload state
                        uploadStateView
                    }
                    .padding(BSCSpacing.lg)
                }
            }
            .navigationTitle("Share Rally")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    postButton
                }
            }
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

    // MARK: - Rally Carousel

    private var rallyCarousel: some View {
        VStack(spacing: BSCSpacing.sm) {
            TabView(selection: $carouselSelection) {
                ForEach(viewModel.savedRallyIndices.indices, id: \.self) { pageIndex in
                    let rallyIndex = viewModel.savedRallyIndices[pageIndex]
                    let url = viewModel.rallyVideoURLs[rallyIndex]
                    let isCurrent = pageIndex == viewModel.selectedPage

                    ZStack(alignment: .bottomLeading) {
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

                        // Rally badge
                        rallyBadge(pageIndex: pageIndex)
                    }
                    .clipped()
                    .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))

            // Page dots
            if viewModel.savedRallyIndices.count > 1 {
                HStack(spacing: BSCSpacing.xs) {
                    ForEach(viewModel.savedRallyIndices.indices, id: \.self) { i in
                        Circle()
                            .fill(i == viewModel.selectedPage ? Color.bscPrimary : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.selectedPage)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rallyBadge(pageIndex: Int) -> some View {
        if viewModel.postAllSaved && viewModel.savedRallyIndices.count > 1 {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("\(viewModel.savedRallyIndices.count) Rallies")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, BSCSpacing.sm)
            .padding(.vertical, BSCSpacing.xxs)
            .background(Capsule().fill(Color.bscPrimary.opacity(0.85)))
            .padding(BSCSpacing.sm)
        } else {
            let rallyIndex = viewModel.savedRallyIndices[pageIndex]
            Text("Rally \(rallyIndex + 1)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, BSCSpacing.sm)
                .padding(.vertical, BSCSpacing.xxs)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .padding(BSCSpacing.sm)
        }
    }

    // MARK: - Player Pool Management

    private func updatePlayerPool(activePage: Int) {
        let pageCount = viewModel.savedRallyIndices.count
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
            let rallyIndex = viewModel.savedRallyIndices[pageIndex]
            guard let info = viewModel.rallyInfo[rallyIndex] else { continue }

            if playerPool[pageIndex] == nil {
                let player = AVPlayer(url: viewModel.originalVideoURL)
                player.automaticallyWaitsToMinimizeStalling = false
                let startTime = CMTimeMakeWithSeconds(info.startTime, preferredTimescale: 600)
                let endTime = CMTimeMakeWithSeconds(info.endTime, preferredTimescale: 600)

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
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.bscTextSecondary)

            TextField("Describe this rally... use #hashtags", text: $viewModel.caption, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.bscPrimary)
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

    // MARK: - Post Options

    private var postOptions: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $viewModel.hideLikes) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 15))
                        .foregroundColor(.bscTextSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Hide like count")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.bscTextPrimary)
                        Text("Others won't see how many likes this post has")
                            .font(.system(size: 12))
                            .foregroundColor(.bscTextTertiary)
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
                        .font(.system(size: 15))
                        .foregroundColor(.bscTextSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add a poll")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.bscTextPrimary)
                        Text("Let viewers vote on your rally")
                            .font(.system(size: 12))
                            .foregroundColor(.bscTextTertiary)
                    }
                }
            }
            .tint(.bscPrimary)
            .padding(BSCSpacing.sm)

            if viewModel.includePoll {
                Divider().opacity(0.3)

                VStack(spacing: BSCSpacing.sm) {
                    TextField("Ask a question...", text: $viewModel.pollQuestion)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.bscTextPrimary)
                        .padding(BSCSpacing.sm)
                        .background(Color.bscSurfaceGlass.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

                    ForEach(viewModel.pollOptions.indices, id: \.self) { index in
                        HStack(spacing: BSCSpacing.xs) {
                            Circle()
                                .stroke(Color.bscTextTertiary, lineWidth: 1.5)
                                .frame(width: 16, height: 16)

                            TextField("Option \(index + 1)", text: $viewModel.pollOptions[index])
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .foregroundColor(.bscTextPrimary)

                            if viewModel.pollOptions.count > 2 {
                                Button {
                                    viewModel.removePollOption(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.bscTextTertiary)
                                }
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
                                    .font(.system(size: 14))
                                Text("Add option")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.bscPrimary)
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
            if viewModel.postAllSaved && viewModel.savedRallyIndices.count > 1 {
                HStack(spacing: BSCSpacing.lg) {
                    Label("\(viewModel.postCount) rallies", systemImage: "square.stack")
                    Label("\(String(format: "%.1f", viewModel.totalDuration))s total", systemImage: "timer")
                }
                .font(.system(size: 12))
                .foregroundColor(.bscTextTertiary)
            } else {
                let meta = viewModel.currentMetadata
                HStack(spacing: BSCSpacing.lg) {
                    Label("\(String(format: "%.1f", meta.duration))s", systemImage: "timer")
                    Label("\(meta.detectionCount) detections", systemImage: "eye")
                }
                .font(.system(size: 12))
                .foregroundColor(.bscTextTertiary)

                if viewModel.isTooLong {
                    Label("Rally must be under 1 minute to share", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.bscError)
                }
            }
        }
    }

    // MARK: - Upload State

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
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

        case .processing:
            HStack(spacing: BSCSpacing.sm) {
                ProgressView()
                    .tint(.bscPrimary)
                Text("Processing...")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

        case .complete:
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.bscSuccess)
                Text("Shared successfully!")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscTextPrimary)
                Text("Opening in feed...")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

        case .failed(let message):
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.bscError)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.retry() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscPrimary)
            }
        }
    }

    // MARK: - Post Button

    private var postButton: some View {
        let canPost = viewModel.state == .idle && (!viewModel.isTooLong || viewModel.postAllSaved) && viewModel.isPollValid
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
        .foregroundColor(canPost ? .bscPrimary : .bscTextTertiary)
    }
}
