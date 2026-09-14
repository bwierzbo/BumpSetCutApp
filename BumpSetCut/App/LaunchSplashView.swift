//
//  LaunchSplashView.swift
//  BumpSetCut
//
//  Animated continuation of the static launch screen. Renders the identical
//  background + rounded logo the system launch screen shows, so the handoff
//  is seamless, then springs the logo and fades into the app.
//

import SwiftUI

struct LaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinished: () -> Void

    @State private var logoScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color("LaunchBackground")

            Image("LaunchLogo")
                .resizable()
                .frame(width: 160, height: 160)
                .scaleEffect(logoScale)
        }
        .ignoresSafeArea()
        .task {
            if !reduceMotion {
                withAnimation(.bscBounce.delay(0.1)) {
                    logoScale = 1.08
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            onFinished()
        }
    }
}

#Preview {
    LaunchSplashView {}
}
