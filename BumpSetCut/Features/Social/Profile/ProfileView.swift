//
//  ProfileView.swift
//  BumpSetCut
//
//  User profile showing stats, highlights grid, and follow button.
//

import SwiftUI

struct ProfileView: View {
    @State private var viewModel: ProfileViewModel
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private func profileHeader(_ profile: UserProfile) -> some View {
        VStack(spacing: BSCSpacing.sm) {
            // Avatar
            Circle()
                .fill(Color.bscSurfaceGlass)
                .frame(width: 80, height: 80)
                .overlay(
                    Text(profile.displayName.prefix(1).uppercased())
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.bscOrange)
                )

            Text(profile.displayName)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.bscTextPrimary)

            Text("@\(profile.username)")
                .font(.system(size: 14))
                .foregroundColor(.bscTextSecondary)

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
            statItem(count: profile.followersCount, label: "Followers")
            Divider().frame(height: 30)
            statItem(count: profile.followingCount, label: "Following")
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
            } else {
                Button {
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(viewModel.highlights) { highlight in
                AsyncImage(url: highlight.thumbnailImageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.bscSurfaceGlass
                }
                .frame(minHeight: 120)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                        Text("\(highlight.likesCount)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(4)
                }
            }
        }
        .padding(.horizontal, 2)
    }
}
