//
//  ConversationViewModelAttachmentTests.swift
//  BumpSetCutTests
//
//  Attaching one of your posts inside a thread: it goes by id with the draft
//  as its caption, and the optimistic row carries the post so the bubble
//  renders before the server answers.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class ConversationViewModelAttachmentTests: XCTestCase {

    private func makeVM(client: MockMessagingClient) -> ConversationViewModel {
        ConversationViewModel(
            route: ConversationRoute(conversationId: "conv-1", summary: nil, otherUser: nil),
            currentUserId: "me",
            apiClient: client,
            inserts: { AsyncStream { $0.finish() } }
        )
    }

    private func highlight() -> Highlight {
        Highlight(
            id: "hl-1", authorId: "me", muxPlaybackId: "mux",
            rallyMetadata: RallyHighlightMetadata(duration: 5, confidence: 0.9, quality: 0.9, detectionCount: 12)
        )
    }

    func testAttachHighlight_sendsByIdWithDraftAsCaption() async {
        let client = MockMessagingClient()
        let vm = makeVM(client: client)

        vm.attach(highlight())
        vm.draftText = "  great set  "
        XCTAssertTrue(vm.canSend)
        await vm.send()

        XCTAssertEqual(client.calls, ["sendMessage"])
        let sent = client.sentParams.first
        XCTAssertEqual(sent?["p_attachment_type"] as? String, "highlight")
        XCTAssertEqual(sent?["p_highlight_id"] as? String, "hl-1")
        XCTAssertEqual(sent?["p_body"] as? String, "great set", "the draft becomes the caption, trimmed")
        XCTAssertEqual(vm.draftText, "")
        XCTAssertNil(vm.pendingAttachment)
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.delivery, .sent)
        XCTAssertEqual(vm.items.first?.message.attachmentType, .highlight, "the optimistic row carried the attachment")
    }

    func testSendFailure_marksFailed_andRetryResendsSamePost() async throws {
        let client = MockMessagingClient()
        client.sendError = APIError.networkUnavailable
        let vm = makeVM(client: client)

        vm.attach(highlight())
        await vm.send()
        XCTAssertEqual(vm.items.first?.delivery, .failed(.network))
        let itemId = try XCTUnwrap(vm.items.first?.id)

        client.sendError = nil
        await vm.retry(itemId)

        XCTAssertEqual(client.sentParams.count, 2)
        XCTAssertEqual(client.sentParams.last?["p_highlight_id"] as? String, "hl-1", "retry rebuilds the same attachment")
        XCTAssertEqual(vm.items.first?.delivery, .sent)
        XCTAssertEqual(vm.items.count, 1, "the retried item keeps its row")
    }

    func testCanSend_reflectsAttachmentState() {
        let vm = makeVM(client: MockMessagingClient())

        XCTAssertFalse(vm.canSend, "nothing to send")
        vm.attach(highlight())
        XCTAssertTrue(vm.canSend, "an attachment alone is enough")
        vm.clearAttachment()
        XCTAssertFalse(vm.canSend)
        vm.draftText = "hi"
        XCTAssertTrue(vm.canSend)
    }
}
