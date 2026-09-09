//
//  DesignTokens.swift
//  BumpSetCut
//
//  SINGLE SOURCE OF TRUTH for every design token in the app: colors, spacing,
//  radius, shadows, sizing, touch targets, animation, and transitions.
//  Documented in /design-system.md — update both together.
//
//  Rules of thumb:
//  - Never hardcode a color/spacing/radius value in a feature view; add or use a token.
//  - Text on light backgrounds must use the contrast-safe variants (bscPrimaryText,
//    bscSuccessText, bscErrorText, bscWarningText) — the raw brand/status colors
//    fail WCAG AA on white.
//  - Interactive elements use BSCTouchTarget.standard (44pt) as the minimum hit area.
//

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
    /// Primary Brand - Blue (aligned to logo, dynamic, tech-forward)
    static let bscBlue = Color(hex: "#3B82F6")
    static let bscBlueBright = Color(hex: "#60A5FA")
    static let bscBlueDark = Color(hex: "#2563EB")

    /// Secondary - Warm Orange (energetic accent, badges, highlights)
    static let bscOrange = Color(hex: "#FF6B35")
    static let bscOrangeBright = Color(hex: "#FF8C5A")
    static let bscOrangeDark = Color(hex: "#E55A28")

    /// Accent - Vibrant Teal (fresh, active)
    static let bscTeal = Color(hex: "#14B8A6")
    static let bscTealBright = Color(hex: "#2DD4BF")
    static let bscTealDark = Color(hex: "#0D9488")
}

// MARK: - Semantic Primary Colors
extension Color {
    /// The current primary brand color used throughout the app.
    static let bscPrimary = Color.bscBlue
    static let bscPrimaryBright = Color.bscBlueBright
    static let bscPrimaryDark = Color.bscBlueDark

    /// Primary for text usage — darker blue that passes WCAG AA on light backgrounds
    static let bscPrimaryText = Color(light: Color(hex: "#2563EB"), dark: Color(hex: "#60A5FA"))

    /// Subtle tinted background using the primary color
    static let bscPrimarySubtle = Color(
        light: Color(hex: "#3B82F6").opacity(0.10),
        dark: Color(hex: "#3B82F6").opacity(0.15)
    )

    /// Warm accent (demoted orange — for special callouts, favorites)
    static let bscWarmAccent = Color.bscOrange
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
    static let bscSurfaceGlass = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.05))

    /// Glass border - Subtle definition
    static let bscSurfaceBorder = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08))

    /// Glass highlight - Top edge shine
    static let bscSurfaceHighlight = Color(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.12))

    /// Media background - Full-bleed behind video players. Dark by design in all
    /// appearances: full-screen video is a dark context (letterbox bars stay black in
    /// light mode), matching TikTok/Reels/Photos. Themes can redefine this token.
    static let bscMediaBackground = Color(hex: "#0D0D0E")
}

// MARK: - Media Overlay Colors (chrome drawn over full-screen video)
extension Color {
    /// Primary chrome (text/icons) over media — always light for contrast on the dark
    /// media surface. Named token so future themes can restyle media overlays in one place.
    static let bscOnMedia = Color.white

    /// Secondary chrome over media (timestamps, inactive labels).
    static let bscOnMediaSecondary = Color.white.opacity(0.7)

    /// Scrim fill for pills/badges/gradients over media to guarantee chrome contrast
    /// even on bright video frames.
    static let bscMediaScrim = Color.black.opacity(0.45)

    /// Base color for scrims that need a non-standard opacity. Apply `.opacity(x)`
    /// to this instead of `Color.black` so themes can restyle every media scrim
    /// from one place.
    static let bscMediaScrimBase = Color.black
}

// MARK: - Text Colors (Adaptive)
extension Color {
    /// Primary text - High contrast
    static let bscTextPrimary = Color(light: Color(hex: "#1A1A1C"), dark: Color(hex: "#F1EFEF"))

    /// Secondary text - Medium emphasis
    static let bscTextSecondary = Color(light: Color(hex: "#6B6B76"), dark: Color(hex: "#A1A1AA"))

    /// Tertiary text - Low emphasis, hints. FAILS WCAG AA (2.65 light / 3.60 dark) —
    /// decorative hints only, never the sole carrier of information.
    static let bscTextTertiary = Color(light: Color(hex: "#9E9EA8"), dark: Color(hex: "#71717A"))

    /// Inverse text - For use on dark/colored backgrounds
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

