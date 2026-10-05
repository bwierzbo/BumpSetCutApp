//
//  SocialNotification.swift
//  BumpSetCut
//
//  One row in the notification center: someone liked / commented on /
//  followed you. Rows are created server-side by triggers; the client only
//  reads them and marks them read.
//

import Foundation

struct SocialNotification: Codable, Identifiable, Hashable {

    enum Kind: String, Codable {
        case like
        case follow
        case comment
        case commentLike = "comment_like"
    }

    let id: String
    let recipientId: String
    let actorId: String
    let kind: Kind
    let highlightId: String?
    let commentId: String?
    var readAt: Date?
    let createdAt: Date

    /// Embedded `actor:profiles!actor_id(*)`.
    var actor: UserProfile?

    var isRead: Bool { readAt != nil }

    /// The whole row sentence with the actor's name as an argument, so word
    /// order is translatable ("sam liked your rally"). The name keeps any
    /// styling the caller gave it (bold in the notification row).
    func sentence(actor: AttributedString) -> AttributedString {
        switch kind {
        case .like:
            return AttributedString(localized: "\(actor) liked your rally", comment: "Notification row; %@ is the username")
        case .follow:
            return AttributedString(localized: "\(actor) started following you", comment: "Notification row; %@ is the username")
        case .comment:
            return AttributedString(localized: "\(actor) commented on your rally", comment: "Notification row; %@ is the username")
        case .commentLike:
            return AttributedString(localized: "\(actor) liked your comment", comment: "Notification row; %@ is the username")
        }
    }

    /// Plain-text form of `sentence(actor:)` (same keys), for VoiceOver.
    func sentence(actor: String) -> String {
        String(sentence(actor: AttributedString(actor)).characters)
    }

    var iconName: String {
        switch kind {
        case .like: return "heart.fill"
        case .follow: return "person.badge.plus"
        case .comment: return "bubble.left.fill"
        case .commentLike: return "heart"
        }
    }

    // Keys are matched after the decoder's `.convertFromSnakeCase` pass, so
    // raw values here are camelCase; only `kind` renames a column ("type").
    private enum CodingKeys: String, CodingKey {
        case id, recipientId, actorId, highlightId, commentId, readAt, createdAt, actor
        case kind = "type"
    }
}
