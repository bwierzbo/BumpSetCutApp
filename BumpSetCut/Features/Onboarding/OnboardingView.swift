//
//  OnboardingView.swift
//  BumpSetCut
//
//  Fullscreen carousel onboarding tutorial
//

import SwiftUI

// MARK: - Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentPage = 0
    @State private var hasAppeared = false

    private let pages = OnboardingPage.allPages

    var body: some View {
        ZStack {
            // Background
            Color.bscBackground
                .ignoresSafeArea()

            // Gradient orbs
            backgroundGradient

            VStack(spacing: 0) {
                // Skip button (top right)
                HStack {
                    Spacer()
                    if currentPage < pages.count - 1 {
                        Button("Skip") {
                            onComplete()
                        }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.bscTextSecondary)
                        .padding(.horizontal, BSCSpacing.lg)
                        .padding(.top, BSCSpacing.md)
                        .accessibilityIdentifier(AccessibilityID.Onboarding.skip)
                    }
                }
                .frame(height: 44)

                // Page content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        OnboardingPageView(page: page)
                            .tag(index)
                            .accessibilityIdentifier(AccessibilityID.Onboarding.page(index))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                // Footer with page indicator and button
                OnboardingFooter(
                    currentPage: currentPage,
                    totalPages: pages.count,
                    onNext: {
                        if currentPage < pages.count - 1 {
                            withAnimation {
                                currentPage += 1
                            }
                        } else {
                            onComplete()
                        }
                    }
                )
                .padding(.bottom, BSCSpacing.xl)
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        GeometryReader { geo in
            ZStack {
                // Top gradient orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [pages[currentPage].color.opacity(0.12), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 300
                        )
                    )
                    .frame(width: 600, height: 600)
                    .offset(x: -geo.size.width * 0.1, y: -geo.size.height * 0.3)
                    .animation(.easeInOut(duration: 0.5), value: currentPage)

                // Bottom gradient orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.bscBlue.opacity(0.06), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 200
                        )
                    )
                    .frame(width: 400, height: 400)
                    .offset(x: geo.size.width * 0.2, y: geo.size.height * 0.35)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Onboarding Footer

private struct OnboardingFooter: View {
    let currentPage: Int
    let totalPages: Int
    let onNext: () -> Void

    private var isLastPage: Bool {
        currentPage == totalPages - 1
    }

    var body: some View {
        VStack(spacing: BSCSpacing.lg) {
            // Page indicator dots
            HStack(spacing: BSCSpacing.sm) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.bscPrimary : Color.white.opacity(0.3))
                        .frame(width: index == currentPage ? 10 : 8, height: index == currentPage ? 10 : 8)
                        .animation(.spring(response: 0.3), value: currentPage)
                }
            }

            // Next / Get Started button
            Button(action: onNext) {
                HStack(spacing: BSCSpacing.sm) {
                    Text(isLastPage ? "Get Started" : "Next")
                        .font(.system(size: 18, weight: .bold))

                    if !isLastPage {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundColor(.bscTextInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BSCSpacing.lg)
                .background(LinearGradient.bscPrimaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
                .bscShadow(BSCShadow.glowOrange)
            }
            .buttonStyle(OnboardingButtonStyle())
            .padding(.horizontal, BSCSpacing.xl)
            .accessibilityIdentifier(isLastPage ? AccessibilityID.Onboarding.getStarted : AccessibilityID.Onboarding.next)
        }
    }
}

// MARK: - Button Style

private struct OnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.bscBounce, value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview("Onboarding") {
    OnboardingView(onComplete: {})
}
