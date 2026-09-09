//
//  MainTabView.swift
//  BumpSetCut
//
//  Root tab container with Home, Feed, and Profile tabs.
//

import SwiftUI

enum AppTab: Int, CaseIterable {
    case home
    case feed
    case search
    case profile
}

// Environment key for changing tabs from child views
private struct ChangeTabKey: EnvironmentKey {
    static let defaultValue: (AppTab) -> Void = { _ in }
}

extension EnvironmentValues {
    var changeTab: (AppTab) -> Void {
        get { self[ChangeTabKey.self] }
        set { self[ChangeTabKey.self] = newValue }
    }
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .home
    @State private var mediaStore: MediaStore
    @State private var metadataStore = MetadataStore()
    @State private var navigationState = AppNavigationState()
    @State private var uploadCoordinator: UploadCoordinator
    @State private var showProcessingView = false
    @State private var showCancelUploadDialog = false
    @State private var showLowStorageBanner = false
    @State private var lowStorageAvailable: Int64 = 0
    @State private var lowStorageDismissed = false
    // Deep link (bumpsetcut://highlight/<id>) presentation
    @State private var deepLinkedHighlight: Highlight?
    @State private var deepLinkedComments: Highlight?
    private var processingCoordinator = ProcessingCoordinator.shared
    private var flywheelService = FlywheelCaptureService.shared

    @Environment(AuthenticationService.self) private var authService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = MediaStore()
        _mediaStore = State(initialValue: store)
        _uploadCoordinator = State(initialValue: UploadCoordinator(mediaStore: store))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // Home
                NavigationStack {
                    HomeView(mediaStore: mediaStore, metadataStore: metadataStore)
                }
                .tag(AppTab.home)
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
                .accessibilityIdentifier(AccessibilityID.Tab.home)

                // Feed
                NavigationStack {
                    if authService.isAuthenticated {
                        SocialFeedView()
                    } else {
                        AuthGateView(onSkip: {
                            selectedTab = .home
                        })
                    }
                }
                .tag(AppTab.feed)
                .tabItem {
                    Image(systemName: "flame.fill")
                    Text("Feed")
                }
                .accessibilityIdentifier(AccessibilityID.Tab.feed)

                // Search
                NavigationStack {
                    SearchCommunityView()
                }
                .tag(AppTab.search)
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .accessibilityIdentifier(AccessibilityID.Tab.search)

