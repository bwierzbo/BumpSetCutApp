//
//  RecipientPickerViewModelTests.swift
//  BumpSetCutTests
//
//  Who is offered as a recipient: Recent before Following, nobody twice,
//  never yourself; typing switches to search results.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class RecipientPickerViewModelTests: XCTestCase {

    private let me = "me"

    private func user(_ id: String) -> UserProfile {
        UserProfile(id: id, username: "user_\(id)")
    }

    private func conversation(with user: UserProfile) -> ConversationSummary {
        ConversationSummary(
            conversationId: "conv-\(user.id)",
            myStatus: .accepted,
            lastReadAt: Date(),
            otherUserId: user.id,
            otherStatus: .accepted,
            otherUsername: user.username,
            otherAvatarURL: nil,
            createdAt: Date(),
            lastMessageAt: Date(),
            lastMessagePreview: "hey",
            lastMessageAttachmentType: nil,
            lastMessageSenderId: user.id,
            unreadCount: 0
        )
    }

    func testLoad_recentBeforeFollowing_dedupedAndWithoutSelf() async {
        let client = MockMessagingClient()
        let sandy = user("sandy"), casey = user("casey"), jordan = user("jordan")
        client.conversations = [conversation(with: sandy), conversation(with: user(me))]
        client.following = [sandy, casey, jordan]

        let vm = RecipientPickerViewModel(currentUserId: me, apiClient: client)
        await vm.load()

        let sections = vm.visibleSections
        XCTAssertEqual(sections.map(\.title), ["Recent", "Following"])
        XCTAssertEqual(sections[0].users.map(\.id), ["sandy"], "self is never offered, even from a conversation")
        XCTAssertEqual(sections[1].users.map(\.id), ["casey", "jordan"], "someone already under Recent isn't repeated under Following")
        XCTAssertFalse(vm.loadFailed)
    }

    func testLoad_whenFollowingFails_recentStillShows() async {
        let client = MockMessagingClient()
        client.conversations = [conversation(with: user("sandy"))]
        client.followingError = APIError.networkUnavailable

        let vm = RecipientPickerViewModel(currentUserId: me, apiClient: client)
        await vm.load()

        XCTAssertEqual(vm.visibleSections.map(\.title), ["Recent"])
        XCTAssertTrue(vm.loadFailed)
    }

    func testSearch_isDebounced_andReplacesSectionsWithResults() async {
        let client = MockMessagingClient()
        client.following = [user("casey")]
        client.searchResults = [user("sandy"), user(me)]

        let vm = RecipientPickerViewModel(currentUserId: me, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.visibleSections.map(\.title), ["Following"])

        vm.query = "san"
        vm.searchTextChanged()
        XCTAssertTrue(vm.visibleSections.isEmpty, "nothing is shown for a query until the debounced search lands")

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(vm.visibleSections.map(\.title), ["Results"])
        XCTAssertEqual(vm.visibleSections[0].users.map(\.id), ["sandy"], "search results also drop self")

        vm.query = ""
        vm.searchTextChanged()
        XCTAssertEqual(vm.visibleSections.map(\.title), ["Following"], "clearing the query restores the browse sections")
    }
}
