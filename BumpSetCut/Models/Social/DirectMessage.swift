//
//  DirectMessage.swift
//  BumpSetCut
//
//  1:1 conversations. A message is text and/or one attachment — an existing
//  feed post, or a clip uploaded privately just for this conversation.
//

import Foundation

// MARK: - Membership

enum MemberStatus: String, Codable, Hashable {
    case accepted
    /// A message from someone you don't follow: it waits in Requests.
    case pending
}

// MARK: - Conversation Summary

/// One row of the `conversation_overview` view. The other participant's
/// profile fields are flattened into the row (the view derives two users from
/// the same table, which would make a PostgREST embed ambiguous).
struct ConversationSummary: Codable, Identifiable, Hashable {
    let conversationId: String
    let myStatus: MemberStatus
    let lastReadAt: Date
    let otherUserId: String
    let otherStatus: MemberStatus
    let otherUsername: String
    let otherAvatarURL: URL?
    let createdAt: Date
    let lastMessageAt: Date?
    /// Nil for attachment-only messages — the client supplies the wording.
    let lastMessagePreview: String?
    let lastMessageAttachmentType: DirectMessage.AttachmentType?
    let lastMessageSenderId: String?
    var unreadCount: Int

    var id: String { conversationId }
    var isRequest: Bool { myStatus == .pending }

    /// Enough of a profile for an avatar and a name; fetch `.getProfile` for more.
    var otherUser: UserProfile {
        UserProfile(id: otherUserId, username: otherUsername, avatarURL: otherAvatarURL)
    }

    private enum CodingKeys: String, CodingKey {
        case conversationId, myStatus, lastReadAt, otherUserId, otherStatus, otherUsername
        case createdAt, lastMessageAt, lastMessagePreview, lastMessageAttachmentType
        case lastMessageSenderId, unreadCount
        // `.convertFromSnakeCase` turns other_avatar_url into otherAvatarUrl —
        // same acronym trap as UserProfile.avatarURL.
        case otherAvatarURL = "otherAvatarUrl"
    }
}

// MARK: - Attachment

enum MessageAttachment: Hashable {
    /// `id` nil means the post was deleted; `highlight` nil means it's hidden
    /// from this viewer or simply not hydrated yet (realtime rows never carry it).
    case highlight(id: String?, highlight: Highlight?)
    case clip(path: String, duration: Double?)
}

// MARK: - Direct Message

struct DirectMessage: Codable, Identifiable, Hashable {
    enum AttachmentType: String, Codable, Hashable {
        case highlight, clip
    }

    let id: String
    let conversationId: String
    let senderId: String
    let recipientId: String
    let body: String?
    let attachmentType: AttachmentType?
    let highlightId: String?
    let clipPath: String?
    let clipDuration: Double?
    let createdAt: Date
    /// Embedded `highlight:highlights!highlight_id(*)`. Nil when deleted, when
    /// RLS hides it, or when the row came from realtime.
    var highlight: Highlight?

    init(id: String, conversationId: String, senderId: String, recipientId: String,
         body: String? = nil, attachmentType: AttachmentType? = nil,
         highlightId: String? = nil, clipPath: String? = nil, clipDuration: Double? = nil,
         createdAt: Date = Date(), highlight: Highlight? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.recipientId = recipientId
        self.body = body
        self.attachmentType = attachmentType
        self.highlightId = highlightId
        self.clipPath = clipPath
        self.clipDuration = clipDuration
        self.createdAt = createdAt
        self.highlight = highlight
    }

    var attachment: MessageAttachment? {
        switch attachmentType {
        case .highlight: return .highlight(id: highlightId, highlight: highlight)
        case .clip: return clipPath.map { .clip(path: $0, duration: clipDuration) }
        case nil: return nil
        }
    }

    func isMine(_ userId: String) -> Bool { senderId == userId }

    /// What the inbox shows when this is the latest message.
    var previewText: String {
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return body }
        return attachmentType == .highlight ? "Sent a post" : "Sent a rally"
    }
}

// MARK: - Send Parameters

/// Arguments for the `send_message` RPC. Nil values are omitted so the SQL
/// DEFAULT NULLs apply.
struct SendMessageParams: Encodable, Equatable {
    let conversationId: String
    var body: String?
    var attachmentType: DirectMessage.AttachmentType?
    var highlightId: String?
    var clipPath: String?
    var clipDuration: Double?

    init(conversationId: String, body: String? = nil,
         attachmentType: DirectMessage.AttachmentType? = nil,
         highlightId: String? = nil, clipPath: String? = nil, clipDuration: Double? = nil) {
        self.conversationId = conversationId
        self.body = body
        self.attachmentType = attachmentType
        self.highlightId = highlightId
        self.clipPath = clipPath
        self.clipDuration = clipDuration
    }

    // Pinned to the SQL argument names — the global `.convertToSnakeCase`
    // strategy would produce `conversation_id`, not `p_conversation_id`.
    enum CodingKeys: String, CodingKey {
        case conversationId = "p_conversation_id"
        case body = "p_body"
        case attachmentType = "p_attachment_type"
        case highlightId = "p_highlight_id"
        case clipPath = "p_clip_path"
        case clipDuration = "p_clip_duration"
    }

    static func text(_ body: String, in conversationId: String) -> SendMessageParams {
        SendMessageParams(conversationId: conversationId, body: body)
    }

    static func highlight(_ id: String, caption: String? = nil, in conversationId: String) -> SendMessageParams {
        SendMessageParams(conversationId: conversationId, body: caption,
                          attachmentType: .highlight, highlightId: id)
    }

    static func clip(path: String, duration: Double?, caption: String? = nil,
                     in conversationId: String) -> SendMessageParams {
        SendMessageParams(conversationId: conversationId, body: caption,
                          attachmentType: .clip, clipPath: path, clipDuration: duration)
    }
}

// MARK: - Device Token

struct DeviceTokenRegistration: Encodable, Equatable {
    enum Environment: String, Encodable, Equatable { case production, sandbox }

    let token: String
    let environment: Environment

    enum CodingKeys: String, CodingKey {
        case token = "p_token"
        case environment = "p_environment"
    }
}

// MARK: - Errors

/// The messaging RPCs raise with a stable `DM_*` prefix so the client can say
/// something useful instead of surfacing raw Postgres text.
enum DirectMessageError: Error, Equatable {
    case blocked
    case selfMessage
    case notMember
    case tooLong
    case empty
    case notFound
    case badAttachment

    init?(_ error: Error) {
        guard case APIError.serverError(_, let message?) = error else { return nil }
        switch message.split(separator: ":").first.map(String.init) {
        case "DM_BLOCKED": self = .blocked
        case "DM_SELF": self = .selfMessage
        case "DM_NOT_MEMBER": self = .notMember
        case "DM_TOO_LONG": self = .tooLong
        case "DM_EMPTY": self = .empty
        case "DM_NOT_FOUND": self = .notFound
        case "DM_BAD_ATTACHMENT": self = .badAttachment
        default: return nil
        }
    }

    var userMessage: String {
        switch self {
        case .blocked: return "You can't message this person"
        case .selfMessage: return "You can't message yourself"
        case .notMember: return "You're no longer in this conversation"
        case .tooLong: return "Messages are limited to 2000 characters"
        case .empty: return "Add a message or a rally first"
        case .notFound: return "This conversation no longer exists"
        case .badAttachment: return "That rally couldn't be attached"
        }
    }
}
