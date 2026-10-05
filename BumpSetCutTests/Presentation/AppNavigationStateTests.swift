//
//  AppNavigationStateTests.swift
//  BumpSetCutTests
//
//  `bumpsetcut://` deep-link routing: only well-formed UUID links reach the
//  backend, and a post that fails to load simply doesn't open.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class AppNavigationStateTests: XCTestCase {

    private let validId = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    func testHighlightLinkFetchesAndPresentsThePost() async {
        let client = MockHighlightClient()
        let state = AppNavigationState(apiClient: client)

        await state.handleDeepLink(URL(string: "bumpsetcut://highlight/\(validId)")!)

        XCTAssertEqual(client.requestedIds, [validId])
        XCTAssertEqual(state.deepLinkedHighlight?.id, validId)
    }

    func testConversationLinkRoutesWithoutNetwork() async {
        let client = MockHighlightClient()
        let state = AppNavigationState(apiClient: client)

        await state.handleDeepLink(URL(string: "bumpsetcut://conversation/\(validId)")!)

        XCTAssertEqual(state.pendingConversationId, validId)
        XCTAssertTrue(client.requestedIds.isEmpty)
    }

    func testNonUUIDOrForeignLinksAreIgnored() async {
        let client = MockHighlightClient()
        let state = AppNavigationState(apiClient: client)

        await state.handleDeepLink(URL(string: "bumpsetcut://highlight/not-a-uuid")!)
        await state.handleDeepLink(URL(string: "https://highlight/\(validId)")!)
        await state.handleDeepLink(URL(string: "bumpsetcut://unknown/\(validId)")!)

        XCTAssertTrue(client.requestedIds.isEmpty)
        XCTAssertNil(state.deepLinkedHighlight)
        XCTAssertNil(state.pendingConversationId)
    }

    func testFailedFetchLeavesNothingPresented() async {
        let client = MockHighlightClient()
        client.shouldFail = true
        let state = AppNavigationState(apiClient: client)

        await state.handleDeepLink(URL(string: "bumpsetcut://highlight/\(validId)")!)

        XCTAssertNil(state.deepLinkedHighlight)
    }
}

// MARK: - Mock client

private final class MockHighlightClient: APIClient, @unchecked Sendable {
    nonisolated(unsafe) var requestedIds: [String] = []
    nonisolated(unsafe) var shouldFail = false

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        guard case .getHighlight(let id) = endpoint else {
            throw APIError.serverError(statusCode: 501, message: "not used")
        }
        requestedIds.append(id)
        if shouldFail { throw APIError.networkUnavailable }
        let highlight = Highlight(
            id: id, authorId: "someone", muxPlaybackId: "mux",
            rallyMetadata: RallyHighlightMetadata(duration: 5, confidence: 0.9, quality: 0.9, detectionCount: 12)
        )
        guard let cast = highlight as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
        return cast
    }

    func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }

    func submitFlywheelContribution(_ contribution: FlywheelContribution, frameURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }
}
