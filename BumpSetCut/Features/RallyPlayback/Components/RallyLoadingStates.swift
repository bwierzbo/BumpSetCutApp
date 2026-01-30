import SwiftUI

// MARK: - Rally Loading View
struct RallyLoadingView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Animated volleyball icon
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.bscOrange.opacity(0.3), Color.clear],
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
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(LinearGradient.bscPrimaryGradient)
                    .offset(y: isAnimating ? -4 : 0)
            }

            VStack(spacing: BSCSpacing.sm) {
                Text("Loading Rallies")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Preparing your rally segments...")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Rally Buffering Overlay
/// Shows a buffering indicator while waiting for video to be ready
struct RallyBufferingOverlay: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Buffering indicator
            VStack(spacing: BSCSpacing.md) {
                // Spinner
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)

                Text("Buffering...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(BSCSpacing.xl)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.lg)
                    .fill(Color.black.opacity(0.7))
                    .shadow(color: .black.opacity(0.3), radius: 20)
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
                    .fill(Color.bscWarning.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.bscWarning)
            }

            VStack(spacing: BSCSpacing.sm) {
                Text("Error Loading Rallies")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text(message)
                    .font(.system(size: 14))
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
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Empty icon
            ZStack {
                Circle()
                    .fill(Color.bscTextTertiary.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "film.stack")
                    .font(.system(size: 36))
                    .foregroundColor(.bscTextTertiary)
            }

            VStack(spacing: BSCSpacing.sm) {
                Text("No Rallies Found")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("This video doesn't have any detected rally segments. Try processing the video first.")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BSCSpacing.xl)
            }

            BSCButton(title: "Go Back", icon: "chevron.left", style: .primary, size: .medium) {
                onDismiss()
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
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
        RallyEmptyView(onDismiss: {})
    }
}
