//
//  InboxView.swift
//  BumpSetCut
//
//  The envelope sheet: chats, plus requests from people you don't follow.
//

import SwiftUI

struct InboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthenticationService.self) private var authService
    @Environment(AppNavigationState.self) private var navigationState

    @State private var viewModel: InboxViewModel
    @State private var path = SwiftUI.NavigationPath()
    @State private var toast: BSCToastMessage?

    init(currentUserId: String) {
        _viewModel = State(initialValue: InboxViewModel(currentUserId: currentUserId))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    segmentPicker

                    if viewModel.visible.isEmpty && viewModel.isLoading {
                        ProgressView()
                            .tint(.bscPrimary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.visible.isEmpty {
                        emptyState
                    } else {
                        conversationList
                    }
                }
            }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.bscTextSecondary)
                        .accessibilityIdentifier(AccessibilityID.Messages.done)
                }
            }
            .navigationDestination(for: ConversationRoute.self) { route in
                ConversationView(route: route, currentUserId: viewModel.currentUserId)
            }
            .navigationDestination(for: String.self) { userId in
                ProfileView(userId: userId)
            }
        }
        .bscToast($toast)
        .task {
            viewModel.startListening()
            await viewModel.loadInitial()
        }
        .onDisappear { viewModel.stopListening() }
        .refreshable { await viewModel.loadInitial() }
        .onChange(of: viewModel.actionError) { _, message in
            guard let message else { return }
            toast = BSCToastMessage(text: message, style: .error)
            viewModel.actionError = nil
        }
        // A push tap or a "View" toast lands here.
        .onChange(of: navigationState.pendingConversationId, initial: true) { _, id in
            guard let id else { return }
            navigationState.pendingConversationId = nil
            path = SwiftUI.NavigationPath()
            path.append(ConversationRoute(conversationId: id, summary: viewModel.summary(for: id)))
        }
        .onChange(of: navigationState.pendingMessageRecipientId, initial: true) { _, userId in
            guard let userId else { return }
            navigationState.pendingMessageRecipientId = nil
            Task {
                if let route = await viewModel.openThread(with: userId) {
                    path = SwiftUI.NavigationPath()
                    path.append(route)
                }
            }
        }
        // Coming back from a thread: its rows are read now.
        .onChange(of: path.count) { oldValue, newValue in
            guard newValue < oldValue else { return }
            Task { await DirectMessageService.shared.refreshCounts() }
        }
    }

    // MARK: - Segments

    private var segmentPicker: some View {
        HStack(spacing: BSCSpacing.sm) {
            segmentButton(
                title: "Chats",
                segment: .chats,
                identifier: AccessibilityID.Messages.segmentChats
            )
            segmentButton(
                title: DirectMessageService.shared.pendingRequestCount > 0
                    ? "Requests (\(DirectMessageService.shared.pendingRequestCount))"
                    : "Requests",
                segment: .requests,
                identifier: AccessibilityID.Messages.segmentRequests
            )
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.sm)
    }

    private func segmentButton(title: String, segment: InboxViewModel.Segment, identifier: String) -> some View {
        let isSelected = viewModel.segment == segment
        return Button {
            withAnimation(.bscQuick) { viewModel.segment = segment }
        } label: {
            Text(title)
                .bscFont(size: 14, weight: isSelected ? .semibold : .medium)
                .foregroundColor(isSelected ? .bscOnPrimary : .bscTextSecondary)
                .frame(maxWidth: .infinity, minHeight: BSCTouchTarget.standard)
                .background(
                    Capsule().fill(isSelected ? Color.bscPrimaryFill : Color.bscSurfaceGlass)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - List

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.visible) { summary in
                    conversationRow(summary)
                    Divider()
                        .overlay(Color.bscSurfaceBorder)
                        .padding(.leading, BSCSpacing.lg + 48 + BSCSpacing.md)
                }

                if viewModel.hasMore {
                    ProgressView()
                        .tint(.bscPrimary)
                        .padding()
                        .onAppear { Task { await viewModel.loadMore() } }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Messages.list)
    }

    private func conversationRow(_ summary: ConversationSummary) -> some View {
        Button {
            viewModel.markLocallyRead(summary.id)
            path.append(ConversationRoute(conversationId: summary.id, summary: summary))
        } label: {
            VStack(spacing: BSCSpacing.sm) {
                HStack(spacing: BSCSpacing.md) {
                    AvatarView(url: summary.otherAvatarURL, name: summary.otherUsername, size: 48)

                    VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                        Text(summary.otherUsername)
                            .bscFont(size: 15, weight: summary.unreadCount > 0 ? .bold : .semibold)
                            .foregroundColor(.bscTextPrimary)

                        Text(viewModel.previewText(for: summary))
                            .bscFont(size: 13)
                            .foregroundColor(summary.unreadCount > 0 ? .bscTextPrimary : .bscTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: BSCSpacing.sm)

                    VStack(alignment: .trailing, spacing: BSCSpacing.xxs) {
                        if let date = summary.lastMessageAt {
                            Text(date.formatted(.relative(presentation: .named)))
                                .bscFont(size: 11)
                                .foregroundColor(.bscTextSecondary)
                        }
                        if summary.unreadCount > 0 {
                            Text("\(summary.unreadCount)")
                                .bscFont(size: 11, weight: .bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Color.bscPrimary))
                        }
                    }
                }

                if summary.isRequest {
                    requestActions(summary)
                }
            }
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Messages.row)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(summary.otherUsername), \(viewModel.previewText(for: summary))"
            + (summary.unreadCount > 0 ? ", \(summary.unreadCount) unread" : "")
        )
        .contextMenu {
            Button(role: .destructive) {
                Task { await viewModel.leave(summary) }
            } label: {
                Label(summary.isRequest ? "Delete Request" : "Leave Conversation", systemImage: "trash")
            }
        }
    }

    private func requestActions(_ summary: ConversationSummary) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            Button {
                Task { await viewModel.accept(summary) }
            } label: {
                Text("Accept")
                    .bscFont(size: 13, weight: .semibold)
                    .foregroundColor(.bscOnPrimary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Capsule().fill(Color.bscPrimaryFill))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Messages.acceptRequest)

            Button {
                Task { await viewModel.leave(summary) }
            } label: {
                Text("Delete")
                    .bscFont(size: 13, weight: .semibold)
                    .foregroundColor(.bscTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Capsule().fill(Color.bscSurfaceGlass))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Messages.deleteRequest)
        }
        .padding(.leading, 48 + BSCSpacing.md)
    }

    // MARK: - Empty

    private var emptyState: some View {
        Group {
            if viewModel.loadFailed {
                BSCEmptyState.loadFailed(message: nil) {
                    Task { await viewModel.loadInitial() }
                }
            } else if viewModel.segment == .chats {
                BSCEmptyState(
                    icon: "envelope",
                    title: "No Messages Yet",
                    message: "Send a rally to a teammate from any post, your library, or their profile."
                )
            } else {
                BSCEmptyState(
                    icon: "tray",
                    title: "No Requests",
                    message: "Messages from people you don't follow land here first."
                )
            }
        }
        .accessibilityIdentifier(AccessibilityID.Messages.emptyState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
