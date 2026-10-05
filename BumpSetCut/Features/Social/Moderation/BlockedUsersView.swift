//
//  BlockedUsersView.swift
//  BumpSetCut
//
//  Settings screen for reviewing and undoing user blocks — without this,
//  unblocking would be impossible in the app.
//

import SwiftUI

struct BlockedUsersView: View {
    @State private var viewModel = BlockedUsersViewModel()
    /// The person an unblock failed for; drives the failure alert.
    @State private var failureToast: BSCToastMessage?

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
            } else if viewModel.loadFailed {
                BSCEmptyState.loadFailed(message: nil) {
                    Task { await viewModel.load() }
                }
            } else if viewModel.profiles.isEmpty {
                BSCEmptyState(
                    icon: "hand.raised",
                    title: "No Blocked Users",
                    message: "People you block will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: BSCSpacing.sm) {
                        ForEach(viewModel.profiles, id: \.id) { profile in
                            blockedRow(profile)
                        }
                    }
                    .padding(BSCSpacing.lg)
                }
            }
        }
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .bscToast($failureToast)
        .task {
            await viewModel.load()
        }
    }

    private func blockedRow(_ profile: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.md) {
            AvatarView(url: profile.avatarURL, name: profile.username, size: 40)

            Text("@\(profile.username)")
                .bscFont(size: 16, weight: .medium)
                .foregroundColor(.bscTextPrimary)

            Spacer()

            BSCButton(title: "Unblock", style: .secondary, size: .small) {
                Task {
                    if await !viewModel.unblock(profile) {
                        failureToast = BSCToastMessage(text: "Couldn't unblock @\(profile.username). Check your connection.", style: .error)
                    }
                }
            }
        }
        .padding(BSCSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .fill(Color.bscSurfaceGlass)
        )
    }

}
