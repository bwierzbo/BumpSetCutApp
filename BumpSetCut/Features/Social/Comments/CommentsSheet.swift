//
//  CommentsSheet.swift
//  BumpSetCut
//
//  Bottom sheet showing comments for a highlight.
//

import SwiftUI

struct CommentsSheet: View {
    let highlight: Highlight
    var onClose: () -> Void = {}
    var onHeaderDrag: (CGFloat) -> Void = { _ in }
    var onHeaderDragEnd: (CGFloat) -> Void = { _ in }
    @State private var viewModel: CommentsViewModel
    @State private var toast: BSCToastMessage?
    @FocusState private var isCommentFocused: Bool
    @Environment(AuthenticationService.self) private var authService

    init(highlight: Highlight,
         onClose: @escaping () -> Void = {},
         onHeaderDrag: @escaping (CGFloat) -> Void = { _ in },
         onHeaderDragEnd: @escaping (CGFloat) -> Void = { _ in }) {
        self.onClose = onClose
        self.onHeaderDrag = onHeaderDrag
        self.onHeaderDragEnd = onHeaderDragEnd
        self.highlight = highlight
        _viewModel = State(initialValue: CommentsViewModel(highlight: highlight))
    }

    var body: some View {
            VStack(spacing: 0) {
                panelHeader

                // Pinned poll (when this post has one)
                if let poll = viewModel.poll {
                    PollView(
                        poll: poll,
                        isAuthenticated: authService.isAuthenticated,
                        onVote: { optionId in
                            Task { await viewModel.votePoll(optionId: optionId) }
                        }
                    )
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.top, BSCSpacing.md)
                    .padding(.bottom, BSCSpacing.sm)
                    Divider()
                }

                // Comments list
                if viewModel.isLoading && viewModel.comments.isEmpty {
                    loadingSkeleton
                } else if viewModel.comments.isEmpty && viewModel.loadError != nil {
                    Spacer()
                    BSCEmptyState.loadFailed(message: viewModel.loadError?.localizedDescription) {
                        Task { await viewModel.loadComments() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Comments.emptyState)
                    Spacer()
                } else if viewModel.visibleComments.isEmpty {
                    Spacer()
                    BSCEmptyState(
                        icon: "bubble.right",
                        title: "No comments yet",
                        message: "Be the first to comment!"
                    )
                    .accessibilityIdentifier(AccessibilityID.Comments.emptyState)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: BSCSpacing.md) {
                            ForEach(viewModel.visibleComments) { comment in
                                commentRow(comment)
                            }
                        }
                        .padding(BSCSpacing.md)
                    }
                }

                Divider()

