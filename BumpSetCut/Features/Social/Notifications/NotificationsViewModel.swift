//
//  NotificationsViewModel.swift
//  BumpSetCut
//
//  Backs the notification center: pages through the user's notifications,
//  marks everything read on open, and resolves taps (follow → profile,
//  like/comment → the highlight).
//

import Foundation
import Observation

@MainActor
@Observable
final class NotificationsViewModel {

    private(set) var notifications: [SocialNotification] = []
    private(set) var isLoading = false
    private(set) var hasMorePages = true
    private(set) var loadFailed = false

    /// Highlight opened from a like/comment row.
    var openedHighlight: Highlight?

    private let apiClient: any APIClient
    private var page = 0
    private static let pageSize = 30

    init(apiClient: (any APIClient)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            page = 0
            let first: [SocialNotification] = try await apiClient.request(.getNotifications(page: 0))
            notifications = first
            hasMorePages = first.count == Self.pageSize
            await markAllRead()
        } catch {
            loadFailed = true
        }
    }

    func loadMore() async {
        guard !isLoading, hasMorePages else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next: [SocialNotification] = try await apiClient.request(.getNotifications(page: page + 1))
            page += 1
            // Marking-read races the page fetch; dedupe on id.
            let known = Set(notifications.map(\.id))
            notifications.append(contentsOf: next.filter { !known.contains($0.id) })
            hasMorePages = next.count == Self.pageSize
        } catch {
            hasMorePages = false
        }
    }

    /// Rows stay visually "new" for this open (readAt untouched locally);
    /// the badge clears immediately.
    private func markAllRead() async {
        guard notifications.contains(where: { !$0.isRead }) else {
            SocialNotificationService.shared.clearBadge()
            return
        }
        let _: EmptyResponse? = try? await apiClient.request(.markAllNotificationsRead)
        SocialNotificationService.shared.clearBadge()
    }

    /// For like/comment rows: fetch the highlight so the caller can present it.
    func openHighlight(for notification: SocialNotification) async {
        guard let highlightId = notification.highlightId else { return }
        openedHighlight = try? await apiClient.request(.getHighlight(id: highlightId))
    }
}
