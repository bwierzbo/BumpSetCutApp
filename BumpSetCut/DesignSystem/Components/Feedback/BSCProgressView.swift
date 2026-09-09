import SwiftUI

// MARK: - BSCProgressView
/// A sports-themed progress indicator with multiple styles
struct BSCProgressView: View {
    // MARK: - Types
    enum Style {
        case linear      // Horizontal bar
        case circular    // Ring/donut
        case volleyball  // Custom animated volleyball
    }

    // MARK: - Properties
    let progress: Double
    var style: Style = .linear
    var showPercentage: Bool = true
    var lineWidth: CGFloat = 8
    var size: CGFloat = 80

    // MARK: - Body
    var body: some View {
        Group {
            switch style {
            case .linear:
                linearProgress
            case .circular:
                circularProgress
            case .volleyball:
                volleyballProgress
            }
        }
        .accessibilityValue("\(Int(progress * 100))%")
    }

    // MARK: - Linear Progress
    private var linearProgress: some View {
        VStack(spacing: BSCSpacing.sm) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: BSCRadius.full)
                        .fill(Color.bscSurfaceGlass)

                    // Fill with gradient
                    RoundedRectangle(cornerRadius: BSCRadius.full)
                        .fill(LinearGradient.bscPrimaryGradient)
                        .frame(width: max(0, geometry.size.width * CGFloat(progress)))
                        .animation(.bscSpring, value: progress)

                    // Shimmer effect when in progress
                    if progress > 0 && progress < 1 {
                        shimmerOverlay(width: geometry.size.width * CGFloat(progress))
                    }
                }
            }
            .frame(height: lineWidth)

            if showPercentage {
                Text("\(Int(progress * 100))%")
                    .bscFont(size: 12, weight: .semibold)
                    .foregroundColor(.bscPrimaryText)
            }
        }
    }

    private func shimmerOverlay(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: BSCRadius.full)
            .fill(
                LinearGradient(
                    colors: [.clear, Color.bscOnMedia.opacity(0.3), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width)
            .mask(
                RoundedRectangle(cornerRadius: BSCRadius.full)
            )
            .bscShimmer()
    }

    // MARK: - Circular Progress
    private var circularProgress: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color.bscSurfaceGlass, lineWidth: lineWidth)

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(
                    LinearGradient.bscPrimaryGradient,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(.bscSpring, value: progress)

            // Percentage text
            if showPercentage {
                VStack(spacing: 2) {
                    Text("\(Int(progress * 100))")
                        .bscFont(size: size * 0.3, weight: .bold)
                        .foregroundColor(.bscTextPrimary)

                    Text("%")
                        .bscFont(size: size * 0.15, weight: .medium)
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Volleyball Progress
    private var volleyballProgress: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.bscSurfaceGlass)

            // Progress arc with glow
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(
                    LinearGradient.bscPrimaryGradient,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(.bscSpring, value: progress)
                .bscShadow(BSCShadow.glowPrimary)

            // Volleyball icon
            Image(systemName: "figure.volleyball")
                .bscFont(size: size * 0.35, weight: .medium)
                .foregroundStyle(LinearGradient.bscPrimaryGradient)
                .bscFloatingEffect()

            // Percentage badge
            if showPercentage {
                VStack {
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .bscFont(size: 11, weight: .bold)
                        .foregroundColor(.bscOnPrimary)
                        .padding(.horizontal, BSCSpacing.sm)
                        .padding(.vertical, BSCSpacing.xxs)
                        .background(Color.bscPrimaryDark)
                        .clipShape(Capsule())
                        .offset(y: BSCSpacing.sm)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Preview
#Preview("BSCProgressView") {
    ScrollView {
        VStack(spacing: BSCSpacing.xxl) {
            // Linear
            VStack(alignment: .leading, spacing: BSCSpacing.md) {
                Text("Linear")
                    .font(.headline)
                    .foregroundColor(.bscTextPrimary)

                BSCProgressView(progress: 0.65, style: .linear)
                    .frame(maxWidth: 300)
            }

            // Circular
            VStack(spacing: BSCSpacing.md) {
                Text("Circular")
                    .font(.headline)
                    .foregroundColor(.bscTextPrimary)

                BSCProgressView(progress: 0.75, style: .circular, size: 100)
            }

            // Volleyball
            VStack(spacing: BSCSpacing.md) {
                Text("Volleyball")
                    .font(.headline)
                    .foregroundColor(.bscTextPrimary)

                BSCProgressView(progress: 0.45, style: .volleyball, size: 120)
            }

        }
        .padding()
    }
    .background(Color.bscBackground)
}
