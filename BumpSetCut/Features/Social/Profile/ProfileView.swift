//
//  ProfileView.swift
//  BumpSetCut
//
//  User profile showing stats, highlights grid, and follow button.
//

import SwiftUI

struct ProfileView: View {
    @State private var viewModel: ProfileViewModel
    @State private var selectedHighlight: Highlight?
    @State private var selectedHighlightForComments: Highlight?
    @State private var highlightToDelete: Highlight?
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    init(userId: String) {
        _viewModel = State(initialValue: ProfileViewModel(userId: userId))
    }

    private var isOwnProfile: Bool {
        authService.currentUser?.id == viewModel.userId
    }

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.profile == nil {
                ProgressView()
                    .tint(.bscOrange)
            } else if let profile = viewModel.profile {
                ScrollView {
                    VStack(spacing: BSCSpacing.lg) {
                        profileHeader(profile)
                        statsRow(profile)
                        actionButtons(profile)
                        highlightsGrid
                    }
                    .padding(.top, BSCSpacing.md)
                }
            }
        }
        .navigationTitle(viewModel.profile?.username ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadProfile()
        }
        .fullScreenCover(item: $selectedHighlight) { highlight in
            highlightDetail(highlight)
        }
        .sheet(item: $selectedHighlightForComments) { highlight in
            CommentsSheet(highlight: highlight)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Sign Out?", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                authService.signOut()
                dismiss()
            }
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert("Delete Post?", isPresented: Binding(
            get: { highlightToDelete != nil },
            set: { if !$0 { highlightToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { highlightToDelete = nil }
            Button("Delete", role: .destructive) {
                if let highlight = highlightToDelete {
                    Task { await viewModel.deleteHighlight(highlight) }
                    highlightToDelete = nil
                }
            }
        } message: {
            Text("This post will be permanently removed.")
        }
    }

    // MARK: - Highlight Detail

    private func highlightDetail(_ highlight: Highlight) -> some View {
        ZStack {
            HighlightCardView(
                highlight: highlight,
                onLike: {
                    Task { await viewModel.toggleLike(for: highlight) }
                },
                onComment: {
                    selectedHighlight = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        selectedHighlightForComments = highlight
                    }
                },
                onProfile: { _ in },
                onDelete: isOwnProfile ? {
                    selectedHighlight = nil
                    Task { await viewModel.deleteHighlight(highlight) }
                } : nil
            )

            // Close button
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

    // MARK: - Header

    private func profileHeader(_ profile: UserProfile) -> some View {
        VStack(spacing: BSCSpacing.sm) {
            // Avatar
            AvatarView(url: profile.avatarURL, name: profile.username, size: 80)

            Text(profile.username)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.bscTextPrimary)

            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, BSCSpacing.xl)
            }

            if let team = profile.teamName, !team.isEmpty {
                Label(team, systemImage: "person.3")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextTertiary)
            }
        }
    }

    // MARK: - Stats

    private func statsRow(_ profile: UserProfile) -> some View {
        HStack(spacing: 0) {
            statItem(count: profile.highlightsCount, label: "Highlights")
            Divider().frame(height: 30)
            NavigationLink {
                FollowListView(userId: viewModel.userId, mode: .followers)
            } label: {
                statItem(count: profile.followersCount, label: "Followers")
            }
            .buttonStyle(.plain)
            Divider().frame(height: 30)
            NavigationLink {
                FollowListView(userId: viewModel.userId, mode: .following)
            } label: {
                statItem(count: profile.followingCount, label: "Following")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    private func statItem(count: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.bscTextPrimary)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.bscTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    @State private var showSignOutConfirmation = false

    private func actionButtons(_ profile: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            if isOwnProfile {
                NavigationLink {
                    EditProfileView()
                } label: {
                    Text("Edit Profile")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.bscTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BSCSpacing.sm)
                        .background(Color.bscSurfaceGlass)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                }

                Button {
                    showSignOutConfirmation = true
                } label: {
                    Text("Sign Out")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.vertical, BSCSpacing.sm)
                        .padding(.horizontal, BSCSpacing.md)
                        .background(Color.bscSurfaceGlass)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                }
            } else {
                Button {
                    UINotificationFeedbackGenerator.success()
                    Task { await viewModel.toggleFollow() }
                } label: {
                    Text(viewModel.isFollowing ? "Following" : "Follow")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(viewModel.isFollowing ? .bscTextPrimary : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BSCSpacing.sm)
                        .background(viewModel.isFollowing ? Color.bscSurfaceGlass : Color.bscOrange)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                }
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Highlights Grid

    private var highlightsGrid: some View {
        Group {
            if viewModel.isLoading && viewModel.highlights.isEmpty {
                // Skeleton loaders
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.xs), count: 3), spacing: BSCSpacing.xs) {
                    ForEach(0..<9, id: \.self) { _ in
                        BSCSkeletonView()
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
                    }
                }
                .padding(.horizontal, BSCSpacing.xs)
            } else if viewModel.highlights.isEmpty {
                // Empty state
                BSCEmptyState.noUserHighlights(isOwnProfile: isOwnProfile)
                    .padding(.top, BSCSpacing.xxl)
            } else {
                // Content
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.xs), count: 3), spacing: BSCSpacing.xs) {
                    ForEach(viewModel.highlights) { highlight in
                        Button {
                            selectedHighlight = highlight
                        } label: {
                            profileGridCell(highlight)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if isOwnProfile {
                                Button(role: .destructive) {
                                    highlightToDelete = highlight
                                } label: {
                                    Label("Delete Post", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, BSCSpacing.xs)
            }
        }
    }

    private func profileGridCell(_ highlight: Highlight) -> some View {
        let isMulti = highlight.allVideoURLs.count > 1

        return GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Always show first video thumbnail
                VideoThumbnailView(
                    thumbnailURL: highlight.thumbnailImageURL,
                    videoURL: highlight.allVideoURLs.first ?? highlight.videoURL
                )
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()

                // Bottom-left: stats overlay
                HStack(spacing: 4) {
                    if isMulti {
                        Image(systemName: "square.stack.fill")
                            .font(.system(size: 9))
                    }
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

                // Top-right: multi-rally badge
                if isMulti {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "square.stack.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
        .contentShape(Rectangle())
    }
}
