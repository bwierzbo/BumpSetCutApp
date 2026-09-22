//
//  DirectMessageModelsTests.swift
//  BumpSetCutTests
//
//  Decode contracts for the messaging models. Two different decoders are in
//  play: PostgREST rows go through the shared `.convertFromSnakeCase` decoder,
//  while Realtime rows arrive raw and are decoded with explicit CodingKeys.
//

import XCTest
@testable import BumpSetCut

final class DirectMessageModelsTests: XCTestCase {

    private var decoder: JSONDecoder { SupabaseConfig.jsonDecoder }
    private var encoder: JSONEncoder { SupabaseConfig.jsonEncoder }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Conversation overview

    func testConversationSummaryDecodesOverviewRow() throws {
        let json = """
        {
            "conversation_id": "c1",
            "user_id": "me",
            "my_status": "pending",
            "last_read_at": "2026-09-17T09:00:00Z",
            "other_user_id": "u2",
            "other_status": "accepted",
            "other_username": "sandy",
            "other_avatar_url": "https://cdn.example.com/avatars/u2/avatar.jpg",
            "created_at": "2026-09-17T08:00:00Z",
            "last_message_at": "2026-09-17T10:00:00Z",
            "last_message_preview": "nice dig",
            "last_message_attachment_type": null,
            "last_message_sender_id": "u2",
            "unread_count": 3
        }
        """
        let summary = try decode(ConversationSummary.self, from: json)

        XCTAssertEqual(summary.id, "c1")
        XCTAssertTrue(summary.isRequest)
        XCTAssertEqual(summary.unreadCount, 3)
        XCTAssertEqual(summary.lastMessagePreview, "nice dig")
        XCTAssertNil(summary.lastMessageAttachmentType)
        // The acronym trap: other_avatar_url -> otherAvatarUrl, never otherAvatarURL.
        XCTAssertEqual(summary.otherAvatarURL?.absoluteString,
                       "https://cdn.example.com/avatars/u2/avatar.jpg")
        XCTAssertEqual(summary.otherUser.username, "sandy")
    }

    /// Attachment-only messages carry no preview text; the client supplies it.
    func testConversationSummaryDecodesAttachmentOnlyPreview() throws {
        let json = """
        {
            "conversation_id": "c1", "user_id": "me", "my_status": "accepted",
            "last_read_at": "2026-09-17T09:00:00Z",
            "other_user_id": "u2", "other_status": "accepted", "other_username": "sandy",
            "other_avatar_url": null,
            "created_at": "2026-09-17T08:00:00Z", "last_message_at": "2026-09-17T10:00:00Z",
            "last_message_preview": null, "last_message_attachment_type": "clip",
            "last_message_sender_id": "u2", "unread_count": 0
        }
        """
        let summary = try decode(ConversationSummary.self, from: json)
        XCTAssertNil(summary.lastMessagePreview)
        XCTAssertEqual(summary.lastMessageAttachmentType, .clip)
        XCTAssertFalse(summary.isRequest)
    }

    // MARK: - Messages

    func testDirectMessageDecodesTextOnly() throws {
        let json = """
        {
            "id": "m1", "conversation_id": "c1", "sender_id": "u2", "recipient_id": "me",
            "body": "good game", "attachment_type": null, "highlight_id": null,
            "clip_path": null, "clip_duration": null,
            "created_at": "2026-09-17T10:00:00Z"
        }
        """
        let message = try decode(DirectMessage.self, from: json)
        XCTAssertNil(message.attachment)
        XCTAssertEqual(message.previewText, "good game")
        XCTAssertTrue(message.isMine("u2"))
        XCTAssertFalse(message.isMine("me"))
    }

    func testDirectMessageDecodesClipAttachment() throws {
        let json = """
        {
            "id": "m2", "conversation_id": "c1", "sender_id": "u2", "recipient_id": "me",
            "body": null, "attachment_type": "clip", "highlight_id": null,
            "clip_path": "u2/abc.mp4", "clip_duration": 12.5,
            "created_at": "2026-09-17T10:00:00Z"
        }
        """
        let message = try decode(DirectMessage.self, from: json)
        XCTAssertEqual(message.attachment, .clip(path: "u2/abc.mp4", duration: 12.5))
        XCTAssertEqual(message.previewText, "Sent a rally")
    }

