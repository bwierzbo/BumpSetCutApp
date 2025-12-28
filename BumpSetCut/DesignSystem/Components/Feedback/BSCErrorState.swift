import SwiftUI

// MARK: - BSCErrorState
/// An error state component with retry and dismiss options
struct BSCErrorState: View {
    // MARK: - Types
    enum Style {
        case fullScreen  // Full-screen error overlay
        case inline      // Compact inline error
        case banner      // Top banner style
    }

    // MARK: - Properties
    let title: String
    let message: String
    var style: Style = .fullScreen
    var retryTitle: String = "Try Again"
    var dismissTitle: String = "Dismiss"
    var onRetry: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var isShaking = false

    // MARK: - Body
    var body: some View {
        Group {
            switch style {
            case .fullScreen:
                fullScreenLayout
            case .inline:
                inlineLayout
            case .banner:
                bannerLayout
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(title). \(message)")
    }

    // MARK: - Full Screen Layout
    private var fullScreenLayout: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Error icon
            errorIcon(size: 64)

            // Text content
            VStack(spacing: BSCSpacing.sm) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action buttons
            VStack(spacing: BSCSpacing.md) {
                if let onRetry = onRetry {
                    BSCButton(
                        title: retryTitle,
                        icon: "arrow.clockwise",
                        style: .primary,
                        action: onRetry
                    )
                    .frame(maxWidth: 280)
                }

                if let onDismiss = onDismiss {
                    BSCButton(
                        title: dismissTitle,
                        style: .ghost,
                        action: onDismiss
                    )
                    .frame(maxWidth: 280)
                }
            }
        }
        .padding(BSCSpacing.xxl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Inline Layout
    private var inlineLayout: some View {
        HStack(spacing: BSCSpacing.md) {
            errorIcon(size: 24)

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.bscTextPrimary)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.bscTextSecondary)
                    .lineLimit(2)
            }

            Spacer()

            if let onRetry = onRetry {
                BSCIconButton(
                    icon: "arrow.clockwise",
                    style: .ghost,
                    size: .compact,
                    action: onRetry
                )
            }

            if let onDismiss = onDismiss {
                BSCIconButton(
                    icon: "xmark",
                    style: .ghost,
                    size: .compact,
                    action: onDismiss
                )
            }
        }
        .padding(BSCSpacing.md)
        .background(Color.bscErrorSubtle)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(Color.bscError.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Banner Layout
    private var bannerLayout: some View {
        HStack(spacing: BSCSpacing.md) {
            errorIcon(size: 20)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .lineLimit(2)

            Spacer()

            if let onRetry = onRetry {
                Button(action: onRetry) {
                    Text(retryTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
        .background(Color.bscError)
        .offset(x: isShaking ? -5 : 0)
        .onAppear {
            withAnimation(.default.repeatCount(3, autoreverses: true).speed(4)) {
                isShaking = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isShaking = false
            }
        }
    }

    // MARK: - Error Icon
    private func errorIcon(size: CGFloat) -> some View {
        ZStack {
            if style == .fullScreen {
                Circle()
                    .fill(Color.bscErrorSubtle)
                    .frame(width: size * 1.5, height: size * 1.5)
            }

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundColor(.bscError)
        }
    }
}

// MARK: - Preset Error States
extension BSCErrorState {
    /// Network error
    static func networkError(onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) -> BSCErrorState {
        BSCErrorState(
            title: "Connection Error",
            message: "Unable to connect. Please check your internet connection and try again.",
            onRetry: onRetry,
            onDismiss: onDismiss
        )
    }

    /// Processing error
    static func processingError(onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) -> BSCErrorState {
        BSCErrorState(
            title: "Processing Failed",
            message: "We couldn't process this video. The file may be corrupted or in an unsupported format.",
            onRetry: onRetry,
            onDismiss: onDismiss
        )
    }

    /// Load error
    static func loadError(onRetry: @escaping () -> Void) -> BSCErrorState {
        BSCErrorState(
            title: "Failed to Load",
            message: "Something went wrong while loading your content.",
            onRetry: onRetry
        )
    }

    /// Export error
    static func exportError(onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) -> BSCErrorState {
        BSCErrorState(
            title: "Export Failed",
            message: "We couldn't export your video. Please ensure you have enough storage space.",
            onRetry: onRetry,
            onDismiss: onDismiss
        )
    }
}

// MARK: - Preview
#Preview("BSCErrorState") {
    ScrollView {
        VStack(spacing: BSCSpacing.xxl) {
            Text("Full Screen")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)

            BSCErrorState.processingError(onRetry: {}, onDismiss: {})

            Divider()
                .background(Color.bscSurfaceBorder)

            Text("Inline")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)

            BSCErrorState(
                title: "Upload Failed",
                message: "The video couldn't be uploaded.",
                style: .inline,
                onRetry: {},
                onDismiss: {}
            )
            .padding(.horizontal)

            Divider()
                .background(Color.bscSurfaceBorder)

            Text("Banner")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)

            BSCErrorState(
                title: "Error",
                message: "Something went wrong. Please try again.",
                style: .banner,
                onRetry: {},
                onDismiss: {}
            )
        }
        .padding(.vertical)
    }
    .background(Color.bscBackground)
}
