//
//  ProfileSheet.swift
//  BumpSetCut
//
//  A profile presented modally from a full-screen post (feed, single-post
//  viewer), where there's no navigation stack to push onto.
//

import SwiftUI

struct ProfileSheet: View {
    let userId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProfileView(userId: userId)
                .toolbar {
                    // Pull-down fights the profile's own scroll/refresh, so
                    // give an explicit way out (tester feedback).
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier(AccessibilityID.Feed.profileDone)
                    }
                }
                // Its own NavigationStack, so it needs its own profile
                // destination for the follower/following lists.
                .profileNavigationDestinations()
        }
        .dismissOnAppNavigation()
        .presentationDragIndicator(.visible)
    }
}
