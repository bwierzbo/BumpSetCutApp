import SwiftUI

// MARK: - Hex Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Create an adaptive color with separate light and dark values.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Brand Colors
extension Color {
    /// Primary Brand - Volleyball Orange (energetic, athletic)
    static let bscOrange = Color(hex: "#FF6B35")
    static let bscOrangeBright = Color(hex: "#FF8C5A")
    static let bscOrangeDark = Color(hex: "#E55A28")

    /// Secondary - Electric Blue (dynamic, tech-forward)
    static let bscBlue = Color(hex: "#3B82F6")
    static let bscBlueBright = Color(hex: "#60A5FA")
    static let bscBlueDark = Color(hex: "#2563EB")

    /// Accent - Vibrant Teal (fresh, active)
    static let bscTeal = Color(hex: "#14B8A6")
    static let bscTealBright = Color(hex: "#2DD4BF")
    static let bscTealDark = Color(hex: "#0D9488")
}

// MARK: - Surface Colors (Adaptive)
extension Color {
    /// Primary background
    static let bscBackground = Color(light: Color(hex: "#F8F8FA"), dark: Color(hex: "#0D0D0E"))

    /// Elevated surfaces - Cards, modals
    static let bscBackgroundElevated = Color(light: .white, dark: Color(hex: "#1A1A1C"))

    /// Muted background - Subtle differentiation
    static let bscBackgroundMuted = Color(light: Color(hex: "#F0F0F3"), dark: Color(hex: "#141416"))

    /// Glass effect base - For frosted glass panels
    static let bscSurfaceGlass = Color(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.05))

    /// Glass border - Subtle definition
    static let bscSurfaceBorder = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08))

    /// Glass highlight - Top edge shine
    static let bscSurfaceHighlight = Color(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.12))

    /// Media background - Full-bleed behind video players (white in light, black in dark)
    static let bscMediaBackground = Color(light: .white, dark: .black)
}

// MARK: - Text Colors (Adaptive)
extension Color {
    /// Primary text - High contrast
    static let bscTextPrimary = Color(light: Color(hex: "#1A1A1C"), dark: Color(hex: "#F1EFEF"))

    /// Secondary text - Medium emphasis
    static let bscTextSecondary = Color(light: Color(hex: "#6B6B76"), dark: Color(hex: "#A1A1AA"))

    /// Tertiary text - Low emphasis, hints
    static let bscTextTertiary = Color(light: Color(hex: "#9E9EA8"), dark: Color(hex: "#71717A"))

    /// Inverse text - For use on light/colored backgrounds
    static let bscTextInverse = Color(light: Color(hex: "#F1EFEF"), dark: Color(hex: "#0D0D0E"))
}

// MARK: - Status Colors
extension Color {
    /// Success - Confirmations, completed states
    static let bscSuccess = Color(hex: "#22C55E")
    static let bscSuccessSubtle = Color(hex: "#22C55E").opacity(0.15)

    /// Warning - Cautions, pending states
    static let bscWarning = Color(hex: "#F59E0B")
    static let bscWarningSubtle = Color(hex: "#F59E0B").opacity(0.15)

    /// Error - Failures, destructive actions
    static let bscError = Color(hex: "#EF4444")
    static let bscErrorSubtle = Color(hex: "#EF4444").opacity(0.15)

    /// Info - Information, neutral highlights
    static let bscInfo = Color(hex: "#3B82F6")
    static let bscInfoSubtle = Color(hex: "#3B82F6").opacity(0.15)
}

// MARK: - Processing Status Colors
extension Color {
    /// Original video - Not yet processed (subtle teal for visibility)
    static let bscStatusOriginal = Color.bscTeal.opacity(0.8)

    /// Processed video - Has AI-detected rallies
    static let bscStatusProcessed = Color.bscOrange

    /// Has versions - Multiple processed variants
    static let bscStatusVersioned = Color.bscBlue
}

// MARK: - Gradient Definitions
extension LinearGradient {
    /// Primary action gradient (energetic sports feel)
    static let bscPrimaryGradient = LinearGradient(
        colors: [Color.bscOrange, Color.bscOrangeDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Hero/header gradient (warm to cool transition)
    static let bscHeroGradient = LinearGradient(
        colors: [Color.bscOrange.opacity(0.8), Color.bscBlue.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Card highlight gradient (subtle glass shine)
    static let bscCardGradient = LinearGradient(
        colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// AI/Processing gradient (tech feel)
    static let bscAIGradient = LinearGradient(
        colors: [Color.bscBlue, Color.bscTeal],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Background fade gradient (for headers)
    static let bscBackgroundFade = LinearGradient(
        colors: [Color.bscBackground, Color.bscBackground.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Destructive action gradient
    static let bscDestructiveGradient = LinearGradient(
        colors: [Color.bscError, Color.bscError.opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Radial Gradients
extension RadialGradient {
    /// Glow effect for buttons and cards
    static func bscGlow(color: Color = .bscOrange) -> RadialGradient {
        RadialGradient(
            colors: [color.opacity(0.4), color.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: 100
        )
    }
}

// MARK: - Design System Namespace
enum BSCColors {
    // Brand
    static let primary = Color.bscOrange
    static let secondary = Color.bscBlue
    static let accent = Color.bscTeal

    // Backgrounds
    static let background = Color.bscBackground
    static let backgroundElevated = Color.bscBackgroundElevated
    static let backgroundMuted = Color.bscBackgroundMuted

    // Surfaces
    static let surfaceGlass = Color.bscSurfaceGlass
    static let surfaceBorder = Color.bscSurfaceBorder

    // Text
    static let textPrimary = Color.bscTextPrimary
    static let textSecondary = Color.bscTextSecondary
    static let textTertiary = Color.bscTextTertiary

    // Status
    static let success = Color.bscSuccess
    static let warning = Color.bscWarning
    static let error = Color.bscError
    static let info = Color.bscInfo
}
