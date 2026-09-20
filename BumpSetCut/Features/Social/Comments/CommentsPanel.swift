//
//  CommentsPanel.swift
//  BumpSetCut
//
//  Custom comments overlay:
//  - Portrait: full-width slide-up sheet (TikTok-style) covering most of the
//    screen, with the post still visible above it.
//  - Landscape: covers the post entirely. A side panel left too little width
//    for a comment and the keyboard swallowed what was left.
//
//  The overlay ignores the container's safe area so it can reach the screen
//  edges, but never the keyboard's: that inset is what lifts the input bar
//  clear of the keyboard. While the field holds focus the sheet takes the
//  whole space the keyboard leaves, so the text being typed is always visible.
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
    /// True while the comment field holds focus — the sheet then fills the
    /// space above the keyboard instead of sitting at its resting height.
    @State private var isTyping = false

    /// Real safe-area insets (the overlay ignores the container's, so read the
    /// window directly).
    private var keyWindowInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }

    private var bottomSafeInset: CGFloat { keyWindowInsets.bottom }
    private var topSafeInset: CGFloat { keyWindowInsets.top }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                ZStack(alignment: .bottom) {
                    if let highlight = item {
                        // Portrait dims the post, which stays visible above the
                        // sheet. Landscape covers it outright — and opaquely,
                        // so that when the keyboard shortens the sheet the post
                        // doesn't reappear in the gap above it.
                        (landscape ? Color.bscBackground : Color.bscMediaScrimBase.opacity(0.18))
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { dismiss() }
                            .transition(.opacity)

                        panel(highlight: highlight, geo: geo, landscape: landscape)
                            .transition(.move(edge: .bottom))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .animation(.bscSnappy, value: item != nil)
                .animation(.bscSnappy, value: isTyping)
            }
            // Container only: the keyboard's inset is what keeps the input bar
            // visible, so it must not be ignored here.
            .ignoresSafeArea(.container)
        }
    }

    @ViewBuilder
    private func panel(highlight: Highlight, geo: GeometryProxy, landscape: Bool) -> some View {
        // geo excludes the keyboard, so while typing this is exactly the space
        // left above it — the sheet fills it and the input bar lands on top of
        // the keyboard rather than behind it. Landscape covers the post
        // outright; there isn't room to read comments beside it.
        let height = (landscape || isTyping) ? geo.size.height : geo.size.height * 0.78

        CommentsSheet(
            highlight: highlight,
            onClose: { dismiss() },
            onHeaderDrag: { value in dragOffset = max(0, value) },
            onHeaderDragEnd: { value in
                if value > 120 {
                    dismiss()
                } else {
                    withAnimation(.bscSnappy) { dragOffset = 0 }
                }
            },
            onFocusChanged: { isTyping = $0 }
        )
        // Clear the home indicator, but not while the keyboard is up — it
        // already occupies that strip, and the gap reads as a misalignment.
        .padding(.bottom, isTyping ? 0 : bottomSafeInset)
        // At full height the sheet's top reaches the screen edge, where the
        // header would otherwise sit under the status bar.
        .padding(.top, (landscape || isTyping) ? topSafeInset : 0)
        .frame(width: geo.size.width, height: height, alignment: .top)
        .background(Color.bscBackground)
        .clipShape(.rect(topLeadingRadius: BSCRadius.xl, topTrailingRadius: BSCRadius.xl))
        .offset(y: max(0, dragOffset))
    }

    private func dismiss() {
        dragOffset = 0
        item = nil
    }
}