                // Send-error banner (transient — clears on next send attempt)
                if viewModel.sendError != nil {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .bscFont(size: 11)
                            .foregroundColor(.bscErrorText)
                        Text("Couldn't send comment. Try again.")
                            .bscFont(size: 12)
                            .foregroundColor(.bscErrorText)
                        Spacer()
                    }
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.xs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Input bar
                inputBar
            }
            .animation(.bscQuick, value: viewModel.sendError != nil)
            .background(Color.bscBackground)
            .bscToast($toast)
            .onChange(of: viewModel.actionError) { _, message in
                if let message {
                    toast = BSCToastMessage(text: message, style: .error)
                    viewModel.actionError = nil
                }
            }
            .task {
                // Poll vote and comments are independent — load them concurrently.
                async let pollVote: Void = viewModel.loadMyPollVote()
                async let comments: Void = viewModel.loadComments()
                _ = await (pollVote, comments)
            }
    }

    // MARK: - Loading Skeleton

    private var loadingSkeleton: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BSCSpacing.md) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(alignment: .top, spacing: BSCSpacing.sm) {
                        BSCSkeletonView()
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                            BSCSkeletonView()
                                .frame(width: 110, height: 12)
                                .clipShape(Capsule())
                            BSCSkeletonView()
                                .frame(width: 210, height: 12)
                                .clipShape(Capsule())
                        }

                        Spacer()
                    }
                }
            }
            .padding(BSCSpacing.md)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading comments")
    }

    // MARK: - Panel Header

    private var panelHeader: some View {
        VStack(spacing: BSCSpacing.sm) {
            BSCSheetGrabber()

            HStack {
                Text("Comments")
                    .bscFont(size: 16, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .bscFont(size: 15, weight: .semibold)
                        .foregroundColor(.bscTextSecondary)
                        .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close comments")
            }
            .padding(.horizontal, BSCSpacing.md)
        }
        .padding(.top, BSCSpacing.sm)
        .padding(.bottom, BSCSpacing.xs)
        // Drag-to-dismiss is confined to the header so it never swallows taps
        // on the poll/comments/input below.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { onHeaderDrag($0.translation.height) }
                .onEnded { onHeaderDragEnd($0.translation.height) }
        )
    }

    // MARK: - Comment Row

    @State private var reportingComment: Comment?
    @State private var blockingComment: Comment?

    private func commentRow(_ comment: Comment) -> some View {
        HStack(alignment: .top, spacing: BSCSpacing.sm) {
            // Avatar
            AvatarView(url: comment.author?.avatarURL, name: comment.author?.username ?? "?", size: 32)

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                HStack(spacing: BSCSpacing.xs) {
                    Text(comment.author?.username ?? "Unknown")
                        .bscFont(size: 13, weight: .semibold)
                        .foregroundColor(.bscTextPrimary)

                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                        .bscFont(size: 11)
                        .foregroundColor(.bscTextSecondary)
                }

                Text(comment.text)
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextPrimary)

                // Like button
                Button {
                    UIImpactFeedbackGenerator.light()
                    Task { await viewModel.toggleCommentLike(comment) }
                } label: {
                    HStack(spacing: BSCSpacing.xxs) {
                        Image(systemName: comment.isLikedByMe ? "heart.fill" : "heart")
                            .bscFont(size: 11)
                            .foregroundColor(comment.isLikedByMe ? .bscError : .bscTextSecondary)
                        if comment.likesCount > 0 {
                            Text("\(comment.likesCount)")
                                .bscFont(size: 11)
                                .foregroundColor(.bscTextSecondary)
                        }
                    }
                    .frame(minWidth: BSCTouchTarget.standard, minHeight: BSCTouchTarget.standard, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(comment.isLikedByMe ? "Unlike comment" : "Like comment")
                .padding(.top, BSCSpacing.xxs)
            }

            Spacer()

            Menu {
                Button {
                    reportingComment = comment
                } label: {
                    Label("Report Comment", systemImage: "exclamationmark.shield")
                }
                Button(role: .destructive) {
                    blockingComment = comment
                } label: {
                    Label("Block @\(comment.author?.username ?? "user")", systemImage: "hand.raised")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .bscFont(size: 13, weight: .semibold)
                    .foregroundColor(.bscTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Comment options")
        }
        .contextMenu {
            Button {
                reportingComment = comment
            } label: {
                Label("Report Comment", systemImage: "exclamationmark.shield")
            }
            Button(role: .destructive) {
                blockingComment = comment
            } label: {
                Label("Block @\(comment.author?.username ?? "user")", systemImage: "hand.raised")
            }
        }
        .sheet(item: $reportingComment) { comment in
            ReportContentSheet(
                contentType: .comment,
                contentId: UUID(uuidString: comment.id) ?? UUID(),
                reportedUserId: UUID(uuidString: comment.authorId) ?? UUID()
            )
        }
        .blockUserAlert(
            isPresented: Binding(
                get: { blockingComment?.id == comment.id },
                set: { if !$0 && blockingComment?.id == comment.id { blockingComment = nil } }
            ),
            username: comment.author?.username ?? "user",
            userId: UUID(uuidString: comment.authorId) ?? UUID()
        ) {
            try await ModerationService.shared.blockUser(
                UUID(uuidString: comment.authorId) ?? UUID()
            )
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: BSCSpacing.sm) {
            TextField("Add a comment...", text: $viewModel.newCommentText)
                .textFieldStyle(.plain)
                .bscFont(size: 15)
                .foregroundColor(.bscTextPrimary)
                .padding(.vertical, BSCSpacing.sm)
                .padding(.horizontal, BSCSpacing.md)
                .frame(minHeight: BSCTouchTarget.standard)
                .background(Color.bscSurfaceGlass)
                .clipShape(Capsule())
                .focused($isCommentFocused)
                .accessibilityIdentifier(AccessibilityID.Comments.inputField)

            Button {
                Task {
                    let countBefore = viewModel.comments.count
                    await viewModel.sendComment()
                    if viewModel.comments.count > countBefore {
                        UINotificationFeedbackGenerator.success()
                    }
                }
            } label: {
                ZStack {
                    if viewModel.isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.bscPrimary)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .bscFont(size: 30)
                            .foregroundColor(viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .bscTextTertiary : .bscPrimary)
                    }
                }
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
            }
            .disabled(viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
            .accessibilityLabel("Send comment")
            .accessibilityIdentifier(AccessibilityID.Comments.sendButton)
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
    }
}
