//
//  NotificationCenterView.swift
//  BumpSetCut
//
//  The bell sheet: likes, comments, and follows on your posts. Opening it
//  marks everything read (clearing the Home badge); rows navigate to the
//  actor's profile (follows) or the highlight (likes/comments).
//

import SwiftUI

struct NotificationCenterView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = NotificationsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.notifications.isEmpty && viewModel.isLoading {
                    ProgressView()
                        .tint(.bscPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.notifications.isEmpty {
                    BSCEmptyState(
                        icon: viewModel.loadFailed ? "wifi.slash" : "bell",
                        title: viewModel.loadFailed ? "Couldn't Load" : "No Notifications Yet",
                        message: viewModel.loadFailed
                            ? "Check your connection and pull to refresh."
                            : "Likes, comments, and new followers on your posts show up here."
                    )
                } else {
                    notificationList
                }
            }
            .background(Color.bscBackground)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.bscTextSecondary)
                        .accessibilityIdentifier(AccessibilityID.Notifications.done)
                }
            }
            .navigationDestination(for: String.self) { userId in
                ProfileView(userId: userId)
            }
        }
        .task { await viewModel.loadInitial() }
        .refreshable { await viewModel.loadInitial() }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.openedHighlight != nil },
            set: { if !$0 { viewModel.openedHighlight = nil } }
        )) {
            if let highlight = viewModel.openedHighlight {
                ProfileHighlightFeedView(
                    highlights: [highlight],
                    startIndex: 0,
                    isOwnProfile: false,
                    onLike: { _ in },
                    onDelete: nil,
                    onDismiss: { viewModel.openedHighlight = nil }
                )
            }
        }
    }

    private var notificationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.notifications) { notification in
                    row(notification)
                    Divider()
                        .overlay(Color.bscSurfaceBorder)
                        .padding(.leading, BSCSpacing.lg + 44 + BSCSpacing.md)
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
        .accessibilityIdentifier(AccessibilityID.Notifications.list)
    }

    @ViewBuilder
    private func row(_ notification: SocialNotification) -> some View {
        if notification.kind == .follow {
            NavigationLink(value: notification.actorId) {
                rowContent(notification)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await viewModel.openHighlight(for: notification) }
            } label: {
                rowContent(notification)
            }
            .buttonStyle(.plain)
        }
    }

    private func rowContent(_ notification: SocialNotification) -> some View {
        HStack(spacing: BSCSpacing.md) {
            AvatarView(
                url: notification.actor?.avatarURL,
                name: notification.actor?.username ?? "?",
                size: 44
            )

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                (Text(notification.actor?.username ?? "Someone")
                    .fontWeight(.semibold)
                 + Text(" \(notification.message)"))
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextPrimary)
                    .multilineTextAlignment(.leading)

                Text(notification.createdAt.formatted(.relative(presentation: .named)))
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }

            Spacer()

            Image(systemName: notification.iconName)
                .bscFont(size: 14)
                .foregroundColor(notification.kind == .follow ? .bscPrimary : .bscTextSecondary)

            if !notification.isRead {
                Circle()
                    .fill(Color.bscPrimary)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
        .contentShape(Rectangle())
    }
}
