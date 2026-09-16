//
//  NotificationsViewModelTests.swift
//  BumpSetCutTests
//
//  Notification center VM: paging, dedupe, mark-read badge clearing, and
//  the SocialNotification decode contract (snake_case + "type" → kind).
//

import XCTest
@testable import BumpSetCut

@MainActor
final class NotificationsViewModelTests: XCTestCase {

    // MARK: - Decode contract

    func testDecodesSnakeCaseRowWithEmbeddedActor() throws {
        let json = """
        {
            "id": "n1",
            "recipient_id": "me",
            "actor_id": "u2",
            "type": "comment_like",
            "highlight_id": "h1",
            "comment_id": "c1",
            "read_at": null,
            "created_at": "2026-09-15T12:00:00Z",
            "actor": { "id": "u2", "username": "sandy", "created_at": "2026-01-01T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let notification = try decoder.decode(SocialNotification.self, from: json)
        XCTAssertEqual(notification.kind, .commentLike)
        XCTAssertEqual(notification.highlightId, "h1")
        XCTAssertEqual(notification.actor?.username, "sandy")
        XCTAssertFalse(notification.isRead)
        XCTAssertEqual(notification.message, "liked your comment")
    }

    // MARK: - View model

    func testLoadInitialPopulatesAndClearsBadge() async {
        let client = MockNotificationsClient()
        client.pages = [[Self.notification(id: "a"), Self.notification(id: "b")]]
        let viewModel = NotificationsViewModel(apiClient: client)

        await viewModel.loadInitial()

        XCTAssertEqual(viewModel.notifications.map(\.id), ["a", "b"])
        XCTAssertFalse(viewModel.hasMorePages) // short page → no more
        XCTAssertEqual(client.markedReadCount, 1)
        XCTAssertEqual(SocialNotificationService.shared.unreadCount, 0)
    }

    func testLoadMoreDeduplicatesOverlappingPage() async {
        let client = MockNotificationsClient()
        let fullPage = (0..<30).map { Self.notification(id: "p0-\($0)") }
        client.pages = [fullPage, [Self.notification(id: "p0-29"), Self.notification(id: "fresh")]]
        let viewModel = NotificationsViewModel(apiClient: client)

        await viewModel.loadInitial()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.notifications.count, 31)
        XCTAssertEqual(viewModel.notifications.last?.id, "fresh")
    }

    func testLoadFailureSetsFlag() async {
        let client = MockNotificationsClient()
        client.shouldFail = true
        let viewModel = NotificationsViewModel(apiClient: client)

        await viewModel.loadInitial()

        XCTAssertTrue(viewModel.loadFailed)
        XCTAssertTrue(viewModel.notifications.isEmpty)
    }

    // MARK: - Helpers

    private static func notification(id: String, kind: SocialNotification.Kind = .like) -> SocialNotification {
        SocialNotification(
            id: id,
            recipientId: "me",
            actorId: "u2",
            kind: kind,
            highlightId: kind == .follow ? nil : "h1",
            commentId: nil,
            readAt: nil,
            createdAt: Date(),
            actor: nil
        )
    }
}

// MARK: - Mock client

private final class MockNotificationsClient: APIClient, @unchecked Sendable {
    nonisolated(unsafe) var pages: [[SocialNotification]] = []
    nonisolated(unsafe) var markedReadCount = 0
    nonisolated(unsafe) var shouldFail = false

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        if shouldFail { throw APIError.networkUnavailable }
        switch endpoint {
        case .getNotifications(let page):
            let result = page < pages.count ? pages[page] : []
            guard let cast = result as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .markAllNotificationsRead:
            markedReadCount += 1
            guard let cast = EmptyResponse() as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .getUnreadNotificationCount:
            guard let cast = 0 as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        default:
            throw APIError.serverError(statusCode: 501, message: "not used")
        }
    }

    func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }

    func submitFlywheelContribution(_ contribution: FlywheelContribution, frameURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }
}
