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

    /// Row text after the actor's username ("benw *liked your rally*").
    var message: String {
        switch kind {
        case .like: return "liked your rally"
        case .follow: return "started following you"
        case .comment: return "commented on your rally"
        case .commentLike: return "liked your comment"
        }
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
