import SwiftUI

// MARK: - Dynamic Type Scaled System Font
//
// `Font.system(size:)` produces a fixed-size font that ignores the user's
// Dynamic Type setting. These helpers scale a point size relative to `.body`
// so custom-sized text still respects accessibility text sizes. At the default
// text size the scaled value equals the requested size, so adopting them is
// visually neutral.

extension Font {
    /// System font scaled with Dynamic Type. Uses the app-wide content size
    /// category at evaluation time; prefer `View.bscFont(...)` in view code,
    /// which re-renders when the user changes their text size.
    static func bscScaled(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .body).scaledValue(for: size), weight: weight, design: design)
    }
}

extension View {
    /// Drop-in replacement for `.font(.system(size:weight:design:))` that
    /// scales with Dynamic Type and live-updates on text-size changes.
    func bscFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(BSCScaledFontModifier(size: size, weight: weight, design: design))
    }
}

private struct BSCScaledFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: traits)
        content.font(.system(size: scaled, weight: weight, design: design))
    }
}

private extension UIContentSizeCategory {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}
