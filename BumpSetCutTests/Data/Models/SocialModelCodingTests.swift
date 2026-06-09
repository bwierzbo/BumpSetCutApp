//
//  SocialModelCodingTests.swift
//  BumpSetCutTests
//
//  Guards the Supabase models against silent key-mapping bugs.
//
//  The shared Supabase coder uses `.convertFromSnakeCase` / `.convertToSnakeCase`.
//  That strategy has two traps these tests lock down:
//    1. Acronym fields — `avatar_url` decodes as `avatarUrl`, never matching an
//       `avatarURL` CodingKey (Foundation lowercases acronyms). Such fields must
//       pin their raw value.
//    2. Explicit snake_case CodingKeys — they do NOT work under the strategy
//       (the payload key is transformed first), so models must use camelCase keys.
//
//  Every model is decoded through the EXACT production decoder, so any future
//  field that drifts from the DB column naming fails here instead of silently
//  becoming nil / throwing in production.
//

import XCTest
@testable import BumpSetCut

final class SocialModelCodingTests: XCTestCase {

    private var decoder: JSONDecoder { SupabaseConfig.jsonDecoder }
    private var encoder: JSONEncoder { SupabaseConfig.jsonEncoder }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - UserProfile (regression: avatar_url)

    func testUserProfileDecodesAllColumns() throws {
        let json = """
        {
            "id": "u1",
            "username": "alice",
            "avatar_url": "https://cdn.example.com/avatars/u1/avatar.jpg",
            "bio": "setter",
            "team_name": "Spikers",
            "followers_count": 3,
            "following_count": 5,
            "highlights_count": 2,
            "privacy_level": "followers_only",
            "created_at": "2026-01-15T14:30:45Z"
        }
        """
        let profile = try decode(UserProfile.self, from: json)

        // The bug we fixed: this was always nil.
        XCTAssertEqual(profile.avatarURL?.absoluteString,
                       "https://cdn.example.com/avatars/u1/avatar.jpg")
        XCTAssertEqual(profile.teamName, "Spikers")
        XCTAssertEqual(profile.followersCount, 3)
        XCTAssertEqual(profile.followingCount, 5)
        XCTAssertEqual(profile.highlightsCount, 2)
        XCTAssertEqual(profile.privacyLevel, .followersOnly)
    }

    // MARK: - Highlight (regression: thumbnail_url + nested author/metadata)

    func testHighlightDecodesIncludingNestedAuthorAndMetadata() throws {
        let json = """
        {
            "id": "h1",
            "author_id": "u1",
            "author": {
                "id": "u1",
                "username": "alice",
                "avatar_url": "https://cdn.example.com/avatars/u1/avatar.jpg",
                "followers_count": 0,
                "following_count": 0,
                "highlights_count": 1,
                "privacy_level": "public",
                "created_at": "2026-01-15T14:30:45Z"
            },
            "mux_playback_id": "https://video.example.com/playlist.m3u8",
            "thumbnail_url": "https://cdn.example.com/thumbs/h1.jpg",
            "caption": "great dig",
            "tags": ["volleyball", "beach"],
            "rally_metadata": {
                "duration": 5.5,
                "confidence": 0.92,
                "quality": 0.81,
                "detection_count": 12
            },
            "likes_count": 7,
            "comments_count": 2,
            "is_liked_by_me": true,
            "created_at": "2026-01-15T14:31:00Z",
            "hide_likes": false,
            "video_urls": ["https://video.example.com/1.m3u8"],
            "location_name": "Ocean Beach"
        }
        """
        let highlight = try decode(Highlight.self, from: json)

        // The bug we fixed: thumbnail_url was always nil.
        XCTAssertEqual(highlight.thumbnailURL?.absoluteString,
                       "https://cdn.example.com/thumbs/h1.jpg")
        XCTAssertEqual(highlight.authorId, "u1")
        XCTAssertEqual(highlight.muxPlaybackId, "https://video.example.com/playlist.m3u8")
        XCTAssertTrue(highlight.isLikedByMe)
        XCTAssertEqual(highlight.likesCount, 7)
        XCTAssertEqual(highlight.videoUrls, ["https://video.example.com/1.m3u8"])
        XCTAssertEqual(highlight.locationName, "Ocean Beach")
        XCTAssertEqual(highlight.rallyMetadata.detectionCount, 12)
        // Nested author must also resolve the acronym field.
        XCTAssertEqual(highlight.author?.avatarURL?.absoluteString,
                       "https://cdn.example.com/avatars/u1/avatar.jpg")
    }

    // MARK: - Comment

