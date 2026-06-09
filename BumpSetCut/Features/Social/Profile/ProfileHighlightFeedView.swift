//
//  ProfileHighlightFeedView.swift
//  BumpSetCut
//
//  Full-screen vertical feed for browsing a profile's highlights.
//  Swipe vertically between highlights, horizontally within multi-rally posts.
//

import SwiftUI

struct ProfileHighlightFeedView: View {
    let highlights: [Highlight]
    let startIndex: Int
    let isOwnProfile: Bool
    let onLike: (Highlight) -> Void
    let onDelete: ((Highlight) -> Void)?
    let onDismiss: () -> Void

    @State private var currentIndex: Int?
    @State private var hasScrolledToStart = false
    @State private var commentsHighlight: Highlight?

    var body: some View {
        ZStack {
            Color.bscMediaBackground.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(highlights.enumerated()), id: \.element.id) { index, highlight in
                        HighlightCardView(
                            highlight: highlight,
                            isActive: currentIndex == index,
                            onLike: { onLike(highlight) },
                            onComment: { commentsHighlight = highlight },
                            onProfile: { _ in },
                            onDelete: isOwnProfile ? { onDelete?(highlight) } : nil
                        )
                        .containerRelativeFrame(.vertical)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentIndex)
            .scrollBounceBehavior(.always)
            .ignoresSafeArea()

            // Close button
            VStack {
                HStack {
                    Spacer()

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.bscOnMedia.opacity(0.8))
                            .shadow(radius: 4)
                    }
                }
                .padding(.horizontal, BSCSpacing.md)
                .padding(.top, BSCSpacing.md)

                Spacer()
            }
        }
        // Full-screen video is a dark context regardless of system appearance.
        .environment(\.colorScheme, .dark)
        .onAppear {
            if !hasScrolledToStart {
                currentIndex = startIndex
                hasScrolledToStart = true
            }
        }
        // Comments overlay the post instead of dismissing it.
        .commentsPanel(item: $commentsHighlight)
    }
}
