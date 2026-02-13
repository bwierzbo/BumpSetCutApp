//
//  ModerationService.swift
//  BumpSetCut
//
//  Handles content reporting and user blocking.
//

import Foundation
import Observation

@MainActor
@Observable
final class ModerationService {

    // MARK: - Singleton
    static let shared = ModerationService()

    // MARK: - State
    private(set) var blockedUserIds: Set<UUID> = []
    private(set) var isLoadingBlocks = false

    // MARK: - Dependencies
    private let apiClient: SupabaseAPIClient

    // MARK: - Initialization

    private init(apiClient: SupabaseAPIClient = .shared) {
        self.apiClient = apiClient
    }

    // MARK: - Content Reporting

    /// Report a highlight
    func reportHighlight(
        _ highlightId: UUID,
        reportedUserId: UUID,
        type: ReportType,
        description: String?
    ) async throws {
        let request = CreateReportRequest(
            reportedType: .highlight,
            reportedId: highlightId,
            reportedUserId: reportedUserId,
            reportType: type,
            description: description
        )

        let _: ContentReport = try await apiClient.request(.createReport(request))
    }

    /// Report a comment
    func reportComment(
        _ commentId: UUID,
        reportedUserId: UUID,
        type: ReportType,
        description: String?
    ) async throws {
        let request = CreateReportRequest(
            reportedType: .comment,
            reportedId: commentId,
            reportedUserId: reportedUserId,
            reportType: type,
            description: description
        )

        let _: ContentReport = try await apiClient.request(.createReport(request))
    }

    /// Report a user profile
    func reportUser(
        _ userId: UUID,
        type: ReportType,
        description: String?
    ) async throws {
        let request = CreateReportRequest(
            reportedType: .userProfile,
            reportedId: userId,
            reportedUserId: userId,
            reportType: type,
            description: description
        )

        let _: ContentReport = try await apiClient.request(.createReport(request))
    }

    /// Get user's submitted reports
    func getMyReports(page: Int = 0) async throws -> [ContentReport] {
        return try await apiClient.request(.getMyReports(page: page))
    }

    // MARK: - User Blocking

    /// Block a user
    func blockUser(_ userId: UUID, reason: String? = nil) async throws {
        let block: UserBlock = try await apiClient.request(
            .blockUser(userId: userId.uuidString, reason: reason)
        )

        // Update local cache
        blockedUserIds.insert(block.blockedId)
    }

    /// Unblock a user
    func unblockUser(_ userId: UUID) async throws {
        let _: EmptyResponse = try await apiClient.request(
            .unblockUser(userId: userId.uuidString)
        )

        // Update local cache
        blockedUserIds.remove(userId)
    }

    /// Load blocked users list
    func loadBlockedUsers() async throws {
        isLoadingBlocks = true
        defer { isLoadingBlocks = false }

        let blocks: [UserBlock] = try await apiClient.request(.getBlockedUsers)

        blockedUserIds = Set(blocks.map { $0.blockedId })
    }

    /// Check if a user is blocked
    func isBlocked(_ userId: UUID) -> Bool {
        return blockedUserIds.contains(userId)
    }

    /// Check if user is blocked (remote check)
    func checkIfBlocked(_ userId: UUID) async throws -> Bool {
        let status: BlockStatusResult = try await apiClient.request(
            .isUserBlocked(userId: userId.uuidString)
        )
        return status.isBlocked
    }

    // MARK: - Filtering Helpers

    /// Filter out blocked users from a list of highlights
    func filterBlockedContent<T: Identifiable>(
        _ items: [T],
        getUserId: (T) -> UUID
    ) -> [T] {
        return items.filter { !isBlocked(getUserId($0)) }
    }

    /// Filter out blocked users from a list of user profiles
    func filterBlockedUsers(_ users: [UserProfile]) -> [UserProfile] {
        return users.filter { UUID(uuidString: $0.id).map { !isBlocked($0) } ?? true }
    }
}
