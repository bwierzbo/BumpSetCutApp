//
//  FollowListView.swift
//  BumpSetCut
//
//  Paginated list of followers or following users with navigation to profiles.
//

import SwiftUI

/// Registers every destination the profile stack can push. Apply once to the
/// root of each NavigationStack that can show a ProfileView — the profile is
/// reachable from five separate stacks, and a stack missing a registration
/// silently ignores the links instead of failing.
extension View {
    func profileNavigationDestinations() -> some View {
        self
            .navigationDestination(for: String.self) { userId in
                ProfileView(userId: userId)
            }
            .navigationDestination(for: FollowListRoute.self) { route in
                FollowListView(userId: route.userId, mode: route.mode)
            }
    }
}

struct FollowListView: View {
    @State private var viewModel: FollowListViewModel
    @Environment(\.changeTab) private var changeTab

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

                                VStack(alignment: .leading, spacing: BSCSpacing.xs) {
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
                // In a ScrollView so pull-to-refresh works on these too.
                ScrollView {
                    Group {
                        if viewModel.loadFailed {
                            BSCEmptyState.loadFailed {
                                Task { await viewModel.loadInitial() }
                            }
                        } else {
                            switch viewModel.mode {
                            case .followers:
                                BSCEmptyState.noFollowers()
                            case .following:
                                BSCEmptyState.noFollowing {
                                    changeTab(.search)
                                }
                            }
                        }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
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
                                .tint(.bscPrimary)
                                .padding()
                                .onAppear {
                                    Task { await viewModel.loadMore() }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.loadInitial()
        }
        .task {
            await viewModel.loadInitial()
        }
    }

    private func userRow(_ user: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.md) {
            AvatarView(url: user.avatarURL, name: user.username, size: 44)

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(user.username)
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
            }

            Spacer()

            Image(systemName: "chevron.forward")
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
        // Without this only the avatar, the name and the chevron are tappable —
        // the Spacer between them is the widest part of the row and swallowed
        // every tap that landed in it.
        .contentShape(Rectangle())
    }
}