                // Profile
                NavigationStack {
                    ProfileTabView()
                }
                .tag(AppTab.profile)
                .tabItem {
                    Image(systemName: "person.fill")
                    Text("Profile")
                }
                .accessibilityIdentifier(AccessibilityID.Tab.profile)
            }
            .tint(.bscPrimary)

            // Floating processing progress pill
            if processingCoordinator.isProcessing || processingCoordinator.showCompletionPill {
                processingPill
                    .padding(.bottom, 54) // Above tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            } else if uploadCoordinator.isUploadInProgress {
                videoUploadPill
                    .padding(.bottom, 54) // Above tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(99)
            } else if flywheelService.isDraining {
                flywheelUploadPill
                    .padding(.bottom, 54) // Above tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(98)
            } else if showLowStorageBanner {
                lowStorageBannerView
                    .padding(.bottom, 54) // Above tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(97)
            }
        }
        .animation(.bscSpring, value: processingCoordinator.isProcessing)
        .animation(.bscSpring, value: processingCoordinator.showCompletionPill)
        .animation(.bscSpring, value: uploadCoordinator.isUploadInProgress)
        .animation(.bscSpring, value: uploadCoordinator.showCompleted)
        .animation(.bscSpring, value: flywheelService.isDraining)
        .animation(.bscSpring, value: showLowStorageBanner)
        .confirmationDialog("Cancel upload?", isPresented: $showCancelUploadDialog, titleVisibility: .visible) {
            Button("Cancel Upload", role: .destructive) { uploadCoordinator.cancelImport() }
            Button("Keep Uploading", role: .cancel) {}
        }
        .alert("Storage Full", isPresented: Binding(
            get: { uploadCoordinator.showStorageWarning },
            set: { uploadCoordinator.showStorageWarning = $0 }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadCoordinator.storageWarningMessage)
        }
        .alert("Import Failed", isPresented: Binding(
            get: { uploadCoordinator.showImportError },
            set: { uploadCoordinator.showImportError = $0 }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadCoordinator.importErrorMessage)
        }
        .environment(uploadCoordinator)
        .environment(navigationState)
        .environment(\.changeTab, { tab in
            selectedTab = tab
        })
        .onChange(of: navigationState.postedHighlight) { _, highlight in
            if highlight != nil {
                selectedTab = .feed
            }
        }
        .onChange(of: navigationState.pendingSearchQuery) { _, query in
            if query != nil {
                selectedTab = .search
            }
        }
        .onAppear { checkStorage() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { checkStorage() }
        }
        .sheet(isPresented: $showProcessingView) {
            if let videoURL = processingCoordinator.videoURL,
               let store = processingCoordinator.mediaStore {
                NavigationStack {
                    ProcessVideoView(
                        videoURL: videoURL,
                        mediaStore: store,
                        onComplete: { showProcessingView = false }
                    )
                }
            }
        }
        .onOpenURL { url in handleDeepLink(url) }
        .fullScreenCover(item: $deepLinkedHighlight) { highlight in
            deepLinkHighlightView(highlight)
                .commentsPanel(item: $deepLinkedComments)
        }
    }

    // MARK: - Deep Links

    /// Handle `bumpsetcut://highlight/<id>` by fetching the post and presenting it.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "bumpsetcut", url.host == "highlight" else { return }
        // Validate the path component is a real UUID before feeding external input to the
        // backend — never pass arbitrary deep-link strings straight into a query.
        let id = url.lastPathComponent
        guard UUID(uuidString: id) != nil else { return }
        Task {
            if let highlight: Highlight = try? await SupabaseAPIClient.shared.request(.getHighlight(id: id)) {
                deepLinkedHighlight = highlight
            }
        }
    }

    /// Full-screen viewer for a deep-linked highlight (mirrors Search's detail).
    private func deepLinkHighlightView(_ highlight: Highlight) -> some View {
        ZStack(alignment: .topTrailing) {
            HighlightCardView(
                highlight: highlight,
                onLike: {},
                onComment: {
                    deepLinkedComments = highlight
                },
                onProfile: { _ in }
            )

            Button {
                deepLinkedHighlight = nil
            } label: {
                // 44pt hit target (28pt glyph + 8pt each side); outer padding drops
                // to xs so the icon stays visually 12pt from the edge as before.
                Image(systemName: "xmark.circle.fill")
                    .bscFont(size: 28)
                    .foregroundColor(Color.bscOnMedia.opacity(0.85))
                    .shadow(color: Color.bscMediaScrimBase.opacity(0.33), radius: 4)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            .padding(BSCSpacing.xs)
        }
    }

    // MARK: - Processing Progress Pill

    /// Subtitle for the processing pill — shows a live ETA once enough progress
    /// has accrued, otherwise the "keep app open" reminder with the video name.
    private var processingETASubtitle: String {
        if let remaining = processingCoordinator.estimatedSecondsRemaining, remaining > 1 {
            return "\(ProcessingTimeEstimator.formatEstimate(remaining)) left \u{2022} keep app open"
        }
        return "Keep app open \u{2022} \(processingCoordinator.videoName)"
    }

    /// Video import pill — mirrors the processing pill's style. Shown while a
    /// video is importing from Photos (incl. iCloud download) so the user can
    /// keep using the app. Tapping offers a cancel confirmation.
    private var videoUploadPill: some View {
        Button {
            if !uploadCoordinator.showCompleted {
                showCancelUploadDialog = true
            }
        } label: {
            HStack(spacing: BSCSpacing.sm) {
                if uploadCoordinator.showCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 20)
                        .foregroundColor(.bscSuccessText)

                    Text("Upload complete!")
                        .bscFont(size: 13, weight: .semibold)
                        .foregroundColor(.bscTextPrimary)
                } else {
                    ZStack {
                        if let fraction = uploadCoordinator.importProgress {
                            Circle().stroke(Color.bscSurfaceBorder, lineWidth: 2.5)
                                .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                            Circle()
                                .trim(from: 0, to: fraction)
                                .stroke(Color.bscPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "arrow.up")
                                .bscFont(size: 9, weight: .bold)
                                .foregroundColor(.bscPrimary)
                        } else {
                            // Indeterminate (drag-drop, or before load progress arrives)
                            ProgressView()
                                .tint(.bscPrimary)
                                .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Uploading \(uploadCoordinator.currentVideoName)…")
                            .bscFont(size: 13, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                        Text(uploadCoordinator.uploadProgressText.isEmpty
                             ? "keep the app open"
                             : uploadCoordinator.uploadProgressText)
                            .bscFont(size: 11)
                            .foregroundColor(.bscTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let fraction = uploadCoordinator.importProgress {
                        Text("\(Int(fraction * 100))%")
                            .bscFont(size: 14, weight: .bold, design: .monospaced)
                            .foregroundColor(.bscPrimaryText)
                    }
                }
            }
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.sm)
            .frame(maxWidth: 500, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .fill(Color.bscBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
            .bscShadow(BSCShadow.md)
            .padding(.horizontal, BSCSpacing.lg)
        }
        .buttonStyle(.plain)
    }

    /// Flywheel upload pill — mirrors the processing pill's style. Shown while
    /// frames are draining to the server so the user knows not to quit mid-upload.
    private var flywheelUploadPill: some View {
        HStack(spacing: BSCSpacing.sm) {
            ZStack {
                Circle().stroke(Color.bscSurfaceBorder, lineWidth: 2.5).frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                Circle()
                    .trim(from: 0, to: flywheelService.uploadProgress)
                    .stroke(Color.bscPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.up")
                    .bscFont(size: 9, weight: .bold)
                    .foregroundColor(.bscPrimary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Uploading rally data…")
                    .bscFont(size: 13, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                Text(flywheelService.uploadFrameTotal > 0
                     ? "\(flywheelService.uploadFrameTotal) frames · keep the app open"
                     : "keep the app open")
                    .bscFont(size: 11)
                    .foregroundColor(.bscTextSecondary)
                    .lineLimit(1)
            }

            Spacer()
            Text("\(Int(flywheelService.uploadProgress * 100))%")
                .bscFont(size: 14, weight: .bold, design: .monospaced)
                .foregroundColor(.bscPrimaryText)
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                .fill(Color.bscBackgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        )
        .bscShadow(BSCShadow.md)
        .padding(.horizontal, BSCSpacing.lg)
    }

    private var processingPill: some View {
        Button {
            if processingCoordinator.videoURL != nil {
                showProcessingView = true
            } else {
                selectedTab = .home
            }
        } label: {
            HStack(spacing: BSCSpacing.sm) {
                if processingCoordinator.didComplete {
                    // Completion state
                    if processingCoordinator.errorMessage != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .bscFont(size: 20)
                            .foregroundColor(.bscError)

                        Text("Processing failed")
                            .bscFont(size: 13, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                    } else {
                        Image(systemName: processingCoordinator.noRalliesDetected ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .bscFont(size: 20)
                            .foregroundColor(processingCoordinator.noRalliesDetected ? .bscTextSecondary : .bscSuccessText)

                        Text(processingCoordinator.noRalliesDetected ? "No rallies found" : "Processing complete!")
                            .bscFont(size: 13, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                    }
                } else {
                    // Progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.bscSurfaceBorder, lineWidth: 2.5)
                            .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)

                        Circle()
                            .trim(from: 0, to: processingCoordinator.progress)
                            .stroke(Color.bscPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                            .rotationEffect(.degrees(-90))

                        Text("\(processingCoordinator.progressPercent)")
                            .bscFont(size: 8, weight: .bold, design: .monospaced)
                            .foregroundColor(.bscPrimaryText)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: BSCSpacing.xxs) {
                            Text("Processing...")
                                .bscFont(size: 13, weight: .semibold)
                                .foregroundColor(.bscTextPrimary)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .bscFont(size: 9)
                                .foregroundColor(.bscWarningText)
                        }

                        Text(processingETASubtitle)
                            .bscFont(size: 11)
                            .foregroundColor(.bscTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(processingCoordinator.progressPercent)%")
                        .bscFont(size: 14, weight: .bold, design: .monospaced)
                        .foregroundColor(.bscPrimaryText)
                }
            }
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.sm)
            .frame(maxWidth: 500, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .fill(Color.bscBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
            .bscShadow(BSCShadow.md)
            .padding(.horizontal, BSCSpacing.lg)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Low Storage Banner

    private var lowStorageBannerView: some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .bscFont(size: 16)
                .foregroundColor(.bscWarningText)

            Text("Storage nearly full — \(StorageChecker.formatBytes(lowStorageAvailable)) remaining. Free up space to avoid issues.")
                .bscFont(size: 12, weight: .medium)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button {
                withAnimation(.bscSpring) {
                    showLowStorageBanner = false
                    lowStorageDismissed = true
                }
            } label: {
                // 44pt hit target around the small glyph; trailing alignment keeps
                // the visible icon where it was, extending the tappable area inward.
                Image(systemName: "xmark")
                    .bscFont(size: 12, weight: .bold)
                    .foregroundColor(.bscTextSecondary)
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                .fill(Color.bscBackgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                .stroke(Color.bscWarning.opacity(0.4), lineWidth: 1)
        )
        .bscShadow(BSCShadow.md)
        .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Storage Check

    private func checkStorage() {
        let (isLow, available) = StorageChecker.isStorageLow()
        lowStorageAvailable = available
        if isLow && !lowStorageDismissed {
            showLowStorageBanner = true
        } else if !isLow {
            showLowStorageBanner = false
        }
    }
}