    func testCommentDecodes() throws {
        let json = """
        {
            "id": "c1",
            "highlight_id": "h1",
            "author_id": "u1",
            "text": "nice rally",
            "likes_count": 4,
            "is_liked_by_me": true,
            "created_at": "2026-01-15T14:32:00Z"
        }
        """
        let comment = try decode(Comment.self, from: json)
        XCTAssertEqual(comment.highlightId, "h1")
        XCTAssertEqual(comment.authorId, "u1")
        XCTAssertEqual(comment.likesCount, 4)
        XCTAssertTrue(comment.isLikedByMe)
    }

    // MARK: - Poll + PollOption

    func testPollDecodesWithOptions() throws {
        let json = """
        {
            "id": "p1",
            "highlight_id": "h1",
            "question": "In or out?",
            "total_votes": 9,
            "options": [
                {"id": "o1", "poll_id": "p1", "text": "In", "vote_count": 6, "sort_order": 0},
                {"id": "o2", "poll_id": "p1", "text": "Out", "vote_count": 3, "sort_order": 1}
            ]
        }
        """
        let poll = try decode(Poll.self, from: json)
        XCTAssertEqual(poll.highlightId, "h1")
        XCTAssertEqual(poll.totalVotes, 9)
        XCTAssertEqual(poll.options.count, 2)
        XCTAssertEqual(poll.options.first?.pollId, "p1")
        XCTAssertEqual(poll.options.first?.voteCount, 6)
        XCTAssertEqual(poll.options.last?.sortOrder, 1)
    }

    // MARK: - UserBlock (regression: was throwing keyNotFound)

    func testUserBlockDecodes() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "blocker_id": "22222222-2222-2222-2222-222222222222",
            "blocked_id": "33333333-3333-3333-3333-333333333333",
            "reason": null,
            "created_at": "2026-01-15T14:33:00Z"
        }
        """
        let block = try decode(UserBlock.self, from: json)
        XCTAssertEqual(block.blockerId.uuidString.lowercased(),
                       "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(block.blockedId.uuidString.lowercased(),
                       "33333333-3333-3333-3333-333333333333")
        XCTAssertNil(block.reason)
    }

    // MARK: - ContentReport (regression: was throwing keyNotFound)

    func testContentReportDecodes() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "reporter_id": "22222222-2222-2222-2222-222222222222",
            "reported_type": "highlight",
            "reported_id": "33333333-3333-3333-3333-333333333333",
            "reported_user_id": "44444444-4444-4444-4444-444444444444",
            "report_type": "spam",
            "description": "ad spam",
            "status": "pending",
            "reviewed_at": null,
            "reviewed_by": null,
            "moderator_notes": null,
            "created_at": "2026-01-15T14:34:00Z",
            "updated_at": "2026-01-15T14:34:00Z"
        }
        """
        let report = try decode(ContentReport.self, from: json)
        XCTAssertEqual(report.reportedType, .highlight)
        XCTAssertEqual(report.reportType, .spam)
        XCTAssertEqual(report.status, .pending)
        XCTAssertEqual(report.reportedUserId?.uuidString.lowercased(),
                       "44444444-4444-4444-4444-444444444444")
    }

    // MARK: - Encode round-trips (writes must produce snake_case columns)

    func testUserProfileUpdateEncodesSnakeCaseColumns() throws {
        let update = UserProfileUpdate(
            username: "alice",
            bio: "setter",
            teamName: "Spikers",
            privacyLevel: .private,
            avatarURL: "https://cdn.example.com/avatars/u1/avatar.jpg"
        )
        let json = try encodedJSON(update)
        XCTAssertTrue(json.contains("\"avatar_url\""), "avatar must write to avatar_url; got: \(json)")
        XCTAssertTrue(json.contains("\"team_name\""))
        XCTAssertTrue(json.contains("\"privacy_level\""))
    }

    func testCreateBlockRequestEncodesSnakeCaseColumn() throws {
        let request = CreateBlockRequest(
            blockedId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            reason: nil
        )
        let json = try encodedJSON(request)
        XCTAssertTrue(json.contains("\"blocked_id\""), "got: \(json)")
    }

    func testCreateReportRequestEncodesSnakeCaseColumns() throws {
        let request = CreateReportRequest(
            reportedType: .highlight,
            reportedId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            reportedUserId: nil,
            reportType: .spam,
            description: "ad spam"
        )
        let json = try encodedJSON(request)
        XCTAssertTrue(json.contains("\"reported_type\""), "got: \(json)")
        XCTAssertTrue(json.contains("\"reported_id\""))
        XCTAssertTrue(json.contains("\"report_type\""))
    }
}
