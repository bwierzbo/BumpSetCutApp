import SwiftUI

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
    /// Apply press effect - Scale down when pressed
    func bscPressEffect(isPressed: Bool) -> some View {
        scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.bscQuick, value: isPressed)
    }

    /// Apply bounce effect - Spring scale animation
    func bscBounceEffect(isActive: Bool) -> some View {
        scaleEffect(isActive ? 1.05 : 1.0)
            .animation(.bscBounce, value: isActive)
    }

    /// Apply floating effect - Gentle up/down motion
    func bscFloatingEffect() -> some View {
        modifier(FloatingModifier())
    }

    /// Apply pulse glow effect
    func bscPulseGlow(color: Color = .bscOrange, isActive: Bool = true) -> some View {
        modifier(PulseGlowModifier(color: color, isActive: isActive))
    }

    /// Apply staggered appearance animation
    func bscStaggered(index: Int, baseDelay: Double = 0.05) -> some View {
        modifier(StaggeredAppearanceModifier(index: index, baseDelay: baseDelay))
    }
}

// MARK: - Floating Animation Modifier
private struct FloatingModifier: ViewModifier {
    @State private var isFloating = false

    func body(content: Content) -> some View {
        content
            .offset(y: isFloating ? -8 : 0)
            .animation(.bscFloat, value: isFloating)
            .onAppear { isFloating = true }
    }
}

// MARK: - Pulse Glow Modifier
private struct PulseGlowModifier: ViewModifier {
    let color: Color
    let isActive: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .shadow(
                color: isActive ? color.opacity(isPulsing ? 0.6 : 0.2) : .clear,
                radius: isPulsing ? 20 : 10,
                x: 0,
                y: 0
            )
            .animation(.bscPulse, value: isPulsing)
            .onAppear {
                if isActive { isPulsing = true }
            }
            .onChange(of: isActive) { _, newValue in
                isPulsing = newValue
            }
    }
}

// MARK: - Staggered Appearance Modifier
private struct StaggeredAppearanceModifier: ViewModifier {
    let index: Int
    let baseDelay: Double
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 20)
            .animation(
                .bscSpring.delay(Double(index) * baseDelay),
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
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
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