    /// Contrast-safe text/icon variants for status colors in light mode.
    /// Use these (not the raw status colors) for any text or glyph on
    /// light backgrounds — the raw values fail WCAG AA there.
    static let bscSuccessText = Color(light: Color(hex: "#16A34A"), dark: Color(hex: "#22C55E"))
    static let bscErrorText = Color(light: Color(hex: "#DC2626"), dark: Color(hex: "#EF4444"))
    static let bscWarningText = Color(light: Color(hex: "#B45309"), dark: Color(hex: "#F59E0B"))
}

// MARK: - Processing Status Colors
extension Color {
    /// Original video - Not yet processed (subtle teal for visibility)
    static let bscStatusOriginal = Color.bscTeal.opacity(0.8)

    /// Processed video - Has AI-detected rallies
    static let bscStatusProcessed = Color.bscBlue

    /// Has versions - Multiple processed variants
    static let bscStatusVersioned = Color.bscTeal
}

// MARK: - Gradient Definitions
extension LinearGradient {
    /// Primary action gradient (blue brand feel)
    static let bscPrimaryGradient = LinearGradient(
        colors: [Color.bscBlue, Color.bscBlueDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Hero/header gradient (blue to teal transition)
    static let bscHeroGradient = LinearGradient(
        colors: [Color.bscBlue.opacity(0.8), Color.bscTeal.opacity(0.6)],
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

    /// Warm accent gradient (for special callouts, badges)
    static let bscWarmGradient = LinearGradient(
        colors: [Color.bscOrange, Color.bscOrangeDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Radial Gradients
extension RadialGradient {
    /// Glow effect for buttons and cards — defaults to primary blue
    static func bscGlow(color: Color = .bscPrimary) -> RadialGradient {
        RadialGradient(
            colors: [color.opacity(0.4), color.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: 100
        )
    }
}

// MARK: - Color Namespace
enum BSCColors {
    // Brand
    static let primary = Color.bscPrimary
    static let primaryText = Color.bscPrimaryText
    static let primarySubtle = Color.bscPrimarySubtle
    static let warmAccent = Color.bscWarmAccent
    static let secondary = Color.bscOrange
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

    /// Primary glow - Brand accent glow (blue)
    static let glowPrimary = BSCShadowStyle(
        color: .bscPrimary.opacity(0.4),
        radius: 20,
        x: 0,
        y: 0
    )

    /// Orange glow - Backward compatibility alias for glowPrimary
    static let glowOrange = glowPrimary

    /// Blue glow - Specific blue accent glow
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
    /// 32pt - Compact touch target. Visual size only — pair with a 44pt hit area
    /// (frame + contentShape) when used for an interactive element.
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

// MARK: - Animation Presets
extension Animation {
    /// Quick feedback - Button presses, toggles (0.15s)
    static let bscQuick = Animation.easeOut(duration: 0.15)

    /// Standard transitions - General UI changes (0.25s)
    static let bscStandard = Animation.easeInOut(duration: 0.25)

    /// Emphasized animations - Modals, significant state changes (0.35s)
    static let bscEmphasized = Animation.easeInOut(duration: 0.35)

    /// Sports-inspired spring - Bouncy, energetic feel
    static let bscBounce = Animation.spring(response: 0.4, dampingFraction: 0.65, blendDuration: 0)

    /// Soft spring - Subtle bounce for cards
    static let bscSpring = Animation.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)

    /// Snappy spring - Quick return for interactions
    static let bscSnappy = Animation.spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0)

    /// Card swipe animation - Smooth dismissal
    static let bscSwipe = Animation.spring(response: 0.45, dampingFraction: 0.75, blendDuration: 0)

    /// Float animation - Gentle hovering effect
    static let bscFloat = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)

    /// Pulse animation - Attention-grabbing glow
    static let bscPulse = Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)

    /// Spin animation - Loading spinners
    static let bscSpin = Animation.linear(duration: 1.0).repeatForever(autoreverses: false)
}

// MARK: - Transition Presets
extension AnyTransition {
    /// Slide up with fade - Modal presentations
    static let bscSlideUp = AnyTransition.asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .move(edge: .bottom).combined(with: .opacity)
    )

    /// Slide down with fade - Dropdown menus
    static let bscSlideDown = AnyTransition.asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .move(edge: .top).combined(with: .opacity)
    )

    /// Scale with fade - Cards, buttons
    static let bscScale = AnyTransition.scale(scale: 0.9).combined(with: .opacity)

    /// Scale up - Appearing elements
    static let bscScaleUp = AnyTransition.scale(scale: 0.8).combined(with: .opacity)

    /// Simple fade - Subtle transitions
    static let bscFade = AnyTransition.opacity

    /// Blur transition - Premium feel
    static var bscBlur: AnyTransition {
        .modifier(
            active: BlurModifier(blur: 10, opacity: 0),
            identity: BlurModifier(blur: 0, opacity: 1)
        )
    }
}

// MARK: - Blur Transition Modifier
private struct BlurModifier: ViewModifier {
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
    }
}

// MARK: - Duration Constants
enum BSCDuration {
    /// Instant - Micro-interactions (0.1s)
    static let instant: Double = 0.1

