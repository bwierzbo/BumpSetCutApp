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
                    Spacer()
                    ProgressView()
                        .tint(.bscPrimary)
                    Spacer()
                } else if viewModel.comments.isEmpty && viewModel.loadError != nil {
                    Spacer()
                    BSCEmptyState.loadFailed(message: viewModel.loadError?.localizedDescription) {
                        Task { await viewModel.loadComments() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Comments.emptyState)
                    Spacer()
                } else if viewModel.comments.isEmpty {
                    Spacer()
                    Text("No comments yet")
                        .font(.system(size: 15))
                        .foregroundColor(.bscTextSecondary)
                        .accessibilityIdentifier(AccessibilityID.Comments.emptyState)
                    Text("Be the first to comment!")
                        .font(.system(size: 13))
                        .foregroundColor(.bscTextTertiary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: BSCSpacing.md) {
                            ForEach(viewModel.comments) { comment in
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
                            .font(.system(size: 11))
                            .foregroundColor(.bscError)
                        Text("Couldn't send comment. Try again.")
                            .font(.system(size: 12))
                            .foregroundColor(.bscError)
                        Spacer()
                    }
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.xs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Input bar
                inputBar
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.sendError != nil)
            .background(Color.bscBackground)
            .task {
                await viewModel.loadMyPollVote()
                await viewModel.loadComments()
            }
    }

    // MARK: - Panel Header

    private var panelHeader: some View {
        VStack(spacing: BSCSpacing.sm) {
            Capsule()
                .fill(Color.bscTextTertiary.opacity(0.5))
                .frame(width: 36, height: 5)

            HStack {
                Text("Comments")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.bscTextPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.bscTextSecondary)
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

    private func commentRow(_ comment: Comment) -> some View {
        HStack(alignment: .top, spacing: BSCSpacing.sm) {
            // Avatar
            AvatarView(url: comment.author?.avatarURL, name: comment.author?.username ?? "?", size: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BSCSpacing.xs) {
                    Text(comment.author?.username ?? "Unknown")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.bscTextPrimary)

                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundColor(.bscTextTertiary)
                }

                Text(comment.text)
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextPrimary)

                // Like button
                Button {
                    Task { await viewModel.toggleCommentLike(comment) }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: comment.isLikedByMe ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                            .foregroundColor(comment.isLikedByMe ? .bscError : .bscTextTertiary)
                        if comment.likesCount > 0 {
                            Text("\(comment.likesCount)")
                                .font(.system(size: 11))
                                .foregroundColor(.bscTextTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            Spacer()
        }
        .contextMenu {
            Button {
                reportingComment = comment
            } label: {
                Label("Report Comment", systemImage: "exclamationmark.shield")
            }
        }
        .sheet(item: $reportingComment) { comment in
            ReportContentSheet(
                contentType: .comment,
                contentId: UUID(uuidString: comment.id) ?? UUID(),
                reportedUserId: UUID(uuidString: comment.authorId) ?? UUID()
            )
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: BSCSpacing.sm) {
            TextField("Add a comment...", text: $viewModel.newCommentText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(.bscTextPrimary)
                .padding(.vertical, BSCSpacing.sm)
                .padding(.horizontal, BSCSpacing.md)
                .background(Color.bscSurfaceGlass)
                .clipShape(Capsule())
                .focused($isCommentFocused)
                .accessibilityIdentifier(AccessibilityID.Comments.inputField)

            Button {
                Task { await viewModel.sendComment() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .bscTextTertiary : .bscPrimary)
            }
            .disabled(viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
            .accessibilityIdentifier(AccessibilityID.Comments.sendButton)
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
    }
}
