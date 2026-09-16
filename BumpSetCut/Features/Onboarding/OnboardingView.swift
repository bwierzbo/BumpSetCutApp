//
//  OnboardingView.swift
//  BumpSetCut
//
//  Fullscreen carousel onboarding tutorial
//

import SwiftUI
import UserNotifications

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
                        Button {
                            onComplete()
                        } label: {
                            Text("Skip")
                                .bscFont(size: 16, weight: .medium)
                                .foregroundColor(.bscTextSecondary)
                                .padding(.horizontal, BSCSpacing.lg)
                                .padding(.top, BSCSpacing.md)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
                        }
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
                .animation(.bscStandard, value: currentPage)

                // Footer with page indicator and button
                OnboardingFooter(
                    currentPage: currentPage,
                    totalPages: pages.count,
                    isNotificationsPage: pages[currentPage].kind == .notifications,
                    onNext: {
                        if pages[currentPage].kind == .notifications {
                            enableNotifications()
                        } else {
                            advance()
                        }
                    },
                    onNotNow: advance
                )
                .padding(.bottom, BSCSpacing.xl)
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.bscStandard) {
                hasAppeared = true
            }
        }
    }

    private func advance() {
        if currentPage < pages.count - 1 {
            withAnimation(.bscStandard) {
                currentPage += 1
            }
        } else {
            onComplete()
        }
    }

    /// Show the real system prompt from the page that explains it, then move
    /// on whatever the answer. Under UI testing the alert would block
    /// automation, so the page just advances.
    private func enableNotifications() {
        guard !CommandLine.arguments.contains("--uitesting") else {
            advance()
            return
        }
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            advance()
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
                    .animation(.bscEmphasized, value: currentPage)

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
    let isNotificationsPage: Bool
    let onNext: () -> Void
    let onNotNow: () -> Void

    private var isLastPage: Bool {
        currentPage == totalPages - 1
    }

    private var primaryTitle: String {
        if isLastPage { return "Get Started" }
        return isNotificationsPage ? "Enable Notifications" : "Next"
    }

    private var primaryIcon: String? {
        if isLastPage { return nil }
        return isNotificationsPage ? "bell.fill" : "arrow.right"
    }

    var body: some View {
        VStack(spacing: BSCSpacing.lg) {
            // Page indicator dots
            HStack(spacing: BSCSpacing.sm) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.bscPrimary : Color.bscTextSecondary.opacity(0.6))
                        .frame(width: index == currentPage ? 10 : 8, height: index == currentPage ? 10 : 8)
                        .animation(.bscSnappy, value: currentPage)
                }
            }

            // Next / Enable Notifications / Get Started button
            Button(action: onNext) {
                HStack(spacing: BSCSpacing.sm) {
                    Text(primaryTitle)
                        .bscFont(size: 18, weight: .bold)

                    if let primaryIcon {
                        Image(systemName: primaryIcon)
                            .bscFont(size: 16, weight: .bold)
                    }
                }
                .foregroundColor(.bscOnPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BSCSpacing.lg)
                .background(LinearGradient.bscPrimaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
                .bscShadow(BSCShadow.glowPrimary)
            }
            .buttonStyle(OnboardingButtonStyle())
            .padding(.horizontal, BSCSpacing.xl)
            .accessibilityIdentifier(isLastPage ? AccessibilityID.Onboarding.getStarted : AccessibilityID.Onboarding.next)

            // "Not Now" escape for the notifications page. Always laid out so
            // the footer height doesn't jump between pages; hidden elsewhere.
            Button(action: onNotNow) {
                Text("Not Now")
                    .bscFont(size: 16, weight: .medium)
                    .foregroundColor(.bscTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .opacity(isNotificationsPage ? 1 : 0)
            .allowsHitTesting(isNotificationsPage)
            .accessibilityHidden(!isNotificationsPage)
            .accessibilityIdentifier(AccessibilityID.Onboarding.notNow)
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
