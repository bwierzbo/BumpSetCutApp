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
                ProgressView()
                    .tint(.bscOrange)
            } else if viewModel.users.isEmpty {
                Text("No \(viewModel.title.lowercased()) yet")
                    .font(.system(size: 15))
                    .foregroundColor(.bscTextSecondary)
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

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.bscTextTertiary)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
    }
}
