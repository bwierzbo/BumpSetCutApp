//
//  AppNavigationState.swift
//  BumpSetCut
//
//  Shared navigation state for cross-view communication (e.g. share → feed).
//

import Observation

@MainActor
@Observable
final class AppNavigationState {
    var postedHighlight: Highlight?
    /// Set to route to the Search tab pre-filled with this query (e.g. tapping a post's location).
    var pendingSearchQuery: String?
    /// Conversation to open (push tap, deep link, or a "View" toast action).
    var pendingConversationId: String?
    /// Person to open a thread with — the inbox creates or finds it first.
    var pendingMessageRecipientId: String?
}
