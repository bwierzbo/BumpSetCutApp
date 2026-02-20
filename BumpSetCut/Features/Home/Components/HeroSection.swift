import SwiftUI

// MARK: - HeroSection
/// Animated hero section with volleyball branding
struct HeroSection: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: BSCSpacing.sm) {
            // Animated volleyball icon
            volleyballIcon

            // Title + tagline
            titleSection
        }
        .onAppear {
            // Delay floating animation to not conflict with intro animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
        }
    }

    // MARK: - Volleyball Icon
    private var volleyballIcon: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscPrimary.opacity(0.3), Color.clear],
                        center: .center,
                        startRadius: 30,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)

            // Icon background
            Circle()
                .fill(Color.bscSurfaceGlass)
                .frame(width: 80, height: 80)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient.bscPrimaryGradient,
                            lineWidth: 3
                        )
                )

            // Volleyball icon
            Image(systemName: "figure.volleyball")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(LinearGradient.bscPrimaryGradient)
                .offset(y: isAnimating ? -3 : 0)
        }
    }

    // MARK: - Title Section
    private var titleSection: some View {
        VStack(spacing: 4) {
            Text("BumpSetCut")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.bscTextPrimary)

            Text("Rally Detection AI")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.bscTextSecondary)
                .tracking(1.5)
                .textCase(.uppercase)
        }
    }
}

// MARK: - Preview
#Preview("HeroSection") {
    HeroSection()
        .padding()
        .background(Color.bscBackground)
}
