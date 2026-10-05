//
//  NotificationCenterView.swift
//  BumpSetCut
//
//  The bell sheet: likes, comments, and follows on your posts. Opening it
//  marks everything read (clearing the Home badge). On every row the avatar
//  and username open the actor's profile; the rest of a like/comment row
//  opens the post, and a follow row opens the profile too.
//

import SwiftUI

struct NotificationCenterView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = NotificationsViewModel()
    // Qualified: the app declares its own NavigationPath type.
    @State private var path = SwiftUI.NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if viewModel.notifications.isEmpty && viewModel.isLoading {
                    ProgressView()
                        .tint(.bscPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.notifications.isEmpty {
                    // In a ScrollView so pull-to-refresh works from here too.
                    ScrollView {
                        Group {
                            if viewModel.loadFailed {
                                BSCEmptyState.loadFailed { Task { await viewModel.loadInitial() } }
                            } else {
                                BSCEmptyState(
                                    icon: "bell",
                                    title: "No Notifications Yet",
                                    message: "Likes, comments, and new followers on your posts show up here."
                                )
                            }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else {
                    notificationList
                }
            }
            .refreshable { await viewModel.loadInitial() }
            .background(Color.bscBackground)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.Notifications.done)
                }
            }
            .profileNavigationDestinations()
        }
        .task { await viewModel.loadInitial() }
        .fullScreenCover(item: $viewModel.openedHighlight) { highlight in
            HighlightDetailCover(highlight: highlight) { viewModel.openedHighlight = nil }
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

    private func openProfile(_ notification: SocialNotification) {
        path.append(notification.actorId)
    }

    /// Whole-row tap: the post for likes/comments, the profile for follows.
    private func row(_ notification: SocialNotification) -> some View {
        Button {
            if notification.kind == .follow {
                openProfile(notification)
            } else {
                Task { await viewModel.openHighlight(for: notification) }
            }
        } label: {
            rowContent(notification)
        }
        .buttonStyle(.plain)
        // One element reading as a sentence ("Sam liked your rally, 2 hours
        // ago"); the avatar/username shortcut becomes a named action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySentence(notification))
        .accessibilityValue(notification.isRead ? "" : "Unread")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "View profile") {
            openProfile(notification)
        }
    }

    private func accessibilitySentence(_ notification: SocialNotification) -> String {
        let username = notification.actor?.username ?? "Someone"
        let when = notification.createdAt.formatted(.relative(presentation: .named))
        return "\(username) \(notification.message), \(when)"
    }

    private func rowContent(_ notification: SocialNotification) -> some View {
        let username = notification.actor?.username ?? "Someone"
        return HStack(spacing: BSCSpacing.md) {
            // Avatar and username are their own targets so a like/comment row
            // can still reach the person, not just the post.
            Button {
                openProfile(notification)
            } label: {
                AvatarView(
                    url: notification.actor?.avatarURL,
                    name: notification.actor?.username ?? "?",
                    size: 44
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Button {
                    openProfile(notification)
                } label: {
                    Text(username)
                        .bscFont(size: 15, weight: .semibold)
                        .foregroundColor(.bscTextPrimary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Text("\(notification.message) · \(notification.createdAt.formatted(.relative(presentation: .named)))")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: notification.iconName)
                .bscFont(size: 14)
                .foregroundColor(notification.kind == .follow ? .bscPrimary : .bscTextSecondary)

            if !notification.isRead {
                Circle()
                    .fill(Color.bscPrimaryFill)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
        .contentShape(Rectangle())
    }
}
