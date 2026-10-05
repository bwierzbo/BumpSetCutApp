//
//  ShareRallyViewModelTests.swift
//  BumpSetCutTests
//
//  The share sheet's poll options and saved-rally pages: both crashed the
//  app when indexed past their arrays.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class ShareRallyViewModelTests: XCTestCase {

    private func makeViewModel(saved: [Int], rallies: Int = 3, initialPage: Int = 0) -> ShareRallyViewModel {
        let video = URL(fileURLWithPath: "/tmp/game.mov")
        let urls = (0..<rallies).map { URL(string: "\(video.absoluteString)#rally_\($0)")! }
        return ShareRallyViewModel(originalVideoURL: video, rallyVideoURLs: urls, savedRallyIndices: saved,
                                   initialPage: initialPage, thumbnailCache: RallyThumbnailCache(),
                                   videoId: UUID(), rallyInfo: [:], apiClient: StubAPIClient())
    }

    func testRemovingAnOptionKeepsTheOthersText() {
        let vm = makeViewModel(saved: [0])
        vm.addPollOption()
        vm.pollOptions[0].text = "Ace"
        vm.pollOptions[1].text = "Block"
        vm.pollOptions[2].text = "Dig"

        vm.removePollOption(vm.pollOptions[1].id)

        XCTAssertEqual(vm.pollOptions.map(\.text), ["Ace", "Dig"])
    }

    func testNeverFewerThanTwoOptions() {
        let vm = makeViewModel(saved: [0])
        vm.removePollOption(vm.pollOptions[0].id)
        XCTAssertEqual(vm.pollOptions.count, 2)
    }

    func testHashtagsAreLowercasedAndUnique() {
        let vm = makeViewModel(saved: [0])
        vm.caption = "Big #Ace then #block and another #ace"
        XCTAssertEqual(vm.extractedTags, ["ace", "block"])
    }

    func testSavedRalliesPastTheRallyListAreDropped() {
        // Saved before a reprocess that found fewer rallies.
        let vm = makeViewModel(saved: [0, 2, 5, 9], rallies: 3, initialPage: 3)
        XCTAssertEqual(vm.savedRallyIndices, [0, 2])
        XCTAssertEqual(vm.selectedPage, 1)
    }
}
