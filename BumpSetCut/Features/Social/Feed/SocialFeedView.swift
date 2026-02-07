//
//  SocialFeedView.swift
//  BumpSetCut
//
//  TikTok-style vertical feed of volleyball highlight clips.
//

import SwiftUI

struct SocialFeedView: View {
    @State private var viewModel = SocialFeedViewModel()
    @State private var selectedHighlightForComments: Highlight?
    @State private var selectedProfileId: String?
    @State private var currentIndex = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading && viewModel.highlights.isEmpty {
                ProgressView()
                    .tint(.bscOrange)
                    .scaleEffect(1.5)
            } else if viewModel.highlights.isEmpty {
                emptyState
            } else {
                feedContent
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
        .sheet(item: $selectedProfileId) { profileId in
            NavigationStack {
                ProfileView(userId: profileId)
            }
        }
    }

    // MARK: - Feed Content

    private var feedContent: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(viewModel.highlights.enumerated()), id: \.element.id) { index, highlight in
                HighlightCardView(
                    highlight: highlight,
                    onLike: {
                        Task { await viewModel.toggleLike(for: highlight) }
                    },
                    onComment: {
                        selectedHighlightForComments = highlight
                    },
                    onProfile: { authorId in
                        selectedProfileId = authorId
                    }
                )
                .tag(index)
                .task {
                    await viewModel.loadMoreIfNeeded(currentItem: highlight)
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BSCSpacing.lg) {
            Image(systemName: "figure.volleyball")
                .font(.system(size: 48))
                .foregroundColor(.bscTextSecondary)

            Text("No highlights yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.bscTextPrimary)

            Text("Be the first to share a volleyball rally!")
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

// MARK: - String Identifiable for profile sheet

extension String: @retroactive Identifiable {
    public var id: String { self }
}
