import SwiftUI

// MARK: - BSCButton
/// A versatile button component with multiple styles and sizes
struct BSCButton: View {
    // MARK: - Types
    enum Style {
        case primary      // Blue gradient - main CTAs
        case secondary    // Glass effect - secondary actions
        case ghost        // Transparent with border
        case destructive  // Red - dangerous actions
    }

    enum Size {
        case small   // Compact
        case medium  // Standard
        case large   // Prominent
    }

    // MARK: - Properties
    let title: String
    var icon: String? = nil
    var style: Style = .primary
    var size: Size = .medium
    var isLoading: Bool = false
    var isFullWidth: Bool = true
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    // MARK: - Body
    var body: some View {
        Button(action: action) {
            HStack(spacing: BSCSpacing.sm) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: foregroundColor))
                        .scaleEffect(0.8)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: fontSize, weight: .semibold))
            }
            .foregroundColor(foregroundColor)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(border)
            .bscShadow(shadowStyle)
            .opacity(isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(BSCButtonPressStyle())
        .disabled(isLoading)
        .accessibilityLabel(title)
        .accessibilityHint(isLoading ? "Loading" : "")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Computed Properties

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .bscTextInverse
        case .secondary:
            return .bscPrimary
        case .ghost:
            return .bscTextPrimary
        case .destructive:
            return .white
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            LinearGradient.bscPrimaryGradient
        case .secondary:
            Color.bscPrimary.opacity(0.12)
        case .ghost:
            Color.clear
        case .destructive:
            LinearGradient.bscDestructiveGradient
        }
    }

    @ViewBuilder
    private var border: some View {
        switch style {
        case .secondary:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.bscPrimary.opacity(0.3), lineWidth: 1)
        case .ghost:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        default:
            EmptyView()
        }
    }

    private var shadowStyle: BSCShadowStyle {
        guard isEnabled else { return BSCShadow.sm }
        switch style {
        case .primary:
            return BSCShadow.md
        case .destructive:
            return BSCShadow.md
        default:
            return BSCShadow.sm
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 14
        case .medium: return 16
        case .large: return 18
        }
    }

    private var iconSize: CGFloat {
        switch size {
        case .small: return 14
        case .medium: return 16
        case .large: return 18
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .small: return BSCSpacing.sm
        case .medium: return BSCSpacing.md
        case .large: return BSCSpacing.lg
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return BSCSpacing.md
        case .medium: return BSCSpacing.xl
        case .large: return BSCSpacing.xxl
        }
    }

    private var cornerRadius: CGFloat {
        switch size {
        case .small: return BSCRadius.md
        case .medium: return BSCRadius.lg
        case .large: return BSCRadius.xl
        }
    }
}

// MARK: - BSCButton Press Style
private struct BSCButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.bscQuick, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

// MARK: - Preview
#Preview("BSCButton Styles") {
    VStack(spacing: BSCSpacing.lg) {
        BSCButton(title: "Primary Action", icon: "play.fill", style: .primary) {}

        BSCButton(title: "Secondary Action", icon: "arrow.right", style: .secondary) {}

        BSCButton(title: "Ghost Button", style: .ghost) {}

        BSCButton(title: "Delete", icon: "trash", style: .destructive) {}

        BSCButton(title: "Loading...", style: .primary, isLoading: true) {}

        HStack(spacing: BSCSpacing.md) {
            BSCButton(title: "Small", size: .small, isFullWidth: false) {}
            BSCButton(title: "Medium", size: .medium, isFullWidth: false) {}
            BSCButton(title: "Large", size: .large, isFullWidth: false) {}
        }
    }
    .padding()
    .background(Color.bscBackground)
}
