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
    private var hasLoadedBlocks = false

    /// Content this user reported, hidden from their own feeds immediately and
    /// across launches (device-local; the server-side report is the source of
    /// truth for moderation).
    private(set) var reportedHighlightIds: Set<UUID>
    private(set) var reportedCommentIds: Set<UUID>

    private static let reportedHighlightsKey = "moderation.reportedHighlightIds"
    private static let reportedCommentsKey = "moderation.reportedCommentIds"

    // MARK: - Dependencies
    private let apiClient: SupabaseAPIClient

    // MARK: - Initialization

    private init(apiClient: SupabaseAPIClient = .shared) {
        self.apiClient = apiClient
        reportedHighlightIds = Self.loadReportedIds(forKey: Self.reportedHighlightsKey)
        reportedCommentIds = Self.loadReportedIds(forKey: Self.reportedCommentsKey)
    }

    private static func loadReportedIds(forKey key: String) -> Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private func persistReportedIds() {
        UserDefaults.standard.set(reportedHighlightIds.map(\.uuidString), forKey: Self.reportedHighlightsKey)
        UserDefaults.standard.set(reportedCommentIds.map(\.uuidString), forKey: Self.reportedCommentsKey)
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

        // Hide it from the reporter's own feeds right away.
        reportedHighlightIds.insert(highlightId)
        persistReportedIds()
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

        reportedCommentIds.insert(commentId)
        persistReportedIds()
    }

    /// Report a direct message. Unlike highlights and comments there's no feed
    /// to hide it from — the report goes to moderation and the sender can be
    /// blocked separately.
    func reportMessage(
        _ messageId: UUID,
        reportedUserId: UUID,
        type: ReportType,
        description: String?
    ) async throws {
        let request = CreateReportRequest(
            reportedType: .message,
            reportedId: messageId,
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
        hasLoadedBlocks = true
    }

    /// Load the block list once per sign-in; feeds call this before their
    /// first filter so blocks survive app relaunch.
    func ensureBlocksLoaded() async {
        guard !hasLoadedBlocks, !isLoadingBlocks else { return }
        try? await loadBlockedUsers()
    }

    /// Clear the signed-in user's block cache (reported-content hides are
    /// device-local and intentionally survive sign-out).
    func resetForSignOut() {
        blockedUserIds = []
        hasLoadedBlocks = false
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

    /// Whether a highlight should be hidden from this user's feeds
    /// (author blocked, or the user reported it).
    func isHighlightHidden(id: String, authorId: String) -> Bool {
        if let highlightId = UUID(uuidString: id), reportedHighlightIds.contains(highlightId) {
            return true
        }
        guard let author = UUID(uuidString: authorId) else { return false }
        return blockedUserIds.contains(author)
    }

    /// Whether a comment should be hidden from this user
    /// (author blocked, or the user reported it).
    func isCommentHidden(id: String, authorId: String) -> Bool {
        if let commentId = UUID(uuidString: id), reportedCommentIds.contains(commentId) {
            return true
        }
        guard let author = UUID(uuidString: authorId) else { return false }
        return blockedUserIds.contains(author)
    }

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
