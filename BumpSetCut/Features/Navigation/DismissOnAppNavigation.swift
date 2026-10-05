//
//  DismissOnAppNavigation.swift
//  BumpSetCut
//
//  A modal (profile sheet, single-post cover) closes itself when something
//  inside it switches tabs or opens a message thread — otherwise the tab
//  changes underneath and the modal stays open over it. Nested modals chain:
//  each forwards to the changeTab of the one that presented it.
//

import SwiftUI

private struct DismissOnAppNavigation: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.changeTab) private var changeTab
    @Environment(AppNavigationState.self) private var navigationState

    func body(content: Content) -> some View {
        content
            .environment(\.changeTab) { tab in
                dismiss()
                changeTab(tab)
            }
            .onChange(of: navigationState.pendingMessageRecipientId) { _, recipient in
                if recipient != nil { dismiss() }
            }
    }
}

extension View {
    func dismissOnAppNavigation() -> some View {
        modifier(DismissOnAppNavigation())
    }
}
