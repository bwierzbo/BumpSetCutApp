//
//  ProfileView.swift
//  BumpSetCut
//
//  User profile showing stats, highlights grid, and follow button.
//

import SwiftUI

struct ProfileView: View {
    @State private var viewModel: ProfileViewModel
    @State private var selectedHighlightIndex: Int?
    @State private var highlightToDelete: Highlight?
    @State private var showReportSheet = false
    @State private var showBlockAlert = false
    @State private var showingSettings = false
    @State private var showingEditProfile = false
    @State private var toast: BSCToastMessage?
    @Environment(AuthenticationService.self) private var authService
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppNavigationState.self) private var navigationState
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
                loadingSkeleton
            } else if let profile = viewModel.profile {
                ScrollView {
                    VStack(spacing: BSCSpacing.lg) {
                        profileHeader(profile)
                        statsRow(profile)
                        actionButtons(profile)
                        PlayerInfoCard(
                            state: viewModel.playerInfoState(isOwnProfile: isOwnProfile),
                            isOwnProfile: isOwnProfile,
                            onAddTapped: { showingEditProfile = true }
                        )
                        .padding(.horizontal, BSCSpacing.lg)
                        highlightsGrid
                    }
                    .padding(.top, BSCSpacing.md)
                }
                .refreshable {
                    await viewModel.loadProfile()
                }
            } else if viewModel.error != nil {
                BSCEmptyState.loadFailed(message: viewModel.error?.localizedDescription) {
                    Task { await viewModel.loadProfile() }
                }
            }

        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // "Add your player info" pushes the same editor as the Edit Profile pill.
        .navigationDestination(isPresented: $showingEditProfile) {
            EditProfileView(onSaved: {
                Task { await viewModel.loadProfile() }
            })
        }
        .bscToast($toast)
        .onChange(of: viewModel.actionError) { _, message in
            if let message {
                toast = BSCToastMessage(text: message, style: .error)
                viewModel.actionError = nil
            }
        }
        .task {
            // Load once per instance. Avoids re-fetching (and scrolling the grid
            // back to top) when the profile tab reappears after a tab switch.
            // Pull-to-refresh still forces a reload.
            if viewModel.highlights.isEmpty {
                await viewModel.loadProfile()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedHighlightIndex != nil },
            set: { if !$0 { selectedHighlightIndex = nil } }
        )) {
            if let index = selectedHighlightIndex {
                ProfileHighlightFeedView(
                    highlights: viewModel.highlights,
                    startIndex: index,
                    isOwnProfile: isOwnProfile,
                    onLike: { highlight in
                        Task { await viewModel.toggleLike(for: highlight) }
                    },
                    onDelete: isOwnProfile ? { highlight in
                        selectedHighlightIndex = nil
                        Task {
                            let deleted = await viewModel.deleteHighlight(highlight)
                            if !deleted {
                                toast = BSCToastMessage(text: "Couldn't delete post", style: .error)
                            }
                        }
                    } : nil,
                    onDismiss: { selectedHighlightIndex = nil }
                )
            }
        }
        .alert("Delete Post?", isPresented: Binding(
            get: { highlightToDelete != nil },
            set: { if !$0 { highlightToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { highlightToDelete = nil }
            Button("Delete", role: .destructive) {
                if let highlight = highlightToDelete {
                    Task {
                        let deleted = await viewModel.deleteHighlight(highlight)
                        if !deleted {
                            toast = BSCToastMessage(text: "Couldn't delete post", style: .error)
                        }
                    }
                    highlightToDelete = nil
                }
            }
        } message: {
            Text("This post will be permanently removed.")
        }
        .toolbar {
            if isOwnProfile {
                ToolbarItem(placement: .navigationBarTrailing) {
                    BSCIconButton(icon: "gearshape.fill", style: .glass, size: .compact) {
                        showingSettings = true
                    }
                    .accessibilityLabel("Settings")
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showReportSheet = true
                        } label: {
                            Label("Report User", systemImage: "exclamationmark.triangle")
                        }
                        Button(role: .destructive) {
                            showBlockAlert = true
                        } label: {
                            Label("Block @\(viewModel.profile?.username ?? "user")", systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .bscFont(size: 16, weight: .medium)
                            .foregroundColor(.bscTextSecondary)
                            .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environment(appSettings)
        }
        .sheet(isPresented: $showReportSheet) {
            ReportContentSheet(
                contentType: .userProfile,
                contentId: UUID(uuidString: viewModel.userId) ?? UUID(),
                reportedUserId: UUID(uuidString: viewModel.userId) ?? UUID()
            )
        }
        .alert("Block @\(viewModel.profile?.username ?? "user")?", isPresented: $showBlockAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                guard let userId = UUID(uuidString: viewModel.userId) else { return }
                Task {
                    try? await ModerationService.shared.blockUser(userId)
                    dismiss()
                }
            }
        } message: {
            Text("You won't see their posts or comments, and they won't be able to see yours.")
        }
    }

    // MARK: - Message Button

    /// Opens (or starts) a thread with this person. The inbox owns thread
    /// navigation, so route through it rather than pushing a thread into
    /// whichever stack this profile happens to be in.
    private var messageButton: some View {
        Button {
            UIImpactFeedbackGenerator.light()
            navigationState.pendingMessageRecipientId = viewModel.userId
            dismiss()
        } label: {
            Label("Message", systemImage: "bubble.left")
                .bscFont(size: 14, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BSCSpacing.sm)
                .background(Color.bscSurfaceGlass)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Profile.messageButton)
    }

    // MARK: - Header

    private func profileHeader(_ profile: UserProfile) -> some View {
        VStack(spacing: BSCSpacing.sm) {
            // Avatar
            AvatarView(url: profile.avatarURL, name: profile.username, size: 80)

            Text(profile.username)
                .bscFont(size: 20, weight: .bold)
                .foregroundColor(.bscTextPrimary)
                .accessibilityIdentifier(AccessibilityID.Profile.username)
                .onLongPressGesture {
                    UIPasteboard.general.string = profile.username
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    toast = BSCToastMessage(text: "Copied!", style: .success)
                }

            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, BSCSpacing.xl)
                    .accessibilityIdentifier(AccessibilityID.Profile.bio)
            }

            if let team = profile.teamName, !team.isEmpty {
                Label(team, systemImage: "person.3")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }
        }
    }

    // MARK: - Stats

    private func statsRow(_ profile: UserProfile) -> some View {
        HStack(spacing: 0) {
            statItem(count: profile.highlightsCount, label: "Highlights")
                .accessibilityIdentifier(AccessibilityID.Profile.highlightsCount)
            Divider().frame(height: 30)
            NavigationLink {
                FollowListView(userId: viewModel.userId, mode: .followers)
            } label: {
                statItem(count: profile.followersCount, label: "Followers")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Profile.followersCount)
            Divider().frame(height: 30)
            NavigationLink {
                FollowListView(userId: viewModel.userId, mode: .following)
            } label: {
                statItem(count: profile.followingCount, label: "Following")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Profile.followingCount)
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    private func statItem(count: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .bscFont(size: 18, weight: .bold)
                .foregroundColor(.bscTextPrimary)
            Text(label)
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func actionButtons(_ profile: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            if isOwnProfile {
                NavigationLink {
                    EditProfileView(onSaved: {
                        Task { await viewModel.loadProfile() }
                    })
                } label: {
                    Text("Edit Profile")
                        .bscFont(size: 14, weight: .semibold)
                        .foregroundColor(.bscTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BSCSpacing.sm)
                        .background(Color.bscSurfaceGlass)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                        )
                }
                .accessibilityIdentifier(AccessibilityID.Profile.editProfileButton)
            } else {
                messageButton
                Button {
                    UIImpactFeedbackGenerator.light()
                    Task {
                        let wasFollowing = viewModel.isFollowing
                        let succeeded = await viewModel.toggleFollow()
                        if succeeded && !wasFollowing {
                            UINotificationFeedbackGenerator.success()
                        }
                    }
                } label: {
                    Text(viewModel.isFollowing ? "Following" : "Follow")
                        .bscFont(size: 14, weight: .semibold)
                        .foregroundColor(viewModel.isFollowing ? .bscTextPrimary : .bscOnPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BSCSpacing.sm)
                        .background(viewModel.isFollowing ? Color.bscSurfaceGlass : Color.bscPrimaryFill)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                }
                .accessibilityIdentifier(AccessibilityID.Profile.followButton)
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Loading Skeleton

    /// Placeholder mirroring the loaded layout: avatar, name, stats row, grid.
    private var loadingSkeleton: some View {
        ScrollView {
            VStack(spacing: BSCSpacing.lg) {
                VStack(spacing: BSCSpacing.sm) {
                    BSCSkeletonView()
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                    BSCSkeletonView()
                        .frame(width: 140, height: 18)
                        .clipShape(Capsule())
                }

                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: BSCSpacing.xs) {
                            BSCSkeletonView()
                                .frame(width: 32, height: 16)
                                .clipShape(Capsule())
                            BSCSkeletonView()
                                .frame(width: 64, height: 10)
                                .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, BSCSpacing.lg)

                gridSkeleton
            }
            .padding(.top, BSCSpacing.md)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading profile")
    }

    private var gridSkeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.xs), count: 3), spacing: BSCSpacing.xs) {
            ForEach(0..<9, id: \.self) { _ in
                BSCSkeletonView()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
            }
        }
        .padding(.horizontal, BSCSpacing.xs)
    }

    // MARK: - Highlights Grid

    private var highlightsGrid: some View {
        Group {
            if viewModel.isLoading && viewModel.highlights.isEmpty {
                gridSkeleton
            } else if viewModel.highlights.isEmpty {
                // Empty state
                BSCEmptyState.noUserHighlights(isOwnProfile: isOwnProfile)
                    .padding(.top, BSCSpacing.xxl)
            } else {
                // Content
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.xs), count: 3), spacing: BSCSpacing.xs) {
                    ForEach(Array(viewModel.highlights.enumerated()), id: \.element.id) { index, highlight in
                        Button {
                            selectedHighlightIndex = index
                        } label: {
                            profileGridCell(highlight)
                        }
                        .buttonStyle(.plain)
                        // Press and hold to delete — no permanent chrome over
                        // every thumbnail. The alert below still confirms.
                        .contextMenu {
                            if isOwnProfile {
                                Button(role: .destructive) {
                                    highlightToDelete = highlight
                                } label: {
                                    Label("Delete Post", systemImage: "trash")
                                }
                            }
                        }
                        .accessibilityHint(isOwnProfile ? "Press and hold to delete" : "")
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
                HStack(spacing: BSCSpacing.xs) {
                    if isMulti {
                        Image(systemName: "square.stack.fill")
                            .bscFont(size: 9)
                    }
                    HStack(spacing: BSCSpacing.xxs) {
                        Image(systemName: "heart.fill")
                            .bscFont(size: 9)
                        Text("\(highlight.likesCount)")
                            .bscFont(size: 9, weight: .medium)
                    }
                    HStack(spacing: BSCSpacing.xxs) {
                        Image(systemName: "bubble.right.fill")
                            .bscFont(size: 9)
                        Text("\(highlight.commentsCount)")
                            .bscFont(size: 9, weight: .medium)
                    }
                }
                .foregroundColor(.bscOnMedia)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.bscMediaScrim)
                .clipShape(Capsule())
                .padding(BSCSpacing.xs)

                // Top-right: multi-rally badge
                if isMulti {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "square.stack.fill")
                                .bscFont(size: 12)
                                .foregroundColor(.bscOnMedia)
                                .padding(BSCSpacing.xs)
                                .background(Color.bscMediaScrim, in: Circle())
                                .padding(BSCSpacing.xs)
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
