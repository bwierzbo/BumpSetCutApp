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
    @Environment(AppNavigationState.self) private var navigationState
    @Environment(AuthenticationService.self) private var authService

    var body: some View {
        ZStack {
            Color.bscMediaBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.highlights.isEmpty {
                ProgressView()
                    .tint(.bscPrimary)
                    .scaleEffect(1.5)
            } else if viewModel.highlights.isEmpty {
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
        .commentsPanel(item: $selectedHighlightForComments)
        .sheet(item: $selectedProfileId) { profile in
            NavigationStack {
                ProfileView(userId: profile.id)
            }
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
                ForEach(Array(viewModel.highlights.enumerated()), id: \.element.id) { index, highlight in
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
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentIndex)
        // Full-bleed top/sides only — respect the bottom safe area so the
        // horizontal carousel ends above the tab bar instead of under it
        // (the tab bar swallows swipes in that strip).
        .ignoresSafeArea(edges: [.top, .horizontal])
    }

    private func highlightCard(index: Int, highlight: Highlight) -> some View {
        let isOwner = highlight.authorId == authService.currentUser?.id
        let deleteAction: (() -> Void)? = isOwner ? {
            Task { await viewModel.deleteHighlight(highlight) }
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
            extendsUnderBottomSafeArea: false
        )
    }

    // MARK: - Tab Picker

    private var feedTabPicker: some View {
        HStack(spacing: 0) {
            ForEach(FeedTab.allCases, id: \.self) { tab in
                Button {
                    guard selectedTab != tab else { return }
                    UIImpactFeedbackGenerator.light()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                    currentIndex = 0
                    viewModel.switchFeed(tab == .following ? .following : .forYou)
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: selectedTab == tab ? .bold : .medium))
                        .foregroundColor(selectedTab == tab ? .bscOnMedia : .bscOnMediaSecondary)
                        .padding(.vertical, BSCSpacing.sm)
                        .padding(.horizontal, BSCSpacing.md)
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

    private var emptyState: some View {
        VStack(spacing: BSCSpacing.lg) {
            Image(systemName: selectedTab == .following ? "person.2" : "figure.volleyball")
                .font(.system(size: 48))
                .foregroundColor(.bscTextSecondary)

            Text(selectedTab == .following ? "No highlights from followed users" : "No highlights yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.bscTextPrimary)

            Text(selectedTab == .following
                 ? "Follow players to see their highlights here."
                 : "Be the first to share a volleyball rally!")
                .font(.system(size: 15))
                .foregroundColor(.bscTextSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.loadFeed() }
            } label: {
                Text("Refresh")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscPrimary)
            }
            .accessibilityIdentifier(AccessibilityID.Feed.refreshButton)
        }
        .padding(BSCSpacing.xl)
    }
}

// MARK: - Profile ID wrapper for sheet binding

struct ProfileID: Identifiable {
    let id: String
}
