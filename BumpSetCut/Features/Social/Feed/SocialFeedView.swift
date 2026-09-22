//
//  SocialFeedView.swift
//  BumpSetCut
//
//  Vertical feed of volleyball highlight clips.
//

import SwiftUI

enum FeedTab: String, CaseIterable {
    case forYou = "For You"
    case following = "Following"
}

struct SocialFeedView: View {
    @State private var viewModel = SocialFeedViewModel()
    @State private var selectedHighlightForComments: Highlight?
    @State private var selectedProfileId: ProfileID?
    @State private var currentIndex: Int? = 0
    @State private var selectedTab: FeedTab = .forYou
    @State private var toast: BSCToastMessage?
    @State private var sendRequest: SendToRequest?
    @Environment(AppNavigationState.self) private var navigationState
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            Color.bscMediaBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.highlights.isEmpty {
                loadingSkeleton
            } else if viewModel.visibleHighlights.isEmpty {
                if viewModel.error != nil {
                    BSCEmptyState.loadFailed(message: viewModel.error?.localizedDescription) {
                        Task { await viewModel.loadFeed() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Feed.emptyState)
                } else {
                    emptyState
                        .accessibilityIdentifier(AccessibilityID.Feed.emptyState)
                }
            } else {
                feedContent
            }

            // Tab picker overlay
            VStack {
                feedTabPicker
                Spacer()
            }

            // Pagination footer: spinner while fetching the next page, retry row on failure
            if !viewModel.highlights.isEmpty, viewModel.isLoadingMore || viewModel.loadMoreFailed {
                VStack {
                    Spacer()
                    loadMoreFooter
                }
            }
        }
        // Full-screen video is a dark context: keeps letterbox bars black and chrome
        // readable in light mode. Semantic tokens inside resolve to their dark variants.
        .environment(\.colorScheme, .dark)
        .task {
            // Only load on first appearance — reloading on every tab return would
            // discard pagination and snap the feed back to the top. Pull-to-refresh
            // and the For You/Following switch still force a fresh load.
            if viewModel.highlights.isEmpty {
                await viewModel.loadFeed()
            }
        }
        .bscToast($toast)
        .onChange(of: viewModel.actionError) { _, message in
            if let message {
                toast = BSCToastMessage(text: message, style: .error)
                viewModel.actionError = nil
            }
        }
        .commentsPanel(item: $selectedHighlightForComments)
        .sheet(item: $sendRequest) { request in
            SendToSheet(payload: request.payload) { conversationId, username in
                toast = .sent(to: username, conversationId: conversationId, navigationState: navigationState)
            }
        }
        // The comments input bar reaches the screen bottom; hide the floating
        // tab bar while the panel is open so it doesn't cover the input.
        .toolbarVisibility(selectedHighlightForComments == nil ? .automatic : .hidden, for: .tabBar)
        .sheet(item: $selectedProfileId) { profile in
            NavigationStack {
                ProfileView(userId: profile.id)
                    .toolbar {
                        // Pull-down fights the profile's own scroll/refresh, so
                        // give an explicit way out (tester feedback).
                        ToolbarItem(placement: .navigationBarLeading) {
                            BSCIconButton(icon: "chevron.left", style: .ghost, size: .compact, accessibilityLabel: "Back to feed") {
                                selectedProfileId = nil
                            }
                            .accessibilityIdentifier(AccessibilityID.Feed.profileBack)
                        }
                    }
                    // This sheet is its own NavigationStack, so it needs its own
                    // profile destination for the follower/following lists.
                    .profileNavigationDestinations()
            }
            .presentationDragIndicator(.visible)
        }
        .onChange(of: navigationState.postedHighlight) { _, highlight in
            if let highlight {
                viewModel.prependHighlight(highlight)
                currentIndex = 0
                navigationState.postedHighlight = nil
            }
        }
    }

    // MARK: - Feed Content

    private var feedContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.visibleHighlights.enumerated()), id: \.element.id) { index, highlight in
                    highlightCard(index: index, highlight: highlight)
                        .containerRelativeFrame(.vertical)
                        .id(index)
                        .task {
                            await viewModel.loadMoreIfNeeded(currentItem: highlight)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .refreshable {
            await viewModel.loadFeed()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentIndex)
        // Portrait: full-bleed top/sides only — respect the bottom safe area so
        // the horizontal carousel ends above the tab bar instead of under it
        // (the tab bar swallows swipes in that strip). Landscape: full-bleed on
        // every edge so pages fill the screen exactly — anything less leaves a
        // strip where the next post's frame shows through (tester feedback).
        .ignoresSafeArea(edges: isLandscape ? [.all] : [.top, .horizontal])
        // Card heights (containerRelativeFrame) go stale across rotation,
        // misaligning pages; rebuild the pager and let scrollPosition restore
        // the current post.
        .id(isLandscape)
    }

    private func highlightCard(index: Int, highlight: Highlight) -> some View {
        let isOwner = highlight.authorId == authService.currentUser?.id
        let deleteAction: (() -> Void)? = isOwner ? {
            Task {
                let deleted = await viewModel.deleteHighlight(highlight)
                if !deleted {
                    toast = BSCToastMessage(text: "Couldn't delete post", style: .error)
                }
            }
        } : nil

        return HighlightCardView(
            highlight: highlight,
            isActive: currentIndex == index,
            onLike: {
                Task { await viewModel.toggleLike(for: highlight) }
            },
            onComment: {
                selectedHighlightForComments = highlight
            },
            onProfile: { authorId in
                selectedProfileId = ProfileID(id: authorId)
            },
            onDelete: deleteAction,
            onLocation: { location in
                navigationState.pendingSearchQuery = location
            },
            onSend: authService.isAuthenticated
                ? { sendRequest = SendToRequest(payload: .highlight(highlight)) }
                : nil,
            // Landscape pages are full-bleed (see feedContent), so chrome needs
            // the bottom inset back; portrait cards end above the tab bar.
            extendsUnderBottomSafeArea: isLandscape
        )
    }

    // MARK: - Loading Skeleton

    /// Full-screen placeholder mirroring the feed card chrome: author/caption
    /// bars bottom-left and the action rail on the right.
    private var loadingSkeleton: some View {
        ZStack {
            Color.bscMediaBackground.ignoresSafeArea()

            VStack {
                Spacer()

                HStack(alignment: .bottom, spacing: BSCSpacing.lg) {
                    VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                        HStack(spacing: BSCSpacing.xs) {
                            BSCSkeletonView()
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                            BSCSkeletonView()
                                .frame(width: 96, height: 14)
                                .clipShape(Capsule())
                        }
                        BSCSkeletonView()
                            .frame(width: 200, height: 12)
                            .clipShape(Capsule())
                        BSCSkeletonView()
                            .frame(width: 140, height: 12)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    VStack(spacing: BSCSpacing.lg) {
                        ForEach(0..<3, id: \.self) { _ in
                            BSCSkeletonView()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, BSCSpacing.md)
                .padding(.bottom, BSCSpacing.huge)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading feed")
    }

    // MARK: - Pagination Footer

    private var loadMoreFooter: some View {
        Group {
            if viewModel.isLoadingMore {
                ProgressView()
                    .tint(.bscOnMedia)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.sm)
                    .background(Capsule().fill(Color.bscMediaScrim))
            } else {
                Button {
                    Task { await viewModel.retryLoadMore() }
                } label: {
                    Text("Couldn't load more — tap to retry")
                        .bscFont(size: 13, weight: .medium)
                        .foregroundColor(.bscOnMedia)
                        .padding(.horizontal, BSCSpacing.md)
                        .padding(.vertical, BSCSpacing.sm)
                        .background(Capsule().fill(Color.bscMediaScrim))
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.bottom, BSCSpacing.sm)
    }

    // MARK: - Tab Picker

    private var feedTabPicker: some View {
        HStack(spacing: 0) {
            ForEach(FeedTab.allCases, id: \.self) { tab in
                Button {
                    guard selectedTab != tab else { return }
                    UIImpactFeedbackGenerator.light()
                    withAnimation(.bscQuick) {
                        selectedTab = tab
                    }
                    currentIndex = 0
                    viewModel.switchFeed(tab == .following ? .following : .forYou)
                } label: {
                    Text(tab.rawValue)
                        .bscFont(size: 15, weight: selectedTab == tab ? .bold : .medium)
                        .foregroundColor(selectedTab == tab ? .bscOnMedia : .bscOnMediaSecondary)
                        .padding(.vertical, BSCSpacing.sm)
                        .padding(.horizontal, BSCSpacing.md)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier(tab == .forYou ? AccessibilityID.Feed.forYouTab : AccessibilityID.Feed.followingTab)
            }
        }
        .padding(.vertical, BSCSpacing.xs)
        .padding(.horizontal, BSCSpacing.sm)
        .background(Color.bscMediaScrim)
        .clipShape(Capsule())
        .padding(.top, BSCSpacing.md)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if selectedTab == .following {
            BSCEmptyState.noFollowingHighlights(actionAccessibilityID: AccessibilityID.Feed.refreshButton) {
                Task { await viewModel.loadFeed() }
            }
        } else {
            BSCEmptyState.noHighlights(actionAccessibilityID: AccessibilityID.Feed.refreshButton) {
                Task { await viewModel.loadFeed() }
            }
        }
    }
}

// MARK: - Profile ID wrapper for sheet binding

struct ProfileID: Identifiable {
    let id: String
}
