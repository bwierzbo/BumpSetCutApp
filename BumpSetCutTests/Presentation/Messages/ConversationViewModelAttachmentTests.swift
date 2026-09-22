//
//  ConversationViewModelAttachmentTests.swift
//  BumpSetCutTests
//
//  Attaching a rally inside a thread: a post goes by id with the draft as
//  its caption; a clip is exported, uploaded, then sent; a failed upload
//  can be retried and re-exports rather than reusing a file that may be gone.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class ConversationViewModelAttachmentTests: XCTestCase {

    private func makeVM(client: MockMessagingClient,
                        media: MockMediaClient,
                        exportClip: (@Sendable (FavoriteShareClip) async throws -> URL)? = nil) -> ConversationViewModel {
        ConversationViewModel(
            route: ConversationRoute(conversationId: "conv-1", summary: nil, otherUser: nil),
            currentUserId: "me",
            apiClient: client,
            media: media,
            inserts: { AsyncStream { $0.finish() } },
            exportClip: exportClip
        )
    }

    private func highlight() -> Highlight {
        Highlight(
            id: "hl-1", authorId: "me", muxPlaybackId: "mux",
            rallyMetadata: RallyHighlightMetadata(duration: 5, confidence: 0.9, quality: 0.9, detectionCount: 12)
        )
    }

    private func clip() -> FavoriteShareClip {
        FavoriteShareClip(url: URL(fileURLWithPath: "/tmp/source.mp4"), timeRange: nil, duration: 7.5, displayName: "Rally 3")
    }

    // Called from the injected @Sendable exporter, off the main actor.
    private nonisolated func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attach-test-\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: url)
        return url
    }

    func testAttachHighlight_sendsByIdWithDraftAsCaption() async {
        let client = MockMessagingClient()
        let vm = makeVM(client: client, media: MockMediaClient())

        vm.attach(.highlight(highlight()))
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

    func testAttachClip_exportsUploadsThenSends_andCleansUp() async throws {
        let client = MockMessagingClient()
        let media = MockMediaClient()
        let exported = try tempFile()
        let exportBox = CallBox()
        let vm = makeVM(client: client, media: media) { _ in exportBox.record("export"); return exported }

        vm.attach(.clip(clip()))
        await vm.send()

        XCTAssertEqual(exportBox.calls, ["export"])
        XCTAssertEqual(media.uploadedFiles, [exported])
        XCTAssertEqual(client.calls, ["sendMessage"])
        let sent = client.sentParams.first
        XCTAssertEqual(sent?["p_attachment_type"] as? String, "clip")
        XCTAssertEqual(sent?["p_clip_path"] as? String, "them/clip.mp4")
        XCTAssertEqual(sent?["p_clip_duration"] as? Double, 7.5)
        XCTAssertNil(sent?["p_body"] as? String, "no draft, no caption")
        XCTAssertEqual(vm.items.first?.delivery, .sent)
        XCTAssertNil(vm.attachmentProgress, "progress is cleared once the send finishes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path), "exported temp file is removed")
    }

    func testClipUploadFailure_marksFailed_withoutSending_andRetryReExports() async throws {
        let client = MockMessagingClient()
        let media = MockMediaClient()
        media.uploadError = APIError.networkUnavailable
        let exportBox = CallBox()
        let vm = makeVM(client: client, media: media) { _ in exportBox.record("export"); return try self.tempFile() }

        vm.attach(.clip(clip()))
        await vm.send()

        XCTAssertEqual(vm.items.first?.delivery, .failed(.network))
        XCTAssertTrue(client.sentParams.isEmpty, "no message row is created for a clip that never uploaded")
        XCTAssertNil(vm.attachmentProgress)
        let itemId = try XCTUnwrap(vm.items.first?.id)

        media.uploadError = nil
        await vm.retry(itemId)

        XCTAssertEqual(exportBox.calls, ["export", "export"], "retry re-exports rather than reusing the earlier file")
        XCTAssertEqual(media.uploadedFiles.count, 2)
        XCTAssertEqual(client.sentParams.count, 1)
        XCTAssertEqual(vm.items.first?.delivery, .sent)
        XCTAssertEqual(vm.items.count, 1, "the retried item keeps its row")
    }

    func testCanSend_reflectsAttachmentAndUploadState() {
        let vm = makeVM(client: MockMessagingClient(), media: MockMediaClient())

        XCTAssertFalse(vm.canSend, "nothing to send")
        vm.attach(.highlight(highlight()))
        XCTAssertTrue(vm.canSend, "an attachment alone is enough")
        vm.clearAttachment()
        XCTAssertFalse(vm.canSend)
        vm.draftText = "hi"
        XCTAssertTrue(vm.canSend)
    }
}
