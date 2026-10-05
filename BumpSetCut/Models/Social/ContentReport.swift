//
//  ContentReport.swift
//  BumpSetCut
//
//  Models for content reporting and moderation.
//

import Foundation

// MARK: - Report Type

enum ReportType: String, Codable, CaseIterable {
    case spam
    case harassment
    case inappropriateContent = "inappropriate_content"
    case impersonation
    case violence
    case hateSpeech = "hate_speech"
    case selfHarm = "self_harm"
    case other

    var displayName: String {
        switch self {
        case .spam:
            return String(localized: "Spam", comment: "Report reason")
        case .harassment:
            return String(localized: "Harassment or Bullying", comment: "Report reason")
        case .inappropriateContent:
            return String(localized: "Inappropriate Content", comment: "Report reason")
        case .impersonation:
            return String(localized: "Impersonation", comment: "Report reason")
        case .violence:
            return String(localized: "Violence or Threats", comment: "Report reason")
        case .hateSpeech:
            return String(localized: "Hate Speech", comment: "Report reason")
        case .selfHarm:
            return String(localized: "Self-Harm or Suicide", comment: "Report reason")
        case .other:
            return String(localized: "Other", comment: "Report reason")
        }
    }

    var icon: String {
        switch self {
        case .spam:
            return "envelope.badge.fill"
        case .harassment:
            return "exclamationmark.bubble.fill"
        case .inappropriateContent:
            return "eye.slash.fill"
        case .impersonation:
            return "person.fill.questionmark"
        case .violence:
            return "exclamationmark.triangle.fill"
        case .hateSpeech:
            return "hand.raised.fill"
        case .selfHarm:
            return "heart.fill"
        case .other:
            return "ellipsis.circle.fill"
        }
    }

    var description: String {
        switch self {
        case .spam:
            return String(localized: "Unwanted commercial content or repetitive posts", comment: "Report reason explanation")
        case .harassment:
            return String(localized: "Bullying, threats, or harassment", comment: "Report reason explanation")
        case .inappropriateContent:
            return String(localized: "Nudity, violence, or other inappropriate content", comment: "Report reason explanation")
        case .impersonation:
            return String(localized: "Pretending to be someone else", comment: "Report reason explanation")
        case .violence:
            return String(localized: "Threats of violence or graphic content", comment: "Report reason explanation")
        case .hateSpeech:
            return String(localized: "Content that attacks people based on protected characteristics", comment: "Report reason explanation")
        case .selfHarm:
            return String(localized: "Content promoting self-harm or suicide", comment: "Report reason explanation")
        case .other:
            return String(localized: "Something else not listed here", comment: "Report reason explanation")
        }
    }
}

// MARK: - Report Status

enum ReportStatus: String, Codable {
    case pending
    case reviewed
    case actionTaken = "action_taken"
    case dismissed

    var displayName: String {
        switch self {
        case .pending:
            return String(localized: "Pending Review", comment: "Report status")
        case .reviewed:
            return String(localized: "Reviewed", comment: "Report status")
        case .actionTaken:
            return String(localized: "Action Taken", comment: "Report status")
        case .dismissed:
            return String(localized: "Dismissed", comment: "Report status")
        }
    }
}

// MARK: - Reported Content Type

enum ReportedContentType: String, Codable {
    case highlight
    case comment
    case userProfile = "user_profile"
    case message
}

// MARK: - Content Report Model

struct ContentReport: Codable, Identifiable {
    let id: UUID
    let reporterId: UUID
    let reportedType: ReportedContentType
    let reportedId: UUID
    let reportedUserId: UUID?
    let reportType: ReportType
    let description: String?
    let status: ReportStatus
    let reviewedAt: Date?
    let reviewedBy: UUID?
    let moderatorNotes: String?
    let createdAt: Date
    let updatedAt: Date

    // Keys are intentionally camelCase: the shared Supabase coder applies
    // `.convertFromSnakeCase`/`.convertToSnakeCase`, so explicit snake_case raw
    // values would NOT match (the strategy transforms the payload key first) and
    // would throw `keyNotFound` on decode. Stay consistent with the other models.
}

// MARK: - Create Report Request

struct CreateReportRequest: Codable {
    let reportedType: ReportedContentType
    let reportedId: UUID
    let reportedUserId: UUID?
    let reportType: ReportType
    let description: String?
    // camelCase keys; the shared coder snake_cases them on encode (see ContentReport).
}

// MARK: - User Block Model

struct UserBlock: Codable, Identifiable {
    let id: UUID
    let blockerId: UUID
    let blockedId: UUID
    let reason: String?
    let createdAt: Date
    // camelCase keys; the shared coder snake_cases them (see ContentReport).
}

// MARK: - Create Block Request

struct CreateBlockRequest: Codable {
    let blockedId: UUID
    let reason: String?
    // camelCase keys; the shared coder snake_cases them on encode (see ContentReport).
}
