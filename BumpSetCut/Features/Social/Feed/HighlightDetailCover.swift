//
//  HighlightDetailCover.swift
//  BumpSetCut
//
//  Full-screen viewer for a single post, used wherever one is opened outside
//  a feed: deep links, and rallies attached to a message.
//

import SwiftUI

struct HighlightDetailCover: View {
    let highlight: Highlight
    var onDismiss: () -> Void = {}

    @State private var comments: Highlight?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HighlightCardView(
                highlight: highlight,
                onLike: {},
                onComment: { comments = highlight },
                onProfile: { _ in }
            )

            // xs outer padding keeps the icon visually 12pt from the edge
            // (the component's 44pt hit frame supplies the other 8pt).
            BSCMediaCloseButton { onDismiss() }
                .padding(BSCSpacing.xs)
        }
        .commentsPanel(item: $comments)
    }
}
