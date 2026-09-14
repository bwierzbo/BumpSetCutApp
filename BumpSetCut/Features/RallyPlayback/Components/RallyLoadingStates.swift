import SwiftUI

// MARK: - Rally Loading View
struct RallyLoadingView: View {
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Animated volleyball icon
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.bscPrimary.opacity(0.3), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .scaleEffect(isAnimating ? 1.1 : 0.95)

                Circle()
                    .fill(Color.bscSurfaceGlass)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Circle()
                            .stroke(LinearGradient.bscPrimaryGradient, lineWidth: 2)
                    )

                Image(systemName: "figure.volleyball")
                    .bscFont(size: 36, weight: .medium)
                    .foregroundStyle(LinearGradient.bscPrimaryGradient)
                    .bscFloatingEffect()
            }

            VStack(spacing: BSCSpacing.sm) {
                Text("Loading Rallies")
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text("Preparing your rally segments...")
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.bscPulse) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Rally Buffering Overlay
/// Shows a buffering indicator while waiting for video to be ready
struct RallyBufferingOverlay: View {
    @State private var isAnimating = false
    var message: String = "Buffering..."

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.bscMediaScrim
                .ignoresSafeArea()

            // Buffering indicator
            VStack(spacing: BSCSpacing.md) {
                // Spinner
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .bscOnMedia))
                    .scaleEffect(1.5)

                Text(message)
                    .bscFont(size: 16, weight: .medium)
                    .foregroundColor(.bscOnMedia)
            }
            .padding(BSCSpacing.xl)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.lg)
                    .fill(Color.bscMediaScrimBase.opacity(0.7))
                    .shadow(color: Color.bscMediaScrimBase.opacity(0.3), radius: 20)
            )
        }
        .transition(.opacity)
    }
}

// MARK: - Rally Error View
struct RallyErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Error icon
            ZStack {
                Circle()
                    .fill(Color.bscWarningText.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "exclamationmark.triangle.fill")
                    .bscFont(size: 40)
                    .foregroundColor(.bscWarningText)
            }

            VStack(spacing: BSCSpacing.sm) {
                Text("Error Loading Rallies")
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text(message)
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BSCSpacing.xl)
            }

            HStack(spacing: BSCSpacing.lg) {
                BSCButton(title: "Dismiss", style: .ghost, size: .medium) {
                    onDismiss()
                }

                BSCButton(title: "Retry", style: .primary, size: .medium) {
                    onRetry()
                }
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }
}

// MARK: - Rally Empty View
struct RallyEmptyView: View {
    let onAddManually: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        BSCEmptyState.noRallySegments(onAddManually: onAddManually, onGoBack: onDismiss)
            .bscGlass(cornerRadius: BSCRadius.xl, padding: 0)
            .frame(maxWidth: BSCContentWidth.regular)
            .padding(BSCSpacing.xl)
    }
}

// MARK: - Previews
#Preview("Loading") {
    ZStack {
        Color.bscBackground
        RallyLoadingView()
    }
}

#Preview("Error") {
    ZStack {
        Color.bscBackground
        RallyErrorView(
            message: "Failed to load video metadata",
            onRetry: {},
            onDismiss: {}
        )
    }
}

#Preview("Empty") {
    ZStack {
        Color.bscBackground
        RallyEmptyView(onAddManually: {}, onDismiss: {})
    }
}
