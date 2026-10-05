//
//  HighlightDetailViewModel.swift
//  BumpSetCut
//
//  Backs the single-post viewer: holds the post so a like updates in place,
//  and deletes it when it's the viewer's own.
//

import Foundation
import Observation

@MainActor
@Observable
final class HighlightDetailViewModel {
    private(set) var highlight: Highlight
    /// Transient message for a failed action; the view shows it as a toast.
    var actionError: String?

    private let apiClient: any APIClient

    init(highlight: Highlight, apiClient: (any APIClient)? = nil) {
        self.highlight = highlight
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    func toggleLike() async {
        let succeeded = await HighlightLikeToggle.toggle(highlight, apiClient: apiClient) { _, mutate in
            mutate(&highlight)
        }
        if !succeeded { actionError = "Couldn't update like" }
    }

    /// Returns true once the post is gone.
    func delete() async -> Bool {
        do {
            let _: EmptyResponse = try await apiClient.request(.deleteHighlight(id: highlight.id))
            return true
        } catch {
            actionError = "Couldn't delete post"
            return false
        }
    }
}