    /// Fast - Quick feedback (0.2s)
    static let fast: Double = 0.2

    /// Normal - Standard transitions (0.3s)
    static let normal: Double = 0.3

    /// Slow - Emphasized transitions (0.5s)
    static let slow: Double = 0.5

    /// Very slow - Dramatic reveals (0.8s)
    static let verySlow: Double = 0.8

    /// Float cycle - Floating animation period (3s)
    static let floatCycle: Double = 3.0

    /// Pulse cycle - Glow pulse period (2s)
    static let pulseCycle: Double = 2.0
}

// MARK: - Animation View Modifiers
extension View {
    /// Apply floating effect - Gentle up/down motion
    func bscFloatingEffect() -> some View {
        modifier(FloatingModifier())
    }

    /// Apply pulse glow effect
    func bscPulseGlow(color: Color = .bscPrimary, isActive: Bool = true) -> some View {
        modifier(PulseGlowModifier(color: color, isActive: isActive))
    }

    /// Apply staggered appearance animation
    func bscStaggered(index: Int, baseDelay: Double = 0.05) -> some View {
        modifier(StaggeredAppearanceModifier(index: index, baseDelay: baseDelay))
    }
}

// MARK: - Floating Animation Modifier
private struct FloatingModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFloating = false

    func body(content: Content) -> some View {
        content
            .offset(y: isFloating ? -8 : 0)
            .animation(reduceMotion ? nil : .bscFloat, value: isFloating)
            .onAppear {
                if !reduceMotion { isFloating = true }
            }
            .onDisappear { isFloating = false }  // Stop animation when off-screen to save battery
    }
}

// MARK: - Pulse Glow Modifier
private struct PulseGlowModifier: ViewModifier {
    let color: Color
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .shadow(
                color: isActive ? color.opacity(isPulsing ? 0.6 : 0.2) : .clear,
                radius: isPulsing ? 20 : 10,
                x: 0,
                y: 0
            )
            .animation(reduceMotion ? nil : .bscPulse, value: isPulsing)
            .onAppear {
                if isActive && !reduceMotion { isPulsing = true }
            }
            .onDisappear {
                isPulsing = false  // Stop pulsing when off-screen to save battery
            }
            .onChange(of: isActive) { _, newValue in
                isPulsing = newValue && !reduceMotion
            }
    }
}

// MARK: - Staggered Appearance Modifier
private struct StaggeredAppearanceModifier: ViewModifier {
    let index: Int
    let baseDelay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 20)
            .animation(
                reduceMotion ? .bscStandard : .bscSpring.delay(Double(index) * baseDelay),
                value: hasAppeared
            )
            .onAppear {
                hasAppeared = true
            }
    }
}

// MARK: - Shimmer Effect
extension View {
    func bscShimmer(isActive: Bool = true) -> some View {
        modifier(ShimmerModifier(isActive: isActive))
    }
}

private struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !reduceMotion {
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.2),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .offset(x: phase)
                    .mask(content)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 400
                }
            }
    }
}

// MARK: - Card Transition Helpers
enum BSCCardTransition {
    /// Calculate rotation for swipe gesture
    static func rotation(for offset: CGFloat, maxRotation: Double = 10) -> Double {
        let normalizedOffset = offset / 200
        return Double(normalizedOffset) * maxRotation
    }

    /// Calculate scale for card stack
    static func scale(for index: Int, maxScale: CGFloat = 1.0, scaleStep: CGFloat = 0.05) -> CGFloat {
        max(0.8, maxScale - (CGFloat(index) * scaleStep))
    }

    /// Calculate opacity for card stack
    static func opacity(for index: Int, maxOpacity: Double = 1.0, opacityStep: Double = 0.2) -> Double {
        max(0.4, maxOpacity - (Double(index) * opacityStep))
    }

    /// Calculate Y offset for card stack
    static func yOffset(for index: Int, offsetStep: CGFloat = 10) -> CGFloat {
        CGFloat(index) * offsetStep
    }
}
