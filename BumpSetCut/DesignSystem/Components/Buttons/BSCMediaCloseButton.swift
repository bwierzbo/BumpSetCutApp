import SwiftUI

// MARK: - BSCMediaCloseButton
/// Close button for full-screen media contexts (feed, rally playback, highlight
/// detail). Renders the standard 28pt `xmark.circle.fill` glyph over video with
/// a scrim shadow, and carries its own 44pt hit area inside the Button label —
/// call sites apply placement padding *outside* the component only.
struct BSCMediaCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .bscFont(size: 28)
                .foregroundColor(Color.bscOnMedia.opacity(0.85))
                .shadow(color: Color.bscMediaScrimBase.opacity(0.33), radius: 4)
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Close")
    }
}

// MARK: - Preview
#Preview("BSCMediaCloseButton") {
    ZStack(alignment: .topTrailing) {
        LinearGradient(
            colors: [Color.bscPrimary, Color.bscMediaBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        BSCMediaCloseButton {}
            .padding(BSCSpacing.xs)
    }
}
