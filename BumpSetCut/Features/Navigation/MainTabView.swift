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
    @State private var followToast: BSCToastMessage?
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

    /// Bottom padding that keeps floating pills clear of the tab bar.
    private let tabBarClearance: CGFloat = 54

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
            // bscPrimaryText, not bscPrimary: the selected tab label renders as
            // text and needs the AA-passing variant (raw bscPrimary is 3.68:1).
            .tint(.bscPrimaryText)

            // Floating processing progress pill
            if processingCoordinator.isProcessing || processingCoordinator.showCompletionPill {
                processingPill
                    .padding(.bottom, tabBarClearance)
                    .transition(.bscSlideUp)
                    .zIndex(100)
            } else if uploadCoordinator.isUploadInProgress {
                videoUploadPill
                    .padding(.bottom, tabBarClearance)
                    .transition(.bscSlideUp)
                    .zIndex(99)
            } else if flywheelService.isDraining {
                flywheelUploadPill
                    .padding(.bottom, tabBarClearance)
                    .transition(.bscSlideUp)
                    .zIndex(98)
            } else if showLowStorageBanner {
                lowStorageBannerView
                    .padding(.bottom, tabBarClearance)
                    .transition(.bscSlideUp)
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
        .bscToast($followToast)
        .onChange(of: SocialNotificationService.shared.followToast) { _, message in
            // A follow arrived while the app is active — surface it on whatever
            // tab the user is on.
            guard let message else { return }
            followToast = BSCToastMessage(text: message, style: .success)
            SocialNotificationService.shared.followToast = nil
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
                        // Completion must NOT dismiss: the view transitions to
                        // its results summary (rally count, time cut, View
                        // Rallies) — auto-closing it here made the pill's
                        // "tap to view" open and instantly vanish.
                        onComplete: {}
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

            // xs outer padding keeps the icon visually 12pt from the edge
            // (the component's 44pt hit frame supplies the other 8pt).
            BSCMediaCloseButton {
                deepLinkedHighlight = nil
            }
            .padding(BSCSpacing.xs)
        }
    }

    // MARK: - Processing Progress Pill

    /// Subtitle for the processing pill — a live ETA once enough progress has
    /// accrued, plus what leaving the app means: with a continued-processing
    /// task active (iOS 26+) processing follows the user out; otherwise
    /// checkpoints mean leaving only pauses it.
    private var processingETASubtitle: String {
        let leaveNote = ProcessingBackgroundKeeper.processing.isActive
            ? "free to leave the app"
            : "progress saves if you leave"
        if let remaining = processingCoordinator.estimatedSecondsRemaining, remaining > 1 {
            return "\(ProcessingTimeEstimator.formatEstimate(remaining)) left \u{2022} \(leaveNote)"
        }
        return "\(processingCoordinator.videoName) \u{2022} \(leaveNote)"
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
            if uploadCoordinator.showCompleted {
                BSCStatusPill(title: "Upload complete!") {
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 20)
                        .foregroundColor(.bscSuccessText)
                } trailing: {}
            } else {
                BSCStatusPill(
                    title: "Uploading \(uploadCoordinator.currentVideoName)…",
                    subtitle: uploadCoordinator.uploadProgressText.isEmpty
                        ? (ProcessingBackgroundKeeper.importing.isActive
                           ? "free to leave the app"
                           : "keep the app open")
                        : uploadCoordinator.uploadProgressText
                ) {
                    if let fraction = uploadCoordinator.importProgress {
                        BSCProgressRing(progress: fraction) {
                            Image(systemName: "arrow.up")
                                .bscFont(size: 9, weight: .bold)
                                .foregroundColor(.bscPrimary)
                        }
                    } else {
                        // Indeterminate (drag-drop, or before load progress arrives)
                        ProgressView()
                            .tint(.bscPrimary)
                            .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                    }
                } trailing: {
                    Spacer()

                    if let fraction = uploadCoordinator.importProgress {
                        Text("\(Int(fraction * 100))%")
                            .bscFont(size: 14, weight: .bold, design: .monospaced)
                            .foregroundColor(.bscPrimaryText)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Flywheel upload pill — mirrors the processing pill's style. Shown while
    /// frames are draining to the server so the user knows not to quit mid-upload.
    private var flywheelUploadPill: some View {
        BSCStatusPill(
            title: "Uploading rally data…",
            subtitle: flywheelService.uploadFrameTotal > 0
                ? "\(flywheelService.uploadFrameTotal) frames · keep the app open"
                : "keep the app open"
        ) {
            BSCProgressRing(progress: flywheelService.uploadProgress) {
                Image(systemName: "arrow.up")
                    .bscFont(size: 9, weight: .bold)
                    .foregroundColor(.bscPrimary)
            }
        } trailing: {
            Spacer()
            Text("\(Int(flywheelService.uploadProgress * 100))%")
                .bscFont(size: 14, weight: .bold, design: .monospaced)
                .foregroundColor(.bscPrimaryText)
        }
    }

    private var processingPill: some View {
        Button {
            if processingCoordinator.videoURL != nil {
                showProcessingView = true
            } else {
                selectedTab = .home
            }
        } label: {
            if processingCoordinator.didComplete {
                // Completion state
                if processingCoordinator.errorMessage != nil {
                    BSCStatusPill(title: "Processing failed") {
                        Image(systemName: "exclamationmark.circle.fill")
                            .bscFont(size: 20)
                            .foregroundColor(.bscError)
                    } trailing: {}
                } else if processingCoordinator.noRalliesDetected {
                    BSCStatusPill(
                        title: "No rallies found",
                        subtitle: "\(processingCoordinator.videoName) \u{2022} tap for options"
                    ) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .bscFont(size: 20)
                            .foregroundColor(.bscTextSecondary)
                    } trailing: {}
                } else {
                    // A summary that survives a trip away from the app — the
                    // user shouldn't have to hunt for the processed video.
                    BSCStatusPill(
                        title: "\(processingCoordinator.completedRallyCount) \(processingCoordinator.completedRallyCount == 1 ? "rally" : "rallies") found",
                        subtitle: "\(processingCoordinator.videoName) \u{2022} tap to view"
                    ) {
                        Image(systemName: "checkmark.circle.fill")
                            .bscFont(size: 20)
                            .foregroundColor(.bscSuccessText)
                    } trailing: {}
                }
            } else {
                BSCStatusPill {
                    BSCProgressRing(progress: processingCoordinator.progress) {
                        Text("\(processingCoordinator.progressPercent)")
                            .bscFont(size: 8, weight: .bold, design: .monospaced)
                            .foregroundColor(.bscPrimaryText)
                    }
                } content: {
                    BSCStatusPillLabel(title: "Processing...", subtitle: processingETASubtitle) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .bscFont(size: 9)
                            .foregroundColor(.bscWarningText)
                    }
                } trailing: {
                    Spacer()

                    Text("\(processingCoordinator.progressPercent)%")
                        .bscFont(size: 14, weight: .bold, design: .monospaced)
                        .foregroundColor(.bscPrimaryText)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Low Storage Banner

    private var lowStorageBannerView: some View {
        // Bespoke content (12pt two-line message, warning border) rather than the
        // standard title/subtitle stack — restyling it would change the banner.
        BSCStatusPill(borderColor: Color.bscWarning.opacity(0.4)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .bscFont(size: 16)
                .foregroundColor(.bscWarningText)
        } content: {
            Text("Storage nearly full — \(StorageChecker.formatBytes(lowStorageAvailable)) remaining. Free up space to avoid issues.")
                .bscFont(size: 12, weight: .medium)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(2)
        } trailing: {
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
                    .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
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
