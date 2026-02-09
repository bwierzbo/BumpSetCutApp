//
//  SocialFeedView.swift
//  BumpSetCut
//
//  TikTok-style vertical feed of volleyball highlight clips.
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
                    .tint(.bscOrange)
                    .scaleEffect(1.5)
            } else if viewModel.highlights.isEmpty {
                emptyState
            } else {
                feedContent
            }

            // Tab picker overlay
            VStack {
                feedTabPicker
                Spacer()
            }
        }
        .task {
            await viewModel.loadFeed()
        }
        .sheet(item: $selectedHighlightForComments) { highlight in
            CommentsSheet(highlight: highlight)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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
                    HighlightCardView(
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
                        onDelete: highlight.authorId == authService.currentUser?.id ? {
                            Task { await viewModel.deleteHighlight(highlight) }
                        } : nil
                    )
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
        .ignoresSafeArea()
    }

    // MARK: - Tab Picker

    private var feedTabPicker: some View {
        HStack(spacing: 0) {
            ForEach(FeedTab.allCases, id: \.self) { tab in
                Button {
                    guard selectedTab != tab else { return }
                    selectedTab = tab
                    currentIndex = 0
                    viewModel.switchFeed(tab == .following ? .following : .forYou)
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: selectedTab == tab ? .bold : .medium))
                        .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.6))
                        .padding(.vertical, BSCSpacing.sm)
                        .padding(.horizontal, BSCSpacing.md)
                }
            }
        }
        .padding(.vertical, BSCSpacing.xs)
        .padding(.horizontal, BSCSpacing.sm)
        .background(.ultraThinMaterial.opacity(0.8))
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
                    .foregroundColor(.bscOrange)
            }
        }
        .padding(BSCSpacing.xl)
    }
}

// MARK: - Profile ID wrapper for sheet binding

struct ProfileID: Identifiable {
    let id: String
}
