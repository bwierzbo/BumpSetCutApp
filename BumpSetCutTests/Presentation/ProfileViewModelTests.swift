//
//  ProfileViewModelTests.swift
//  BumpSetCutTests
//
//  Player Info visibility: the card is locked for non-followers of a private
//  profile, and following someone re-fetches so it unlocks in place.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class ProfileViewModelTests: XCTestCase {

    private func makeProfile(
        id: String = "them",
        privacy: PrivacyLevel = .public,
        details: PlayerInfo? = PlayerInfo(playTypes: [.beach], level: .aa)
    ) -> UserProfile {
        UserProfile(id: id, username: "sandy", privacyLevel: privacy, details: details)
    }

    private func loadedViewModel(
        profile: UserProfile,
        following: Bool = false,
        client: MockProfileClient? = nil
    ) async -> (ProfileViewModel, MockProfileClient) {
        let mock = client ?? MockProfileClient()
        mock.profile = profile
        mock.isFollowing = following
        let viewModel = ProfileViewModel(userId: profile.id, apiClient: mock)
        await viewModel.loadProfile()
        return (viewModel, mock)
    }

    // MARK: - Visible

    func testPublicProfileWithDetailsIsVisible() async {
        let (viewModel, _) = await loadedViewModel(profile: makeProfile(privacy: .public))
        XCTAssertEqual(
            viewModel.playerInfoState(isOwnProfile: false),
            .visible(PlayerInfo(playTypes: [.beach], level: .aa))
        )
    }

    func testFollowersOnlyProfileIsVisibleOnceFollowing() async {
        let (viewModel, _) = await loadedViewModel(
            profile: makeProfile(privacy: .followersOnly), following: true
        )
        XCTAssertEqual(
            viewModel.playerInfoState(isOwnProfile: false),
            .visible(PlayerInfo(playTypes: [.beach], level: .aa))
        )
    }

    func testPrivateProfileIsVisibleToFollowers() async {
        let (viewModel, _) = await loadedViewModel(
            profile: makeProfile(privacy: .private), following: true
        )
        XCTAssertEqual(
            viewModel.playerInfoState(isOwnProfile: false),
            .visible(PlayerInfo(playTypes: [.beach], level: .aa))
        )
    }

    // MARK: - Locked

    func testFollowersOnlyProfileIsLockedForNonFollower() async {
        let (viewModel, _) = await loadedViewModel(
            profile: makeProfile(privacy: .followersOnly), following: false
        )
        XCTAssertEqual(viewModel.playerInfoState(isOwnProfile: false), .locked)
    }

    /// The lock is about the viewer, not the data: even if a details row came
    /// back, a non-follower of a private profile must not see it.
    func testPrivateProfileIsLockedForNonFollower() async {
        let (viewModel, _) = await loadedViewModel(
            profile: makeProfile(privacy: .private), following: false
        )
        XCTAssertEqual(viewModel.playerInfoState(isOwnProfile: false), .locked)
    }

    func testOwnPrivateProfileIsNeverLocked() async {
        let (viewModel, _) = await loadedViewModel(profile: makeProfile(privacy: .private))
        XCTAssertEqual(
            viewModel.playerInfoState(isOwnProfile: true),
            .visible(PlayerInfo(playTypes: [.beach], level: .aa))
        )
    }

    // MARK: - Empty

    func testProfileWithoutDetailsIsEmpty() async {
        let (viewModel, _) = await loadedViewModel(profile: makeProfile(details: nil))
        XCTAssertEqual(viewModel.playerInfoState(isOwnProfile: true), .empty)
    }

    func testProfileWithBlankDetailsIsEmpty() async {
        let (viewModel, _) = await loadedViewModel(profile: makeProfile(details: PlayerInfo()))
        XCTAssertEqual(viewModel.playerInfoState(isOwnProfile: true), .empty)
    }

    // MARK: - Follow refresh

    /// Following changes what RLS will return, so the profile is re-fetched —
    /// that's what makes a locked card unlock without leaving the screen.
    func testFollowingRefetchesTheProfile() async {
        let (viewModel, mock) = await loadedViewModel(
            profile: makeProfile(privacy: .followersOnly), following: false
        )
        XCTAssertEqual(mock.getProfileCount, 1)
        XCTAssertEqual(viewModel.playerInfoState(isOwnProfile: false), .locked)

        await viewModel.toggleFollow()

        XCTAssertEqual(mock.getProfileCount, 2, "toggleFollow should re-read the profile")
        XCTAssertEqual(
            viewModel.playerInfoState(isOwnProfile: false),
            .visible(PlayerInfo(playTypes: [.beach], level: .aa))
        )
    }
}

// MARK: - Mock client

private final class MockProfileClient: APIClient, @unchecked Sendable {
    nonisolated(unsafe) var profile = UserProfile(id: "them", username: "sandy")
    nonisolated(unsafe) var isFollowing = false
    nonisolated(unsafe) var getProfileCount = 0

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        switch endpoint {
        case .getProfile:
            getProfileCount += 1
            guard let cast = profile as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .getUserHighlights:
            guard let cast = [Highlight]() as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .checkFollowStatus:
            let rows = isFollowing ? [FollowRow(followingId: profile.id)] : []
            guard let cast = rows as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .follow, .unfollow:
            guard let cast = EmptyResponse() as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        default:
            throw APIError.serverError(statusCode: 501, message: "not used")
        }
    }

    func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }

    func submitFlywheelContribution(_ contribution: FlywheelContribution, frameURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }
}
