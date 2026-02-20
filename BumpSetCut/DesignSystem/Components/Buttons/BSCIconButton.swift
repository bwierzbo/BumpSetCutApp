import SwiftUI

// MARK: - BSCIconButton
/// A circular icon button with glass background and bounce animation
struct BSCIconButton: View {
    // MARK: - Types
    enum Style {
        case glass       // Frosted glass background
        case solid       // Solid color background
        case ghost       // Transparent
        case primary     // Blue primary
        case destructive // Red
        case success     // Green
    }

    enum Size {
        case compact     // 32pt
        case standard    // 44pt
        case large       // 60pt
        case extraLarge  // 70pt

        var dimension: CGFloat {
            switch self {
            case .compact: return BSCTouchTarget.compact
            case .standard: return BSCTouchTarget.standard
            case .large: return BSCTouchTarget.large
            case .extraLarge: return BSCTouchTarget.extraLarge
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .compact: return 14
            case .standard: return 18
            case .large: return 24
            case .extraLarge: return 28
            }
        }
    }

    // MARK: - Properties
    let icon: String
    var style: Style = .glass
    var size: Size = .standard
    var badge: Int? = nil
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    // MARK: - Body
    var body: some View {
        Button(action: action) {
            ZStack {
                // Background
                Circle()
                    .fill(backgroundColor)
                    .frame(width: size.dimension, height: size.dimension)

                // Border for glass style
                if style == .glass || style == .ghost {
                    Circle()
                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                        .frame(width: size.dimension, height: size.dimension)
                }

                // Icon
                Image(systemName: icon)
                    .font(.system(size: size.iconSize, weight: .semibold))
                    .foregroundColor(foregroundColor)

                // Badge
                if let badge = badge, badge > 0 {
                    badgeView(count: badge)
                }
            }
            .bscShadow(shadowStyle)
            .opacity(isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(BSCIconButtonPressStyle())
        .accessibilityLabel(accessibilityLabel ?? icon)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Badge View
    @ViewBuilder
    private func badgeView(count: Int) -> some View {
        let badgeText = count > 99 ? "99+" : "\(count)"

        Text(badgeText)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.bscError)
            .clipShape(Capsule())
            .offset(x: size.dimension / 3, y: -size.dimension / 3)
    }

    // MARK: - Computed Properties

    private var backgroundColor: Color {
        switch style {
        case .glass:
            return Color.bscSurfaceGlass
        case .solid:
            return Color.bscBackgroundElevated
        case .ghost:
            return Color.clear
        case .primary:
            return Color.bscPrimary
        case .destructive:
            return Color.bscError
        case .success:
            return Color.bscSuccess
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .glass, .solid, .ghost:
            return Color.bscTextPrimary
        case .primary, .destructive, .success:
            return Color.white
        }
    }

    private var shadowStyle: BSCShadowStyle {
        guard isEnabled else { return BSCShadow.sm }
        switch style {
        case .primary:
            return BSCShadow.glowPrimary
        case .destructive:
            return BSCShadow.glowError
        case .success:
            return BSCShadow.glowSuccess
        default:
            return BSCShadow.sm
        }
    }
}

// MARK: - BSCIconButton Press Style
private struct BSCIconButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.bscBounce, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

// MARK: - Convenience Initializers
extension BSCIconButton {
    /// Creates a toolbar-style icon button
    static func toolbar(icon: String, action: @escaping () -> Void) -> BSCIconButton {
        BSCIconButton(icon: icon, style: .glass, size: .compact, action: action)
    }

    /// Creates a primary action button (like save/heart)
    static func primaryAction(icon: String, action: @escaping () -> Void) -> BSCIconButton {
        BSCIconButton(icon: icon, style: .primary, size: .large, action: action)
    }

    /// Creates a destructive action button (like delete/trash)
    static func destructiveAction(icon: String, action: @escaping () -> Void) -> BSCIconButton {
        BSCIconButton(icon: icon, style: .destructive, size: .large, action: action)
    }
}

// MARK: - Preview
#Preview("BSCIconButton Styles") {
    VStack(spacing: BSCSpacing.xl) {
        HStack(spacing: BSCSpacing.lg) {
            BSCIconButton(icon: "gear", style: .glass, size: .compact) {}
            BSCIconButton(icon: "plus", style: .glass, size: .standard) {}
            BSCIconButton(icon: "play.fill", style: .glass, size: .large) {}
        }

        HStack(spacing: BSCSpacing.lg) {
            BSCIconButton(icon: "heart.fill", style: .primary, size: .large) {}
            BSCIconButton(icon: "trash", style: .destructive, size: .large) {}
            BSCIconButton(icon: "checkmark", style: .success, size: .large) {}
        }

        HStack(spacing: BSCSpacing.lg) {
            BSCIconButton(icon: "bell", style: .glass, size: .standard, badge: 5) {}
            BSCIconButton(icon: "envelope", style: .glass, size: .standard, badge: 42) {}
            BSCIconButton(icon: "message", style: .glass, size: .standard, badge: 100) {}
        }

        HStack(spacing: BSCSpacing.lg) {
            BSCIconButton.toolbar(icon: "magnifyingglass") {}
            BSCIconButton.toolbar(icon: "ellipsis") {}
            BSCIconButton.toolbar(icon: "square.and.arrow.up") {}
        }
    }
    .padding()
    .background(Color.bscBackground)
}
