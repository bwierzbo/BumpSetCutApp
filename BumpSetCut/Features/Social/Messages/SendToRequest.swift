//
//  SendToRequest.swift
//  BumpSetCut
//
//  What the "Send to Friend" entry points hand to a `.sheet(item:)`, and the
//  toast every presenter shows once the sheet reports success.
//

import Foundation

/// A pending send. A fresh id per request means the same rally can be sent
/// again right after — SwiftUI treats it as a new item, not a re-show.
struct SendToRequest: Identifiable {
    let id = UUID()
    let payload: SendToViewModel.Payload
}

extension BSCToastMessage {
    /// "Sent to @x" with a View action that opens the thread. Routed through
    /// AppNavigationState: Home owns the inbox sheet and pushes the route.
    @MainActor
    static func sent(to username: String, conversationId: String, navigationState: AppNavigationState) -> BSCToastMessage {
        BSCToastMessage(
            text: "Sent to @\(username)",
            style: .success,
            action: BSCToastAction(title: "View") {
                navigationState.pendingConversationId = conversationId
            }
        )
    }
}
