//
//  MessageRoutes.swift
//  BumpSetCut
//
//  Shared types for the messaging screens: how a thread is addressed, and how
//  a failed send is described to the person who tried.
//

import Foundation

/// Navigation value for a thread. The summary rides along when we already have
/// it (from the inbox) so the header renders before the fetch lands.
struct ConversationRoute: Hashable, Identifiable {
    let conversationId: String
    var summary: ConversationSummary?
    /// Known when opening from a profile, before any message exists.
    var otherUser: UserProfile?

    var id: String { conversationId }

    static func == (lhs: ConversationRoute, rhs: ConversationRoute) -> Bool {
        lhs.conversationId == rhs.conversationId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(conversationId)
    }
}

/// Why a send didn't go through, in words worth showing someone.
enum SendFailure: Error, Equatable {
    case messaging(DirectMessageError)
    case network
    case upload
    case unknown

    init(_ error: Error) {
        if let messaging = DirectMessageError(error) {
            self = .messaging(messaging)
        } else if error is URLError {
            self = .network
        } else if case APIError.networkUnavailable = error {
            self = .network
        } else if case APIError.uploadFailed = error {
            self = .upload
        } else {
            self = .unknown
        }
    }

    var userMessage: String {
        switch self {
        case .messaging(let error): return error.userMessage
        case .network: return "No connection. Tap to retry."
        case .upload: return "Couldn't upload that rally."
        case .unknown: return "Couldn't send. Tap to retry."
        }
    }

    /// A blocked or removed conversation won't start working on a retry.
    var isRetryable: Bool {
        switch self {
        case .messaging(let error):
            return error != .blocked && error != .notMember && error != .notFound
        case .network, .upload, .unknown:
            return true
        }
    }
}
