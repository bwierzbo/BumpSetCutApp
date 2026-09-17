//
//  ProfileTabView.swift
//  BumpSetCut
//
//  Own-profile tab wrapper that shows AuthGateView when not signed in.
//

import SwiftUI

struct ProfileTabView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.changeTab) private var changeTab

    var body: some View {
        Group {
            if authService.isAuthenticated, let user = authService.currentUser {
                ProfileView(userId: user.id)
            } else {
                AuthGateView(onSkip: {
                    changeTab(.home)
                })
            }
        }
        // Registered once for the whole tab stack. A follower list can sit at
        // any depth (profile → followers → profile → followers), and each one
        // declaring its own String destination would be a duplicate
        // registration — SwiftUI drops the second push and you bounce back to
        // the list you tapped from.
        .navigationDestination(for: String.self) { userId in
            ProfileView(userId: userId)
        }
    }
}
