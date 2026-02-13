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
    @State private var player = AVPlayer()
    @State private var loopObserver: Any?
    @State private var carouselOffset: CGFloat = 0
    @State private var isSliding = false
    @State private var showAuthGate = false
    @FocusState private var isCaptionFocused: Bool

    init(originalVideoURL: URL, rallyVideoURLs: [URL], savedRallyIndices: [Int],
         initialRallyIndex: Int, thumbnailCache: RallyThumbnailCache,
         videoId: UUID, rallyInfo: [Int: RallyShareInfo], postAllSaved: Bool = false) {
        let initialPage = savedRallyIndices.firstIndex(of: initialRallyIndex) ?? 0
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
        .onAppear { configurePlayer() }
        .onDisappear { cleanupPlayer() }
        .onChange(of: viewModel.selectedPage) { _, _ in configurePlayer() }
        .onChange(of: isCaptionFocused) { _, focused in
            if focused {
                player.pause()
            } else {
                player.play()
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
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    // Thumbnail fallback behind video
                    Group {
                        if let url = currentThumbnailURL,
                           let thumb = viewModel.thumbnailCache.getThumbnail(for: url) {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.bscSurfaceGlass
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                    // Video player on top
                    CustomVideoPlayerView(
                        player: player,
                        gravity: .resizeAspectFill,
                        onReadyForDisplay: { _ in }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)

                    // Rally badge
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
                        .background(Capsule().fill(Color.bscOrange.opacity(0.85)))
                        .padding(BSCSpacing.sm)
                    } else {
                        Text("Rally \(viewModel.currentRallyIndex + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, BSCSpacing.sm)
                            .padding(.vertical, BSCSpacing.xxs)
                            .background(Capsule().fill(Color.black.opacity(0.7)))
                            .padding(BSCSpacing.sm)
                    }
                }
                .offset(x: carouselOffset)
                .contentShape(Rectangle())
                .gesture(carouselGesture(width: geo.size.width))
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))

            // Page dots
            if viewModel.savedRallyIndices.count > 1 {
                HStack(spacing: BSCSpacing.xs) {
                    ForEach(viewModel.savedRallyIndices.indices, id: \.self) { i in
                        Circle()
                            .fill(i == viewModel.selectedPage ? Color.bscOrange : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.selectedPage)
                    }
                }
            }
        }
    }

    private var currentThumbnailURL: URL? {
        let index = viewModel.currentRallyIndex
        guard index < viewModel.rallyVideoURLs.count else { return nil }
        return viewModel.rallyVideoURLs[index]
    }

    // MARK: - Carousel Gesture

    private func carouselGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isSliding, viewModel.savedRallyIndices.count > 1 else { return }
                // Rubber-band at edges
                let atStart = viewModel.selectedPage == 0 && value.translation.width > 0
                let atEnd = viewModel.selectedPage == viewModel.savedRallyIndices.count - 1
                    && value.translation.width < 0
                carouselOffset = (atStart || atEnd)
                    ? value.translation.width * 0.25
                    : value.translation.width
            }
            .onEnded { value in
                guard !isSliding, viewModel.savedRallyIndices.count > 1 else {
                    snapBack()
                    return
                }

                let threshold = width * 0.25
                let velocity = value.predictedEndTranslation.width

                if (value.translation.width < -threshold || velocity < -threshold),
                   viewModel.selectedPage < viewModel.savedRallyIndices.count - 1 {
                    slideTo(page: viewModel.selectedPage + 1, direction: -1, width: width)
                } else if (value.translation.width > threshold || velocity > threshold),
                          viewModel.selectedPage > 0 {
                    slideTo(page: viewModel.selectedPage - 1, direction: 1, width: width)
                } else {
                    snapBack()
                }
            }
    }

    private func slideTo(page: Int, direction: CGFloat, width: CGFloat) {
        isSliding = true

        // Slide current content off-screen in the swipe direction
        withAnimation(.easeIn(duration: 0.18)) {
            carouselOffset = direction * width
        }

        // At midpoint: swap page (player seeks while off-screen), jump to opposite side
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            viewModel.selectedPage = page
            carouselOffset = direction * -width

            // Slide new content in
            withAnimation(.easeOut(duration: 0.22)) {
                carouselOffset = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                isSliding = false
            }
        }
    }

    private func snapBack() {
        withAnimation(.easeOut(duration: 0.2)) {
            carouselOffset = 0
        }
    }

    // MARK: - Player Management

    private func configurePlayer() {
        // Remove old boundary observer
        if let observer = loopObserver {
            player.removeTimeObserver(observer)
            loopObserver = nil
        }

        guard let info = viewModel.currentShareInfo else { return }
        let startTime = CMTimeMakeWithSeconds(info.startTime, preferredTimescale: 600)
        let endTime = CMTimeMakeWithSeconds(info.endTime, preferredTimescale: 600)

        // Create item only once (all rallies are from the same source video)
        if player.currentItem == nil {
            let item = AVPlayerItem(url: viewModel.originalVideoURL)
            player.replaceCurrentItem(with: item)
        }

        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()

        // Loop back to start when reaching end of rally segment
        loopObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [player] in
            player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func cleanupPlayer() {
        if let observer = loopObserver {
            player.removeTimeObserver(observer)
            loopObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
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
                                .foregroundColor(.bscOrange)
                                .padding(.horizontal, BSCSpacing.sm)
                                .padding(.vertical, BSCSpacing.xxs)
                                .background(Color.bscOrange.opacity(0.15))
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
            .tint(.bscOrange)
            .padding(BSCSpacing.sm)
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
                    .tint(.bscOrange)
                Text(viewModel.postAllSaved && viewModel.postCount > 1
                     ? "Uploading \(viewModel.postCount) rallies... \(Int(progress * 100))%"
                     : "Uploading... \(Int(progress * 100))%")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

        case .processing:
            HStack(spacing: BSCSpacing.sm) {
                ProgressView()
                    .tint(.bscOrange)
                Text("Processing...")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

        case .complete:
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)
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
                    .foregroundColor(.red)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.retry() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscOrange)
            }
        }
    }

    // MARK: - Post Button

    private var postButton: some View {
        let canPost = viewModel.state == .idle && (!viewModel.isTooLong || viewModel.postAllSaved)
        return Button("Post") {
            if authService.isAuthenticated {
                viewModel.upload()
            } else {
                showAuthGate = true
            }
        }
        .disabled(!canPost)
        .fontWeight(.semibold)
        .foregroundColor(canPost ? .bscOrange : .bscTextTertiary)
    }
}
