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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.bscOrange)
            }
        }
    }

    private func shimmerOverlay(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: BSCRadius.full)
            .fill(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.3), .clear],
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
                        .font(.system(size: size * 0.3, weight: .bold))
                        .foregroundColor(.bscTextPrimary)

                    Text("%")
                        .font(.system(size: size * 0.15, weight: .medium))
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
                .bscShadow(BSCShadow.glowOrange)

            // Volleyball icon
            Image(systemName: "figure.volleyball")
                .font(.system(size: size * 0.35, weight: .medium))
                .foregroundStyle(LinearGradient.bscPrimaryGradient)
                .bscFloatingEffect()

            // Percentage badge
            if showPercentage {
                VStack {
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.bscTextInverse)
                        .padding(.horizontal, BSCSpacing.sm)
                        .padding(.vertical, BSCSpacing.xxs)
                        .background(Color.bscOrange)
                        .clipShape(Capsule())
                        .offset(y: BSCSpacing.sm)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Step Progress
/// A step-based progress indicator
struct BSCStepProgress: View {
    let currentStep: Int
    let totalSteps: Int
    var labels: [String]? = nil

    var body: some View {
        VStack(spacing: BSCSpacing.sm) {
            // Steps
            HStack(spacing: BSCSpacing.xs) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    stepIndicator(for: step)

                    if step < totalSteps - 1 {
                        connector(isComplete: step < currentStep)
                    }
                }
            }

            // Labels
            if let labels = labels, labels.count == totalSteps {
                HStack {
                    ForEach(0..<totalSteps, id: \.self) { step in
                        Text(labels[step])
                            .font(.caption2)
                            .foregroundColor(step <= currentStep ? .bscTextPrimary : .bscTextTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func stepIndicator(for step: Int) -> some View {
        ZStack {
            Circle()
                .fill(step <= currentStep ? Color.bscOrange : Color.bscSurfaceGlass)
                .frame(width: 24, height: 24)

            if step < currentStep {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text("\(step + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(step == currentStep ? .white : .bscTextTertiary)
            }
        }
    }

    private func connector(isComplete: Bool) -> some View {
        Rectangle()
            .fill(isComplete ? Color.bscOrange : Color.bscSurfaceGlass)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
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

            // Step Progress
            VStack(alignment: .leading, spacing: BSCSpacing.md) {
                Text("Step Progress")
                    .font(.headline)
                    .foregroundColor(.bscTextPrimary)

                BSCStepProgress(
                    currentStep: 2,
                    totalSteps: 4,
                    labels: ["Upload", "Detect", "Process", "Export"]
                )
                .frame(maxWidth: 300)
            }
        }
        .padding()
    }
    .background(Color.bscBackground)
}
