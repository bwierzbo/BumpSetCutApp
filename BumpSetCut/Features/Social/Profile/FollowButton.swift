//
//  FollowButton.swift
//  BumpSetCut
//
//  Follow / Following toggle, the same everywhere a person is listed.
//

import SwiftUI

struct FollowButton: View {
    let isFollowing: Bool
    var isFullWidth: Bool = false
    let action: () -> Void

    var body: some View {
        BSCButton(
            title: isFollowing ? "Following" : "Follow",
            style: isFollowing ? .secondary : .primary,
            size: .small,
            isFullWidth: isFullWidth,
            action: action
        )
    }
}
