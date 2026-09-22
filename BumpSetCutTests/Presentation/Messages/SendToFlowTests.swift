//
//  SendToFlowTests.swift
//  BumpSetCutTests
//
//  Sending a post to a friend: conversation first (so a blocked recipient
//  fails before anything else), then the message row referencing the post.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class SendToFlowTests: XCTestCase {

    private let them = UserProfile(id: "them", username: "sandy")

    private func highlight() -> Highlight {
        Highlight(
            id: "hl-1", authorId: "someone", muxPlaybackId: "mux",
            rallyMetadata: RallyHighlightMetadata(duration: 5, confidence: 0.9, quality: 0.9, detectionCount: 12)
        )
    }

    /// Wait for the view model's background task to leave `previous` and reach
    /// a terminal phase. `send()` only spawns the task; a check made before it
    /// runs would still see the phase it started from.
    private func settle(_ vm: SendToViewModel, leaving previous: SendToViewModel.Phase = .idle, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (vm.isBusy || vm.phase == previous), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testCreatesConversationThenSendsInOrder() async {
        let client = MockMessagingClient()
        let vm = SendToViewModel(highlight: highlight(), apiClient: client)
        vm.choose(them)
        vm.send()
        await settle(vm)

        XCTAssertEqual(vm.phase, .sent(conversationId: "conv-1", username: "sandy"))
        XCTAssertEqual(client.calls, ["getOrCreateConversation:them", "sendMessage"])
        let sent = client.sentParams.first
        XCTAssertEqual(sent?["p_conversation_id"] as? String, "conv-1")
        XCTAssertEqual(sent?["p_attachment_type"] as? String, "highlight")
        XCTAssertEqual(sent?["p_highlight_id"] as? String, "hl-1")
        XCTAssertNil(sent?["p_body"] as? String, "empty note must not become a body")
    }

    func testNoteIsTrimmedAndSentAsCaption() async {
        let client = MockMessagingClient()
        let vm = SendToViewModel(highlight: highlight(), apiClient: client)
        vm.note = "  nice one  "
        vm.choose(them)
        vm.send()
        await settle(vm)

        XCTAssertEqual(client.sentParams.first?["p_body"] as? String, "nice one")
    }

    // MARK: - Failures

    func testBlocked_failsBeforeSending_andIsNotRetryable() async {
        let client = MockMessagingClient()
        client.conversationError = APIError.serverError(statusCode: 400, message: "DM_BLOCKED: cannot message this user")
        let vm = SendToViewModel(highlight: highlight(), apiClient: client)
        vm.choose(them)
        vm.send()
        await settle(vm)

        XCTAssertEqual(vm.phase, .failed(.messaging(.blocked)))
        XCTAssertEqual(vm.failure?.isRetryable, false)
        XCTAssertFalse(client.calls.contains("sendMessage"), "a blocked recipient must fail before any message is sent")
    }

    func testNetworkFailure_isRetryable_andRetrySucceeds() async {
        let client = MockMessagingClient()
        client.sendError = APIError.networkUnavailable
        let vm = SendToViewModel(highlight: highlight(), apiClient: client)
        vm.choose(them)
        vm.send()
        await settle(vm)
        XCTAssertEqual(vm.phase, .failed(.network))
        XCTAssertEqual(vm.failure?.isRetryable, true)

        client.sendError = nil
        vm.retry()
        await settle(vm, leaving: .failed(.network))
        XCTAssertEqual(vm.phase, .sent(conversationId: "conv-1", username: "sandy"))
        XCTAssertEqual(client.sentParams.count, 2, "retry re-sends rather than reusing the failed attempt")
    }

    func testChangeRecipient_clearsSelectionAndFailure() async {
        let client = MockMessagingClient()
        client.conversationError = APIError.networkUnavailable
        let vm = SendToViewModel(highlight: highlight(), apiClient: client)
        vm.choose(them)
        vm.send()
        await settle(vm)
        XCTAssertNotNil(vm.failure)

        vm.changeRecipient()
        XCTAssertNil(vm.recipient)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertFalse(vm.canSend)
    }
}

// MARK: - Shared test doubles

/// Records calls from `@Sendable` closures without actor hops.
final class CallBox: @unchecked Sendable {
    nonisolated(unsafe) private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

/// Messaging API double. Conversation and send can each be made to fail;
/// sent params are captured as the wire dictionary the RPC would receive.
final class MockMessagingClient: APIClient, @unchecked Sendable {
    nonisolated(unsafe) var calls: [String] = []
    nonisolated(unsafe) var sentParams: [[String: Any]] = []
    nonisolated(unsafe) var conversationError: Error?
    nonisolated(unsafe) var sendError: Error?
    nonisolated(unsafe) var conversations: [ConversationSummary] = []
    nonisolated(unsafe) var following: [UserProfile] = []
    nonisolated(unsafe) var followingError: Error?
    nonisolated(unsafe) var searchResults: [UserProfile] = []

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        switch endpoint {
        case .getOrCreateConversation(let otherUserId):
            calls.append("getOrCreateConversation:\(otherUserId)")
            if let conversationError { throw conversationError }
            return try cast("conv-1")
        case .sendMessage(let params):
            calls.append("sendMessage")
            let data = try JSONEncoder().encode(params)
            let wire = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            sentParams.append(wire)
            if let sendError { throw sendError }
            // Echo the row the way the RPC does — attachment fields included —
            // so a merge into the optimistic item keeps what was sent.
            return try cast(DirectMessage(
                id: "m-\(sentParams.count)",
                conversationId: wire["p_conversation_id"] as? String ?? "conv-1",
                senderId: "me",
                recipientId: "them",
                body: wire["p_body"] as? String,
                attachmentType: (wire["p_attachment_type"] as? String).flatMap(DirectMessage.AttachmentType.init(rawValue:)),
                highlightId: wire["p_highlight_id"] as? String
            ))
        case .getConversations:
            return try cast(conversations)
        case .getFollowing:
            if let followingError { throw followingError }
            return try cast(following.map { FollowingWrapper(following: $0) })
        case .searchUsers:
            return try cast(searchResults)
        default:
            throw APIError.serverError(statusCode: 501, message: "not used: \(endpoint)")
        }
    }

    private func cast<T>(_ value: Any) throws -> T {
        guard let cast = value as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
        return cast
    }

    func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }

    func submitFlywheelContribution(_ contribution: FlywheelContribution, frameURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }
}
