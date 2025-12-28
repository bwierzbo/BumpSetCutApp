import SwiftUI

// MARK: - Spacing (8pt Grid System)
enum BSCSpacing {
    /// 2pt - Micro spacing
    static let xxs: CGFloat = 2

    /// 4pt - Extra small
    static let xs: CGFloat = 4

    /// 8pt - Small
    static let sm: CGFloat = 8

    /// 12pt - Medium
    static let md: CGFloat = 12

    /// 16pt - Large
    static let lg: CGFloat = 16

    /// 24pt - Extra large
    static let xl: CGFloat = 24

    /// 32pt - 2X large
    static let xxl: CGFloat = 32

    /// 48pt - 3X large
    static let xxxl: CGFloat = 48

    /// 64pt - Huge
    static let huge: CGFloat = 64
}

// MARK: - Corner Radius
enum BSCRadius {
    /// 6pt - Small elements (badges, small buttons)
    static let sm: CGFloat = 6

    /// 10pt - Medium elements (inputs, small cards)
    static let md: CGFloat = 10

    /// 14pt - Large elements (cards, modals)
    static let lg: CGFloat = 14

    /// 20pt - Extra large (hero cards, sheets)
    static let xl: CGFloat = 20

    /// 28pt - 2X large (full-screen cards)
    static let xxl: CGFloat = 28

    /// Pill shape (capsule)
    static let full: CGFloat = 9999
}

// MARK: - Shadow Definitions
struct BSCShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    func apply(to view: some View) -> some View {
        view.shadow(color: color, radius: radius, x: x, y: y)
    }
}

enum BSCShadow {
    /// Small shadow - Subtle elevation
    static let sm = BSCShadowStyle(
        color: .black.opacity(0.15),
        radius: 4,
        x: 0,
        y: 2
    )

    /// Medium shadow - Cards, buttons
    static let md = BSCShadowStyle(
        color: .black.opacity(0.2),
        radius: 8,
        x: 0,
        y: 4
    )

    /// Large shadow - Modals, elevated surfaces
    static let lg = BSCShadowStyle(
        color: .black.opacity(0.25),
        radius: 16,
        x: 0,
        y: 8
    )

    /// Extra large shadow - Floating elements
    static let xl = BSCShadowStyle(
        color: .black.opacity(0.3),
        radius: 24,
        x: 0,
        y: 12
    )

    /// Orange glow - Primary accent glow
    static let glowOrange = BSCShadowStyle(
        color: .bscOrange.opacity(0.4),
        radius: 20,
        x: 0,
        y: 0
    )

    /// Blue glow - Secondary accent glow
    static let glowBlue = BSCShadowStyle(
        color: .bscBlue.opacity(0.4),
        radius: 20,
        x: 0,
        y: 0
    )

    /// Success glow - Green accent
    static let glowSuccess = BSCShadowStyle(
        color: .bscSuccess.opacity(0.4),
        radius: 16,
        x: 0,
        y: 0
    )

    /// Error glow - Red accent
    static let glowError = BSCShadowStyle(
        color: .bscError.opacity(0.4),
        radius: 16,
        x: 0,
        y: 0
    )
}

// MARK: - View Extension for Shadows
extension View {
    func bscShadow(_ style: BSCShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    func bscShadow(_ keyPath: KeyPath<BSCShadow.Type, BSCShadowStyle>) -> some View {
        let style = BSCShadow.self[keyPath: keyPath]
        return shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}

// MARK: - Content Width Constraints
enum BSCContentWidth {
    /// Compact - Narrow content (forms, inputs)
    static let compact: CGFloat = 320

    /// Regular - Standard content width
    static let regular: CGFloat = 480

    /// Wide - Expanded content
    static let wide: CGFloat = 720

    /// Maximum - Full content area
    static let max: CGFloat = 1200
}

// MARK: - Icon Sizes
enum BSCIconSize {
    /// 16pt - Inline icons
    static let sm: CGFloat = 16

    /// 20pt - Standard icons
    static let md: CGFloat = 20

    /// 24pt - Large icons
    static let lg: CGFloat = 24

    /// 32pt - Extra large icons
    static let xl: CGFloat = 32

    /// 48pt - Hero icons
    static let xxl: CGFloat = 48
}

// MARK: - Touch Target Sizes
enum BSCTouchTarget {
    /// 32pt - Compact touch target
    static let compact: CGFloat = 32

    /// 44pt - Standard touch target (Apple HIG minimum)
    static let standard: CGFloat = 44

    /// 60pt - Large touch target (action buttons)
    static let large: CGFloat = 60

    /// 70pt - Extra large (primary actions)
    static let extraLarge: CGFloat = 70
}

// MARK: - Convenience Padding Modifier
extension View {
    func bscPadding(_ spacing: CGFloat) -> some View {
        padding(spacing)
    }

    func bscPadding(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
    }

    func bscCardPadding() -> some View {
        padding(BSCSpacing.lg)
    }

    func bscSectionPadding() -> some View {
        padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.md)
    }
}
