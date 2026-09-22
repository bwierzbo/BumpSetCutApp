//
//  MyPostsPickerSheet.swift
//  BumpSetCut
//
//  Pick one of your own community posts to attach to a message. Tap to
//  attach — a post is referenced by id, so there's nothing to export.
//

import SwiftUI

struct MyPostsPickerSheet: View {
    @State private var viewModel: MyPostsPickerViewModel
    let onPick: (Highlight) -> Void
    let onCancel: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.xs), count: 3)

    init(currentUserId: String,
         apiClient: (any APIClient)? = nil,
         onPick: @escaping (Highlight) -> Void,
         onCancel: @escaping () -> Void) {
        _viewModel = State(initialValue: MyPostsPickerViewModel(currentUserId: currentUserId, apiClient: apiClient))
        self.onPick = onPick
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("My Posts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .foregroundColor(.bscTextSecondary)
                }
            }
            .task { await viewModel.loadInitial() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.highlights.isEmpty {
            ProgressView().tint(.bscPrimary)
        } else if viewModel.loadFailed && viewModel.highlights.isEmpty {
            BSCEmptyState.loadFailed { Task { await viewModel.loadInitial() } }
        } else if viewModel.highlights.isEmpty {
            BSCEmptyState.noUserHighlights(isOwnProfile: true)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: BSCSpacing.xs) {
                    ForEach(viewModel.highlights) { highlight in
                        Button {
                            onPick(highlight)
                        } label: {
                            cell(highlight)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(highlight.caption ?? "Post")
                        .accessibilityIdentifier(AccessibilityID.Messages.attachCell)
                    }

                    if viewModel.hasMore {
                        ProgressView()
                            .tint(.bscPrimary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onAppear { Task { await viewModel.loadMore() } }
                    }
                }
                .padding(BSCSpacing.xs)
            }
            .accessibilityIdentifier(AccessibilityID.Messages.attachMyPosts)
        }
    }

    private func cell(_ highlight: Highlight) -> some View {
        AsyncImage(url: highlight.thumbnailImageURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.bscSurfaceGlass
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let caption = highlight.caption, !caption.isEmpty {
                Text(caption)
                    .bscFont(size: 11, weight: .medium)
                    .foregroundColor(.bscOnMedia)
                    .lineLimit(1)
                    .padding(.horizontal, BSCSpacing.xs)
                    .padding(.vertical, BSCSpacing.xxs)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(BSCSpacing.xs)
            }
        }
        // The whole tile is the target, including the image's letterboxed corners.
        .contentShape(Rectangle())
    }
}
