//
//  DirectMessageServiceTests.swift
//  BumpSetCutTests
//
//  Live-message routing: every listener gets every insert, the open thread
//  never toasts itself, and badges come from the server rather than local
//  arithmetic.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class DirectMessageServiceTests: XCTestCase {

    private func message(
        id: String = "m1",
        conversationId: String = "c1",
        senderId: String = "u2",
        body: String? = "hey"
    ) -> DirectMessage {
        DirectMessage(id: id, conversationId: conversationId, senderId: senderId,
                      recipientId: "me", body: body)
    }

    // MARK: - Fan-out

    func testEverySubscriberReceivesTheInsert() async {
        let service = DirectMessageService(apiClient: MockMessagesClient())
        var first: [String] = []
        var second: [String] = []

        let streamA = service.inserts()
        let streamB = service.inserts()
        let taskA = Task { for await m in streamA { first.append(m.id) } }
        let taskB = Task { for await m in streamB { second.append(m.id) } }

        await service.handleIncoming(message(), isAppActive: true)
        // Give the consuming tasks a turn.
        try? await Task.sleep(for: .milliseconds(50))
        taskA.cancel(); taskB.cancel()

        XCTAssertEqual(first, ["m1"], "the inbox listener missed the insert")
        XCTAssertEqual(second, ["m1"], "the thread listener missed the insert")
    }

    func testStopFinishesEveryStream() async {
        let service = DirectMessageService(apiClient: MockMessagesClient())
        var finished = false
        let stream = service.inserts()
        let task = Task { for await _ in stream {}; finished = true }

        service.stop()
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        XCTAssertTrue(finished, "stop() should end the stream so listeners don't hang")
    }

    // MARK: - Toast suppression

    func testMessageForTheOpenThreadDoesNotToast() async {
        let mock = MockMessagesClient()
        let service = DirectMessageService(apiClient: mock)
        service.activeConversationId = "c1"

        await service.handleIncoming(message(conversationId: "c1"), isAppActive: true)

        XCTAssertNil(service.incomingToast, "the open thread shows the message itself")
        XCTAssertEqual(mock.unreadCountCalls, 0, "no need to refresh: the thread marks itself read")
    }

    func testMessageForAnotherConversationToastsAndRefreshes() async {
        let mock = MockMessagesClient()
        mock.unread = 4
        mock.pending = 1
        mock.summary = ConversationSummary(
            conversationId: "c2", myStatus: .accepted, lastReadAt: Date(),
            otherUserId: "u2", otherStatus: .accepted, otherUsername: "sandy",
            otherAvatarURL: nil, createdAt: Date(), lastMessageAt: Date(),
            lastMessagePreview: "hey", lastMessageAttachmentType: nil,
            lastMessageSenderId: "u2", unreadCount: 1
        )
        let service = DirectMessageService(apiClient: mock)
        service.activeConversationId = "c1"
        await service.adopt(userId: "me")

        await service.handleIncoming(message(conversationId: "c2"), isAppActive: true)

        XCTAssertEqual(service.unreadCount, 4)
        XCTAssertEqual(service.pendingRequestCount, 1)
        XCTAssertEqual(service.incomingToast?.conversationId, "c2")
        XCTAssertEqual(service.incomingToast?.text, "sandy: hey")
    }

    /// A message from someone you don't follow reads differently — it's an
    /// introduction, not a reply.
    func testRequestToastReadsAsAnIntroduction() async {
        let mock = MockMessagesClient()
        mock.summary = ConversationSummary(
            conversationId: "c3", myStatus: .pending, lastReadAt: Date(),
            otherUserId: "u3", otherStatus: .accepted, otherUsername: "newcomer",
            otherAvatarURL: nil, createdAt: Date(), lastMessageAt: Date(),
            lastMessagePreview: "hi", lastMessageAttachmentType: nil,
            lastMessageSenderId: "u3", unreadCount: 1
        )
        let service = DirectMessageService(apiClient: mock)
        await service.adopt(userId: "me")

        await service.handleIncoming(message(conversationId: "c3", senderId: "u3"), isAppActive: true)

        XCTAssertEqual(service.incomingToast?.text, "newcomer wants to message you")
    }

    // MARK: - Push tokens

    func testDeviceTokenIsRegisteredAsLowercaseHex() async {
        let mock = MockMessagesClient()
        let service = DirectMessageService(apiClient: mock)
        await service.adopt(userId: "me")

        await service.registerDeviceToken(Data([0x00, 0xab, 0xff, 0x10]))

        XCTAssertEqual(mock.registeredTokens.first?.token, "00abff10")
        XCTAssertEqual(mock.registeredTokens.first?.environment, DirectMessageService.apnsEnvironment)
    }

    func testUnregisterUsesTheCachedToken() async {
        let mock = MockMessagesClient()
        let service = DirectMessageService(apiClient: mock)
        await service.adopt(userId: "me")
        await service.registerDeviceToken(Data([0xde, 0xad]))

        await service.unregisterDeviceToken()

        XCTAssertEqual(mock.deletedTokens, ["dead"])
    }
}

// MARK: - Mock client

private final class MockMessagesClient: APIClient, @unchecked Sendable {
    nonisolated(unsafe) var unread = 0
    nonisolated(unsafe) var pending = 0
    nonisolated(unsafe) var summary: ConversationSummary?
    nonisolated(unsafe) var unreadCountCalls = 0
    nonisolated(unsafe) var registeredTokens: [DeviceTokenRegistration] = []
    nonisolated(unsafe) var deletedTokens: [String] = []

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        switch endpoint {
        case .unreadMessageCount:
            unreadCountCalls += 1
            guard let cast = unread as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .pendingRequestCount:
            guard let cast = pending as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .getConversation:
            guard let summary, let cast = summary as? T else {
                throw APIError.serverError(statusCode: 404, message: "no summary")
            }
            return cast
        case .markConversationRead:
            guard let cast = EmptyResponse() as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .registerDeviceToken(let registration):
            registeredTokens.append(registration)
            guard let cast = EmptyResponse() as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .deleteDeviceToken(let token):
            deletedTokens.append(token)
            guard let cast = EmptyResponse() as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
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
