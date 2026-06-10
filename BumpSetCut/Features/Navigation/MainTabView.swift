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
    @State private var mediaStore = MediaStore()
    @State private var metadataStore = MetadataStore()
    @State private var navigationState = AppNavigationState()
    @State private var showProcessingView = false
    @State private var showLowStorageBanner = false
    @State private var lowStorageAvailable: Int64 = 0
    @State private var lowStorageDismissed = false
    // Deep link (bumpsetcut://highlight/<id>) presentation
    @State private var deepLinkedHighlight: Highlight?
    @State private var deepLinkedComments: Highlight?
    private var processingCoordinator = ProcessingCoordinator.shared

    @Environment(AuthenticationService.self) private var authService
    @Environment(\.scenePhase) private var scenePhase

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
            } else if showLowStorageBanner {
                lowStorageBannerView
                    .padding(.bottom, 54) // Above tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(99)
            }
        }
        .animation(.bscSpring, value: processingCoordinator.isProcessing)
        .animation(.bscSpring, value: processingCoordinator.showCompletionPill)
        .animation(.bscSpring, value: showLowStorageBanner)
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
                        folderPath: LibraryType.processed.rootPath,
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
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(radius: 4)
            }
            .padding(BSCSpacing.md)
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

    private var processingPill: some View {
        Button {
            print("🔘 Processing pill tapped — videoURL=\(processingCoordinator.videoURL?.lastPathComponent ?? "nil"), showProcessingView=\(showProcessingView)")
            if processingCoordinator.videoURL != nil {
                showProcessingView = true
            } else {
                print("⚠️ Pill tap: videoURL is nil, switching to home tab")
                selectedTab = .home
            }
        } label: {
            HStack(spacing: BSCSpacing.sm) {
                if processingCoordinator.didComplete {
                    // Completion state
                    Image(systemName: processingCoordinator.noRalliesDetected ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(processingCoordinator.noRalliesDetected ? .bscTextSecondary : .bscSuccess)

                    Text(processingCoordinator.noRalliesDetected ? "No rallies found" : "Processing complete!")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.bscTextPrimary)
                } else {
                    // Progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.bscSurfaceBorder, lineWidth: 2.5)
                            .frame(width: 24, height: 24)

                        Circle()
                            .trim(from: 0, to: processingCoordinator.progress)
                            .stroke(Color.bscPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: 24, height: 24)
                            .rotationEffect(.degrees(-90))

                        Text("\(processingCoordinator.progressPercent)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.bscPrimary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: BSCSpacing.xxs) {
                            Text("Processing...")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.bscTextPrimary)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.bscWarning)
                        }

                        Text(processingETASubtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.bscTextTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(processingCoordinator.progressPercent)%")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.bscPrimary)
                }
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
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.horizontal, BSCSpacing.lg)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Low Storage Banner

    private var lowStorageBannerView: some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(.bscWarning)

            Text("Storage nearly full — \(StorageChecker.formatBytes(lowStorageAvailable)) remaining. Free up space to avoid issues.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.bscTextPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button {
                withAnimation(.bscSpring) {
                    showLowStorageBanner = false
                    lowStorageDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.bscTextSecondary)
            }
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
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
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
