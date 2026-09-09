import SwiftUI

// MARK: - BSCSheetGrabber
/// Drag-indicator capsule for custom sheet/panel headers that hide the
/// system grabber. Callers own the surrounding padding.
struct BSCSheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Color.bscTextTertiary.opacity(0.5))
            .frame(width: 36, height: 5)
    }
}

// MARK: - Preview
#Preview("BSCSheetGrabber") {
    VStack(spacing: 0) {
        BSCSheetGrabber()
            .padding(.top, BSCSpacing.sm)
        Spacer()
    }
    .frame(maxWidth: .infinity)
    .frame(height: 200)
    .background(Color.bscBackground)
}
