//
//  BlockedUsersViewModel.swift
//  BumpSetCut
//
//  The people the signed-in user has blocked, and undoing a block.
//

import Foundation
import Observation

@MainActor
@Observable
final class BlockedUsersViewModel {
    private(set) var profiles: [UserProfile] = []
    private(set) var isLoading = true
    /// The block list couldn't be loaded (distinct from "no one blocked").
    private(set) var loadFailed = false

    private let apiClient: any APIClient
    private let moderation = ModerationService.shared

    init(apiClient: (any APIClient)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    func load() async {
        isLoading = true
        loadFailed = false
        do {
            try await moderation.loadBlockedUsers()
        } catch {
            loadFailed = true
            isLoading = false
            return
        }
        var loaded: [UserProfile] = []
        for userId in moderation.blockedUserIds {
            // A profile that can't be fetched (deleted account) is left out.
            if let profile: UserProfile = try? await apiClient.request(.getProfile(userId: userId.uuidString.lowercased())) {
                loaded.append(profile)
            }
        }
        profiles = loaded.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
        isLoading = false
    }

    /// False when the unblock failed; the person stays in the list.
    func unblock(_ profile: UserProfile) async -> Bool {
        guard let userId = UUID(uuidString: profile.id) else { return false }
        do {
            try await moderation.unblockUser(userId)
            profiles.removeAll { $0.id == profile.id }
            return true
        } catch {
            return false
        }
    }
}
