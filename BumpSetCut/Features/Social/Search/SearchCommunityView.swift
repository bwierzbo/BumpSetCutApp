//
//  SearchCommunityView.swift
//  BumpSetCut
//
//  Community search tab: find users and highlights by keyword or hashtag.
//

import SwiftUI

struct SearchCommunityView: View {
    @State private var viewModel = SearchCommunityViewModel()
    @State private var selectedHighlight: Highlight?
    @State private var selectedHighlightForComments: Highlight?
    @Environment(AuthenticationService.self) private var authService

    private let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: BSCSpacing.xs),
        count: 3
    )

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            Group {
                if isSearchEmpty {
                    trendingSection
                } else {
                    resultsList
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $viewModel.searchText, prompt: "Search users or posts")
        .searchScopes($viewModel.searchScope) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.searchTextChanged()
        }
        .onChange(of: viewModel.searchScope) { _, _ in
            viewModel.scopeChanged()
        }
        .task {
            await viewModel.loadTrendingTags()
        }
        .fullScreenCover(item: $selectedHighlight) { highlight in
            highlightDetail(highlight)
        }
        .sheet(item: $selectedHighlightForComments) { highlight in
            CommentsSheet(highlight: highlight)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var isSearchEmpty: Bool {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Trending Tags

    private var trendingSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BSCSpacing.md) {
                if !viewModel.trendingTags.isEmpty {
                    Text("Trending")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.bscTextPrimary)
                        .padding(.horizontal, BSCSpacing.lg)
                        .padding(.top, BSCSpacing.md)

                    FlowLayout(spacing: BSCSpacing.sm) {
                        ForEach(viewModel.trendingTags, id: \.self) { tag in
                            Button {
                                viewModel.selectTrendingTag(tag)
                            } label: {
                                Text("#\(tag)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.bscOrange)
                                    .padding(.horizontal, BSCSpacing.md)
                                    .padding(.vertical, BSCSpacing.sm)
                                    .background(Color.bscSurfaceGlass)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                }
            }
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .tint(.bscOrange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch viewModel.searchScope {
                case .users:
                    usersResults
                case .posts:
                    postsResults
                }
            }
        }
    }

    // MARK: - Users

    private var usersResults: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.users.isEmpty {
                    emptyResult("No users found")
                } else {
                    ForEach(viewModel.users) { user in
                        NavigationLink(value: user.id) {
                            userRow(user)
                        }
                        .buttonStyle(.plain)
                    }

                    if viewModel.hasMorePages {
                        ProgressView()
                            .tint(.bscOrange)
                            .padding()
                            .onAppear {
                                Task { await viewModel.loadMore() }
                            }
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { userId in
            ProfileView(userId: userId)
        }
    }

    private func userRow(_ user: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.md) {
            Circle()
                .fill(Color.bscSurfaceGlass)
                .frame(width: 44, height: 44)
                .overlay(
                    Text(user.displayName.prefix(1).uppercased())
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.bscOrange)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.bscTextPrimary)
                Text("@\(user.username)")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

            Spacer()

            if authService.isAuthenticated, authService.currentUser?.id != user.id {
                followButton(for: user)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.bscTextTertiary)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
    }

    private func followButton(for user: UserProfile) -> some View {
        let isFollowing = viewModel.isFollowing(user.id)
        return Button {
            Task { await viewModel.toggleFollow(for: user.id) }
        } label: {
            Text(isFollowing ? "Following" : "Follow")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isFollowing ? .bscTextPrimary : .white)
                .padding(.horizontal, BSCSpacing.md)
                .padding(.vertical, 6)
                .background(isFollowing ? Color.bscSurfaceGlass : Color.bscOrange)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Posts

    private var postsResults: some View {
        ScrollView {
            if viewModel.highlights.isEmpty {
                emptyResult("No posts found")
            } else {
                LazyVGrid(columns: gridColumns, spacing: BSCSpacing.xs) {
                    ForEach(viewModel.highlights) { highlight in
                        Button {
                            selectedHighlight = highlight
                        } label: {
                            postGridCell(highlight)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, BSCSpacing.xs)

                if viewModel.hasMorePages {
                    ProgressView()
                        .tint(.bscOrange)
                        .padding()
                        .onAppear {
                            Task { await viewModel.loadMore() }
                        }
                }
            }
        }
    }

    private func postGridCell(_ highlight: Highlight) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                VideoThumbnailView(
                    thumbnailURL: highlight.thumbnailImageURL,
                    videoURL: highlight.allVideoURLs.first ?? highlight.videoURL
                )
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()

                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                        Text("\(highlight.likesCount)")
                            .font(.system(size: 9, weight: .medium))
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.right.fill")
                            .font(.system(size: 9))
                        Text("\(highlight.commentsCount)")
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Empty

    private func emptyResult(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 15))
            .foregroundColor(.bscTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }

    // MARK: - Highlight Detail

    private func highlightDetail(_ highlight: Highlight) -> some View {
        ZStack {
            HighlightCardView(
                highlight: highlight,
                onLike: {},
                onComment: {
                    selectedHighlight = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        selectedHighlightForComments = highlight
                    }
                },
                onProfile: { _ in }
            )

            VStack {
                HStack {
                    Spacer()
                    Button {
                        selectedHighlight = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(radius: 4)
                    }
                    .padding(BSCSpacing.md)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Flow Layout

/// Simple horizontal wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return ArrangeResult(
            positions: positions,
            sizes: sizes,
            size: CGSize(width: maxWidth, height: y + rowHeight)
        )
    }

    private struct ArrangeResult {
        let positions: [CGPoint]
        let sizes: [CGSize]
        let size: CGSize
    }
}
