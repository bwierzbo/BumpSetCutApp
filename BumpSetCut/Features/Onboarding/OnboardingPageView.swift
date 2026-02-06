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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { geometry in
            if isLandscape {
                landscapeLayout(geometry: geometry)
            } else {
                portraitLayout(geometry: geometry)
            }
        }
        .onAppear {
            isAnimating = true
        }
    }

    // MARK: - Portrait Layout
    private func portraitLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: BSCSpacing.xl) {
            Spacer()

            iconView(size: 200, iconSize: 64)

            Spacer()
                .frame(height: BSCSpacing.xl)

            textContent(maxWidth: geometry.size.width - 80)

            Spacer()
            Spacer()
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    // MARK: - Landscape Layout
    private func landscapeLayout(geometry: GeometryProxy) -> some View {
        HStack(spacing: BSCSpacing.xl) {
            // Left: icon
            iconView(size: 120, iconSize: 44)
                .frame(maxWidth: geometry.size.width * 0.35, maxHeight: .infinity)

            // Right: text
            VStack(spacing: BSCSpacing.md) {
                Spacer()
                textContent(maxWidth: geometry.size.width * 0.5)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    // MARK: - Icon View
    private func iconView(size: CGFloat, iconSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(page.color.opacity(0.1))
                .frame(width: size, height: size)
                .scaleEffect(isAnimating ? 1.1 : 1.0)

            Circle()
                .fill(page.color.opacity(0.2))
                .frame(width: size * 0.8, height: size * 0.8)

            Image(systemName: page.icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(page.color)
                .scaleEffect(isAnimating ? 1.05 : 1.0)
        }
        .animation(
            .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
            value: isAnimating
        )
    }

    // MARK: - Text Content
    private func textContent(maxWidth: CGFloat) -> some View {
        VStack(spacing: BSCSpacing.sm) {
            Text(page.title)
                .font(.system(size: isLandscape ? 22 : 28, weight: .bold))
                .foregroundColor(.bscTextPrimary)
                .multilineTextAlignment(.center)

            Text(page.description)
                .font(.system(size: isLandscape ? 15 : 17))
                .foregroundColor(.bscTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: maxWidth)
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
