//
//  RecipientPickerViewModel.swift
//  BumpSetCut
//
//  Who to send a rally to. With no query: people you've messaged recently,
//  then people you follow. With a query: a user search. Never yourself, and
//  never someone you've blocked — the server would refuse the send anyway,
//  but they shouldn't be offered in the first place.
//

import Foundation
import Observation

@MainActor
@Observable
final class RecipientPickerViewModel {

    struct Section: Identifiable {
        let title: String
        let users: [UserProfile]
        var id: String { title }
    }

    var query = ""
    private(set) var results: [UserProfile] = []
    private(set) var recent: [UserProfile] = []
    private(set) var following: [UserProfile] = []
    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var loadFailed = false

    let currentUserId: String
    private let apiClient: any APIClient
    private var searchTask: Task<Void, Never>?

    init(currentUserId: String, apiClient: (any APIClient)? = nil) {
        self.currentUserId = currentUserId
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    var isQueryActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the list shows: search results while typing, otherwise Recent and
    /// Following. Someone in both appears only under Recent.
    var visibleSections: [Section] {
        if isQueryActive {
            let users = eligible(results)
            return users.isEmpty ? [] : [Section(title: "Results", users: users)]
        }
        let recentUsers = eligible(recent)
        let seen = Set(recentUsers.map(\.id))
        let followingUsers = eligible(following).filter { !seen.contains($0.id) }
        var sections: [Section] = []
        if !recentUsers.isEmpty { sections.append(Section(title: "Recent", users: recentUsers)) }
        if !followingUsers.isEmpty { sections.append(Section(title: "Following", users: followingUsers)) }
        return sections
    }

    // MARK: - Loading

    /// Recent and Following are independent — fetch them concurrently. A
    /// failure of either leaves the other's rows in place.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        loadFailed = false

        async let recentPage: [ConversationSummary] = apiClient.request(.getConversations(page: 0))
        async let followingPage: [FollowingWrapper] = apiClient.request(.getFollowing(userId: currentUserId, page: 0))

        do {
            recent = try await recentPage.map(\.otherUser)
        } catch is CancellationError {
            return
        } catch {
            loadFailed = true
        }
        do {
            following = try await followingPage.map(\.following)
        } catch is CancellationError {
            return
        } catch {
            loadFailed = true
        }
    }

    /// Debounced so a name typed quickly is one request, not one per key.
    func searchTextChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.search(trimmed)
        }
    }

    private func search(_ text: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let found: [UserProfile] = try await apiClient.request(.searchUsers(query: text, page: 0))
            // A later keystroke may have superseded this request.
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            results = found
        } catch is CancellationError {
        } catch {
            results = []
        }
    }

    // MARK: - Filtering

    private func eligible(_ users: [UserProfile]) -> [UserProfile] {
        let blocked = ModerationService.shared.blockedUserIds
        var seen = Set<String>()
        return users.filter { user in
            guard user.id != currentUserId, seen.insert(user.id).inserted else { return false }
            if let uuid = UUID(uuidString: user.id), blocked.contains(uuid) { return false }
            return true
        }
    }
}
