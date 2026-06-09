//
//  CommentsPanel.swift
//  BumpSetCut
//
//  Custom comments overlay that keeps the post visible:
//  - Portrait: full-width slide-up sheet (TikTok-style), reaching the screen bottom.
//  - Landscape: full-height side panel on the right, video on the left.
//

import SwiftUI

extension View {
    /// Present a comments panel over this view for the given highlight.
    func commentsPanel(item: Binding<Highlight?>) -> some View {
        modifier(CommentsPanelModifier(item: item))
    }
}

private struct CommentsPanelModifier: ViewModifier {
    @Binding var item: Highlight?
    @State private var dragOffset: CGFloat = 0

    /// Real bottom safe-area inset (overlay ignores safe area, so read the window).
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                ZStack(alignment: landscape ? .trailing : .bottom) {
                    if let highlight = item {
                        // Dim backdrop over the post — tap to dismiss, post stays visible.
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { dismiss() }
                            .transition(.opacity)

                        panel(highlight: highlight, geo: geo, landscape: landscape)
                            .transition(.move(edge: landscape ? .trailing : .bottom))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: landscape ? .trailing : .bottom)
                .animation(.snappy(duration: 0.28), value: item != nil)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func panel(highlight: Highlight, geo: GeometryProxy, landscape: Bool) -> some View {
        let width = landscape ? min(460, geo.size.width * 0.46) : geo.size.width
        let height = landscape ? geo.size.height : geo.size.height * 0.78

        CommentsSheet(
            highlight: highlight,
            onClose: { dismiss() },
            onHeaderDrag: { value in
                if !landscape { dragOffset = max(0, value) }
            },
            onHeaderDragEnd: { value in
                if !landscape, value > 120 {
                    dismiss()
                } else {
                    withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                }
            }
        )
        // Keep the input bar above the home indicator (overlay ignores safe area).
        .padding(.bottom, bottomSafeInset)
        .frame(width: width, height: height, alignment: .top)
        .background(Color.bscBackground)
        .clipShape(landscape
            ? .rect(topLeadingRadius: 22, bottomLeadingRadius: 22)
            : .rect(topLeadingRadius: 22, topTrailingRadius: 22))
        .offset(y: landscape ? 0 : max(0, dragOffset))
    }

    private func dismiss() {
        dragOffset = 0
        item = nil
    }
}