    /// A deleted post nulls highlight_id via ON DELETE SET NULL, and RLS can
    /// null the embed — both must decode to an attachment the UI can mark
    /// "unavailable" rather than failing the whole message.
    func testDirectMessageDecodesHighlightAttachmentWithoutEmbed() throws {
        let json = """
        {
            "id": "m3", "conversation_id": "c1", "sender_id": "u2", "recipient_id": "me",
            "body": null, "attachment_type": "highlight", "highlight_id": "h1",
            "clip_path": null, "clip_duration": null,
            "created_at": "2026-09-17T10:00:00Z", "highlight": null
        }
        """
        let message = try decode(DirectMessage.self, from: json)
        XCTAssertEqual(message.attachment, .highlight(id: "h1", highlight: nil))
        XCTAssertEqual(message.previewText, "Sent a post")
    }

    // MARK: - Realtime rows

    func testRealtimeRowDecodesWithMicrosecondTimestamp() throws {
        let json = """
        {
            "id": "m4", "conversation_id": "c1", "sender_id": "u2", "recipient_id": "me",
            "body": "live one", "attachment_type": "highlight", "highlight_id": "h1",
            "clip_path": null, "clip_duration": null,
            "created_at": "2026-09-17T10:00:00.123456+00:00"
        }
        """
        // Realtime payloads are NOT decoded with the shared coder.
        let row = try JSONDecoder().decode(InsertedMessageRow.self, from: Data(json.utf8))
        let message = row.asMessage()

        XCTAssertEqual(message.id, "m4")
        XCTAssertEqual(message.conversationId, "c1")
        // Realtime never carries the embed, so a highlight arrives unhydrated.
        XCTAssertEqual(message.attachment, .highlight(id: "h1", highlight: nil))
        XCTAssertEqual(
            message.createdAt.timeIntervalSince1970,
            Date(timeIntervalSince1970: 1_789_639_200.123456).timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - Send parameters

    func testSendMessageParamsEncodeRPCArgumentNames() throws {
        let params = SendMessageParams.highlight("hl-9", in: "c1")
        let json = String(decoding: try encoder.encode(params), as: UTF8.self)

        XCTAssertTrue(json.contains("\"p_conversation_id\":\"c1\""))
        XCTAssertTrue(json.contains("\"p_attachment_type\":\"highlight\""))
        XCTAssertTrue(json.contains("\"p_highlight_id\":\"hl-9\""))
        // Nil arguments are omitted so the SQL DEFAULT NULLs apply.
        XCTAssertFalse(json.contains("p_clip_path"))
        XCTAssertFalse(json.contains("p_body"))
    }

    func testDeviceTokenRegistrationEncodesRPCArgumentNames() throws {
        let json = String(decoding: try encoder.encode(
            DeviceTokenRegistration(token: "abc123", environment: .sandbox)
        ), as: UTF8.self)
        XCTAssertTrue(json.contains("\"p_token\":\"abc123\""))
        XCTAssertTrue(json.contains("\"p_environment\":\"sandbox\""))
    }

    // MARK: - Error mapping

    func testDirectMessageErrorMapsServerPrefixes() {
        func error(_ message: String) -> Error {
            APIError.serverError(statusCode: 400, message: message)
        }

        XCTAssertEqual(DirectMessageError(error("DM_BLOCKED: cannot message this user")), .blocked)
        XCTAssertEqual(DirectMessageError(error("DM_SELF: cannot message yourself")), .selfMessage)
        XCTAssertEqual(DirectMessageError(error("DM_NOT_MEMBER: not a member")), .notMember)
        XCTAssertEqual(DirectMessageError(error("DM_TOO_LONG: too long")), .tooLong)
        XCTAssertEqual(DirectMessageError(error("DM_EMPTY: empty")), .empty)
        XCTAssertEqual(DirectMessageError(error("DM_NOT_FOUND: gone")), .notFound)
        XCTAssertEqual(DirectMessageError(error("DM_BAD_ATTACHMENT: nope")), .badAttachment)

        // Anything else stays unmapped so the generic handler deals with it.
        XCTAssertNil(DirectMessageError(error("some other failure")))
        XCTAssertNil(DirectMessageError(APIError.networkUnavailable))
    }
}
