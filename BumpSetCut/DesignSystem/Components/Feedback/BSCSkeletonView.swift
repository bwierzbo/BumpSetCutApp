import SwiftUI

// MARK: - BSCSkeletonView
/// A shimmer loading placeholder for content that's loading
struct BSCSkeletonView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            // Base color
            Color.bscBackgroundElevated

            // Shimmer gradient overlay
            LinearGradient(
                colors: [
                    Color.bscSurfaceGlass.opacity(0.3),
                    Color.bscSurfaceGlass.opacity(0.6),
                    Color.bscSurfaceGlass.opacity(0.3)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .offset(x: isAnimating ? 200 : -200)
            .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)

            // Video icon placeholder
            Image(systemName: "video.fill")
                .font(.title2)
                .foregroundColor(.bscTextTertiary.opacity(0.5))
        }
        .onAppear {
            isAnimating = true
        }
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
