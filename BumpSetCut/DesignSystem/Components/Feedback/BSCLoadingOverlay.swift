import SwiftUI

// MARK: - BSCLoadingOverlay
/// A full-screen loading overlay with sports-themed animation
struct BSCLoadingOverlay: View {
    // MARK: - Properties
    let message: String
    var progress: Double? = nil
    var icon: String = "figure.volleyball"
    var showBackground: Bool = true

    @State private var isAnimating = false

    // MARK: - Body
    var body: some View {
        ZStack {
            // Background with blur
            if showBackground {
                Color.bscBackground.opacity(0.85)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
            }

            // Content
            VStack(spacing: BSCSpacing.xl) {
                // Animated icon
                animatedIcon

                // Message
                Text(message)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.bscTextPrimary)
                    .multilineTextAlignment(.center)

                // Progress indicator
                if let progress = progress {
                    progressIndicator(progress: progress)
                } else {
                    indeterminateIndicator
                }
            }
            .padding(BSCSpacing.xxl)
            .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xxl)
        }
        .onAppear {
            withAnimation(.bscFloat) {
                isAnimating = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityValue(progress.map { "\(Int($0 * 100))%" } ?? "Loading")
    }

    // MARK: - Animated Icon
    private var animatedIcon: some View {
        Image(systemName: icon)
            .font(.system(size: 48, weight: .medium))
            .foregroundStyle(LinearGradient.bscPrimaryGradient)
            .offset(y: isAnimating ? -8 : 0)
            .animation(.bscFloat, value: isAnimating)
            .bscShadow(BSCShadow.glowOrange)
    }

    // MARK: - Progress Indicator
    private func progressIndicator(progress: Double) -> some View {
        VStack(spacing: BSCSpacing.sm) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: BSCRadius.full)
                        .fill(Color.bscSurfaceGlass)
                        .frame(height: 8)

                    // Fill
                    RoundedRectangle(cornerRadius: BSCRadius.full)
                        .fill(LinearGradient.bscPrimaryGradient)
                        .frame(width: geometry.size.width * CGFloat(progress), height: 8)
                        .animation(.bscSpring, value: progress)
                }
            }
            .frame(height: 8)
            .frame(maxWidth: 200)

            // Percentage
            Text("\(Int(progress * 100))%")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.bscOrange)
        }
    }

    // MARK: - Indeterminate Indicator
    private var indeterminateIndicator: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .bscOrange))
            .scaleEffect(1.2)
    }
}

// MARK: - Compact Loading Indicator
/// A smaller inline loading indicator
struct BSCLoadingIndicator: View {
    var message: String? = nil
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: BSCSpacing.sm) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .bscOrange))
                .scaleEffect(size / 20)

            if let message = message {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
    }
}

// MARK: - Preview
#Preview("BSCLoadingOverlay") {
    ZStack {
        Color.bscBackground.ignoresSafeArea()

        VStack(spacing: BSCSpacing.xxl) {
            BSCLoadingOverlay(
                message: "Analyzing rallies...",
                progress: 0.65
            )

            BSCLoadingOverlay(
                message: "Loading videos...",
                icon: "video.fill"
            )
        }
    }
}
