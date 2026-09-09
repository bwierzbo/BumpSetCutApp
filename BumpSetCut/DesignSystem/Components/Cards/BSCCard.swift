import SwiftUI

/// Scale applied to selected cards (BSCCard.interactive and .bscInteractive).
private let bscSelectedCardScale: CGFloat = 1.03

// MARK: - BSCCard
/// A versatile card container with glass morphism and elevation styles
struct BSCCard<Content: View>: View {
    // MARK: - Types
    enum Style {
        case glass       // Frosted glass with blur
        case elevated    // Solid with shadow
        case outlined    // Border only
        case interactive // Selectable with glow
    }

    // MARK: - Properties
    var style: Style = .glass
    var cornerRadius: CGFloat = BSCRadius.lg
    var padding: CGFloat = BSCSpacing.lg
    var isSelected: Bool = false
    @ViewBuilder let content: () -> Content

    // MARK: - Body
    var body: some View {
        content()
            .padding(padding)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(border)
            .bscShadow(shadowStyle)
            .scaleEffect(isSelected ? bscSelectedCardScale : 1.0)
            .animation(.bscSpring, value: isSelected)
    }

    // MARK: - Background
    @ViewBuilder
    private var background: some View {
        switch style {
        case .glass:
            ZStack {
                // Base glass layer
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.bscBackgroundElevated)

                // Gradient overlay for depth
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient.bscCardGradient)
            }

        case .elevated:
            Color.bscBackgroundElevated

        case .outlined:
            Color.clear

        case .interactive:
            ZStack {
                Color.bscBackgroundElevated

                if isSelected {
                    LinearGradient.bscCardGradient
                }
            }
        }
    }

    // MARK: - Border
    @ViewBuilder
    private var border: some View {
        switch style {
        case .glass:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)

        case .outlined:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)

        case .interactive:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    isSelected ? Color.bscPrimary : Color.bscSurfaceBorder,
                    lineWidth: isSelected ? 2 : 1
                )

        case .elevated:
            EmptyView()
        }
    }

    // MARK: - Shadow
    private var shadowStyle: BSCShadowStyle {
        switch style {
        case .glass:
            return BSCShadow.md
        case .elevated:
            return BSCShadow.lg
        case .outlined:
            return BSCShadow.sm
        case .interactive:
            return isSelected ? BSCShadow.glowBlue : BSCShadow.sm
        }
    }
}

// MARK: - Glass Effect Modifier
/// A view modifier that applies glass morphism effect
struct BSCGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = BSCRadius.lg
    var padding: CGFloat = BSCSpacing.lg
    var showBorder: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.bscBackgroundElevated)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient.bscCardGradient)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if showBorder {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                }
            }
            .bscShadow(BSCShadow.md)
    }
}

// MARK: - View Extensions
extension View {
    /// Apply glass morphism effect
    func bscGlass(
        cornerRadius: CGFloat = BSCRadius.lg,
        padding: CGFloat = BSCSpacing.lg,
        showBorder: Bool = true
    ) -> some View {
        modifier(BSCGlassModifier(
            cornerRadius: cornerRadius,
            padding: padding,
            showBorder: showBorder
        ))
    }

    /// Apply interactive card style
    func bscInteractive(
        isSelected: Bool,
        cornerRadius: CGFloat = BSCRadius.lg
    ) -> some View {
        background(Color.bscBackgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isSelected ? Color.bscPrimary : Color.bscSurfaceBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .bscShadow(isSelected ? BSCShadow.glowBlue : BSCShadow.sm)
            .scaleEffect(isSelected ? bscSelectedCardScale : 1.0)
            .animation(.bscSpring, value: isSelected)
    }
}

// MARK: - Surface Chrome
extension View {
    /// Standard elevated-surface chrome: rounded fill, hairline border, medium shadow.
    /// One modifier for the card/pill chrome repeated across the app.
    func bscSurfaceChrome(cornerRadius: CGFloat = BSCRadius.lg, shadow: BSCShadowStyle = BSCShadow.md) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.bscBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
            .bscShadow(shadow)
    }
}

// MARK: - Preview
#Preview("BSCCard Styles") {
    ScrollView {
        VStack(spacing: BSCSpacing.lg) {
            BSCCard(style: .glass) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Glass Card")
                        .font(.headline)
                        .foregroundColor(.bscTextPrimary)
                    Text("Frosted glass effect with subtle gradient")
                        .font(.subheadline)
                        .foregroundColor(.bscTextSecondary)
                }
            }

            BSCCard(style: .elevated) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Elevated Card")
                        .font(.headline)
                        .foregroundColor(.bscTextPrimary)
                    Text("Solid background with shadow")
                        .font(.subheadline)
                        .foregroundColor(.bscTextSecondary)
                }
            }

            BSCCard(style: .outlined) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Outlined Card")
                        .font(.headline)
                        .foregroundColor(.bscTextPrimary)
                    Text("Border only, no fill")
                        .font(.subheadline)
                        .foregroundColor(.bscTextSecondary)
                }
            }

            BSCCard(style: .interactive, isSelected: true) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Interactive Card (Selected)")
                        .font(.headline)
                        .foregroundColor(.bscTextPrimary)
                    Text("Blue glow when selected")
                        .font(.subheadline)
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
        .padding()
    }
    .background(Color.bscBackground)
}
