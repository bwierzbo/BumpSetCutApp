//
//  FollowListView.swift
//  BumpSetCut
//
//  Paginated list of followers or following users with navigation to profiles.
//

import SwiftUI

struct FollowListView: View {
    @State private var viewModel: FollowListViewModel

    init(userId: String, mode: FollowListMode) {
        _viewModel = State(initialValue: FollowListViewModel(userId: userId, mode: mode))
    }

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.users.isEmpty {
                // Skeleton loaders
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { _ in
                            HStack(spacing: BSCSpacing.md) {
                                BSCSkeletonView()
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    BSCSkeletonView()
                                        .frame(width: 120, height: 14)
                                        .clipShape(Capsule())
                                }

                                Spacer()
                            }
                            .padding(.horizontal, BSCSpacing.lg)
                            .padding(.vertical, BSCSpacing.md)
                        }
                    }
                }
            } else if viewModel.users.isEmpty {
                // Empty state
                Group {
                    switch viewModel.mode {
                    case .followers:
                        BSCEmptyState.noFollowers()
                    case .following:
                        BSCEmptyState.noFollowing {
                            // Navigate to search/discover
                        }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
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
                .navigationDestination(for: String.self) { userId in
                    ProfileView(userId: userId)
                }
            }
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadInitial()
        }
    }

    private func userRow(_ user: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.md) {
            AvatarView(url: user.avatarURL, name: user.username, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.username)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.bscTextPrimary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.bscTextTertiary)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
    }
}
