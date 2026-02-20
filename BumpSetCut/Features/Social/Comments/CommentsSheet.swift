//
//  CommentsSheet.swift
//  BumpSetCut
//
//  Bottom sheet showing comments for a highlight.
//

import SwiftUI

struct CommentsSheet: View {
    let highlight: Highlight
    @State private var viewModel: CommentsViewModel
    @FocusState private var isCommentFocused: Bool

    init(highlight: Highlight) {
        self.highlight = highlight
        _viewModel = State(initialValue: CommentsViewModel(highlightId: highlight.id))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Comments list
                if viewModel.isLoading && viewModel.comments.isEmpty {
                    Spacer()
                    ProgressView()
                        .tint(.bscPrimary)
                    Spacer()
                } else if viewModel.comments.isEmpty {
                    Spacer()
                    Text("No comments yet")
                        .font(.system(size: 15))
                        .foregroundColor(.bscTextSecondary)
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

                // Input bar
                inputBar
            }
            .background(Color.bscBackground)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await viewModel.loadComments()
        }
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
                .onAppear { isCommentFocused = true }

            Button {
                Task { await viewModel.sendComment() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .bscTextTertiary : .bscPrimary)
            }
            .disabled(viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
    }
}
