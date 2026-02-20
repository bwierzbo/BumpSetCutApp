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
    let onComment: (Highlight) -> Void
    let onDelete: ((Highlight) -> Void)?
    let onDismiss: () -> Void

    @State private var currentIndex: Int?
    @State private var hasScrolledToStart = false

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
                            onComment: { onComment(highlight) },
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
            .ignoresSafeArea()

            // Close button + counter
            VStack {
                HStack {
                    // Position counter
                    if highlights.count > 1 {
                        Text("\((currentIndex ?? startIndex) + 1)/\(highlights.count)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, BSCSpacing.sm)
                            .padding(.vertical, BSCSpacing.xs)
                            .background(.ultraThinMaterial.opacity(0.8))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(radius: 4)
                    }
                }
                .padding(.horizontal, BSCSpacing.md)
                .padding(.top, BSCSpacing.md)

                Spacer()
            }
        }
        .onAppear {
            if !hasScrolledToStart {
                currentIndex = startIndex
                hasScrolledToStart = true
            }
        }
    }
}
