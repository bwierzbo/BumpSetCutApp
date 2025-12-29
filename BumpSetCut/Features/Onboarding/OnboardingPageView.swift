//
//  OnboardingPageView.swift
//  BumpSetCut
//
//  Individual page view for onboarding tutorial
//

import SwiftUI

// MARK: - Onboarding Page View

struct OnboardingPageView: View {
    let page: OnboardingPage
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: BSCSpacing.xl) {
            Spacer()

            // Animated icon container
            ZStack {
                // Outer glow
                Circle()
                    .fill(page.color.opacity(0.1))
                    .frame(width: 200, height: 200)
                    .scaleEffect(isAnimating ? 1.1 : 1.0)

                // Inner circle
                Circle()
                    .fill(page.color.opacity(0.2))
                    .frame(width: 160, height: 160)

                // Icon
                Image(systemName: page.icon)
                    .font(.system(size: 64, weight: .medium))
                    .foregroundColor(page.color)
                    .scaleEffect(isAnimating ? 1.05 : 1.0)
            }
            .animation(
                .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                value: isAnimating
            )

            Spacer()
                .frame(height: BSCSpacing.xl)

            // Title
            Text(page.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.bscTextPrimary)
                .multilineTextAlignment(.center)

            // Description
            Text(page.description)
                .font(.system(size: 17))
                .foregroundColor(.bscTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: UIScreen.main.bounds.width - 80)

            Spacer()
            Spacer()
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Preview

#Preview("Onboarding Page") {
    ZStack {
        Color.bscBackground.ignoresSafeArea()
        OnboardingPageView(page: OnboardingPage.allPages[0])
    }
}
