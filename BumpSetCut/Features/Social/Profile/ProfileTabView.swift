//
//  ProfileTabView.swift
//  BumpSetCut
//
//  Own-profile tab wrapper that shows AuthGateView when not signed in.
//

import SwiftUI

struct ProfileTabView: View {
    @Environment(AuthenticationService.self) private var authService

    var body: some View {
        Group {
            if authService.isAuthenticated, let user = authService.currentUser {
                ProfileView(userId: user.id)
            } else {
                AuthGateView()
            }
        }
    }
}
