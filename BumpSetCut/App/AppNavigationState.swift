//
//  AppNavigationState.swift
//  BumpSetCut
//
//  Shared navigation state for cross-view communication (e.g. share → feed),
//  plus `bumpsetcut://` deep-link routing.
//

import Foundation
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
    /// Post opened from a `bumpsetcut://highlight/<id>` link, shown full-screen.
    var deepLinkedHighlight: Highlight?

    @ObservationIgnored private let apiClient: any APIClient

    init(apiClient: (any APIClient)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    /// Route `bumpsetcut://conversation/<id>` and `bumpsetcut://highlight/<id>`.
    ///
    /// The path component must be a real UUID before it reaches the backend —
    /// never pass arbitrary deep-link strings straight into a query. A post
    /// that fails to load (deleted, hidden, offline) simply doesn't open.
    func handleDeepLink(_ url: URL) async {
        guard url.scheme == "bumpsetcut" else { return }
        let id = url.lastPathComponent
        guard UUID(uuidString: id) != nil else { return }

        switch url.host {
        case "conversation":
            pendingConversationId = id
        case "highlight":
            if let highlight: Highlight = try? await apiClient.request(.getHighlight(id: id)) {
                deepLinkedHighlight = highlight
            }
        default:
            break
        }
    }
}
