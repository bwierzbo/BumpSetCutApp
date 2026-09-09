import SwiftUI

// MARK: - BSCSkeletonView
/// A shimmer loading placeholder for content that's loading
struct BSCSkeletonView: View {
    var body: some View {
        ZStack {
            // Base color
            Color.bscBackgroundElevated

            // Video icon placeholder
            Image(systemName: "video.fill")
                .bscFont(size: BSCIconSize.md)
                .foregroundColor(.bscTextTertiary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .bscShimmer()
    }
}

// MARK: - Preview
#Preview("BSCSkeletonView") {
    VStack(spacing: BSCSpacing.lg) {
        BSCSkeletonView()
            .frame(width: 200, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))

        BSCSkeletonView()
            .frame(width: 100, height: 100)
            .clipShape(Circle())
    }
    .padding()
    .background(Color.bscBackground)
}
