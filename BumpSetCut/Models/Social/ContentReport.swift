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
            return "Spam"
        case .harassment:
            return "Harassment or Bullying"
        case .inappropriateContent:
            return "Inappropriate Content"
        case .impersonation:
            return "Impersonation"
        case .violence:
            return "Violence or Threats"
        case .hateSpeech:
            return "Hate Speech"
        case .selfHarm:
            return "Self-Harm or Suicide"
        case .other:
            return "Other"
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
            return "Unwanted commercial content or repetitive posts"
        case .harassment:
            return "Bullying, threats, or harassment"
        case .inappropriateContent:
            return "Nudity, violence, or other inappropriate content"
        case .impersonation:
            return "Pretending to be someone else"
        case .violence:
            return "Threats of violence or graphic content"
        case .hateSpeech:
            return "Content that attacks people based on protected characteristics"
        case .selfHarm:
            return "Content promoting self-harm or suicide"
        case .other:
            return "Something else not listed here"
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
            return "Pending Review"
        case .reviewed:
            return "Reviewed"
        case .actionTaken:
            return "Action Taken"
        case .dismissed:
            return "Dismissed"
        }
    }
}

// MARK: - Reported Content Type

enum ReportedContentType: String, Codable {
    case highlight
    case comment
    case userProfile = "user_profile"
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

    enum CodingKeys: String, CodingKey {
        case id
        case reporterId = "reporter_id"
        case reportedType = "reported_type"
        case reportedId = "reported_id"
        case reportedUserId = "reported_user_id"
        case reportType = "report_type"
        case description
        case status
        case reviewedAt = "reviewed_at"
        case reviewedBy = "reviewed_by"
        case moderatorNotes = "moderator_notes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Create Report Request

struct CreateReportRequest: Codable {
    let reportedType: ReportedContentType
    let reportedId: UUID
    let reportedUserId: UUID?
    let reportType: ReportType
    let description: String?

    enum CodingKeys: String, CodingKey {
        case reportedType = "reported_type"
        case reportedId = "reported_id"
        case reportedUserId = "reported_user_id"
        case reportType = "report_type"
        case description
    }
}

// MARK: - User Block Model

struct UserBlock: Codable, Identifiable {
    let id: UUID
    let blockerId: UUID
    let blockedId: UUID
    let reason: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case blockerId = "blocker_id"
        case blockedId = "blocked_id"
        case reason
        case createdAt = "created_at"
    }
}

// MARK: - Create Block Request

struct CreateBlockRequest: Codable {
    let blockedId: UUID
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case blockedId = "blocked_id"
        case reason
    }
}
