//
//  HighlightDetailCover.swift
//  BumpSetCut
//
//  Full-screen viewer for a single post, used wherever one is opened outside
//  a feed: search results, notifications, deep links, and rallies attached
//  to a message.
//

import SwiftUI

struct HighlightDetailCover: View {
    var onDismiss: () -> Void = {}

    @State private var viewModel: HighlightDetailViewModel
    @State private var comments: Highlight?
    @State private var profile: ProfileID?
    @State private var sendRequest: SendToRequest?
    @State private var toast: BSCToastMessage?
    @Environment(AuthenticationService.self) private var authService
    @Environment(AppNavigationState.self) private var navigationState

    init(highlight: Highlight, onDismiss: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
        _viewModel = State(initialValue: HighlightDetailViewModel(highlight: highlight))
    }

    private var isOwnPost: Bool {
        authService.currentUser?.id == viewModel.highlight.authorId
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HighlightCardView(
                highlight: viewModel.highlight,
                onLike: { Task { await viewModel.toggleLike() } },
                onComment: { comments = viewModel.highlight },
                onProfile: { authorId in profile = ProfileID(id: authorId) },
                onDelete: isOwnPost ? {
                    Task {
                        if await viewModel.delete() { onDismiss() }
                    }
                } : nil,
                onSend: authService.isAuthenticated
                    ? { sendRequest = SendToRequest(highlight: viewModel.highlight) }
                    : nil
            )

            // xs outer padding keeps the icon visually 12pt from the edge
            // (the component's 44pt hit frame supplies the other 8pt).
            BSCMediaCloseButton { onDismiss() }
                .padding(BSCSpacing.xs)
        }
        .commentsPanel(item: $comments)
        .sheet(item: $profile) { profile in
            ProfileSheet(userId: profile.id)
        }
        .sheet(item: $sendRequest) { request in
            SendToSheet(highlight: request.highlight) { conversationId, username in
                toast = .sent(to: username, conversationId: conversationId, navigationState: navigationState)
            }
        }
        .bscToast($toast)
        .onChange(of: viewModel.actionError) { _, message in
            if let message {
                toast = BSCToastMessage(verbatim: message, style: .error)
                viewModel.actionError = nil
            }
        }
        .dismissOnAppNavigation()
    }
}
