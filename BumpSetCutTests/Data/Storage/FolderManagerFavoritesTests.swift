//
//  FolderManagerFavoritesTests.swift
//  BumpSetCutTests
//
//  Removing a favorite clip must also un-star the rally on its source
//  video's review selections, or the player keeps showing it as favorited.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class FolderManagerFavoritesTests: XCTestCase {

    private var baseDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("FolderManagerFavoritesTests_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = baseDirectory
    }

    override func tearDown() async throws {
        StorageManager.storageDirectoryOverride = nil
        try? fileManager.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    private func addFavorite(_ name: String, source: UUID, index: Int, in store: MediaStore) throws -> VideoMetadata {
        let folder = LibraryType.favorites.rootPath
        let directory = baseDirectory.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("clip".utf8).write(to: url)
        XCTAssertTrue(store.addVideo(at: url, toFolder: folder, sourceVideoId: source, sourceRallyIndex: index))
        return try XCTUnwrap(store.getAllVideos().first { $0.fileName == name })
    }

    private func addSource(_ name: String, in store: MediaStore) throws -> UUID {
        let url = baseDirectory.appendingPathComponent(name)
        try Data("game".utf8).write(to: url)
        XCTAssertTrue(store.addVideo(at: url))
        return try XCTUnwrap(store.getAllVideos().first { $0.fileName == name }).id
    }

    func testRemoveFavoriteUnstarsSourceRallyAndDeletesClip() async throws {
        let store = MediaStore(baseDirectory: baseDirectory)
        let metadataStore = MetadataStore(baseDirectory: baseDirectory)
        let manager = FolderManager(mediaStore: store, libraryType: .favorites, metadataStore: metadataStore)
        let source = try addSource("game.mp4", in: store)
        let clip = try addFavorite("rally2.mp4", source: source, index: 2, in: store)

        var selections = RallyReviewSelections()
        selections.favorited = [1, 2]
        try metadataStore.saveReviewSelections(selections, for: source)

        try await manager.removeFavorite(clip)

        XCTAssertEqual(metadataStore.loadReviewSelections(for: source).favorited, [1])
        XCTAssertFalse(store.getAllVideos().contains { $0.id == clip.id })
    }

    /// Favorites are their own clips: deleting the game keeps them, and
    /// removing one afterwards leaves nothing of the deleted game behind.
    func testFavoriteOutlivesItsSourceVideo() async throws {
        let store = MediaStore(baseDirectory: baseDirectory)
        let metadataStore = MetadataStore(baseDirectory: baseDirectory)
        let manager = FolderManager(mediaStore: store, libraryType: .favorites, metadataStore: metadataStore)
        let source = try addSource("game.mp4", in: store)
        let clip = try addFavorite("rally0.mp4", source: source, index: 0, in: store)
        var selections = RallyReviewSelections()
        selections.favorited = [0]
        try metadataStore.saveReviewSelections(selections, for: source)

        XCTAssertTrue(store.deleteVideo(fileName: "game.mp4"))
        let kept = try XCTUnwrap(store.getAllVideos().first { $0.id == clip.id })
        XCTAssertTrue(fileManager.fileExists(atPath: store.getVideoURL(for: kept).path))
        XCTAssertTrue(metadataStore.loadReviewSelections(for: source).favorited.isEmpty)

        try await manager.removeFavorite(kept)
        XCTAssertTrue(metadataStore.loadReviewSelections(for: source).favorited.isEmpty)
        let sidecars = try fileManager.subpathsOfDirectory(atPath: baseDirectory.path).filter { $0.contains(source.uuidString) }
        XCTAssertEqual(sidecars, [])
    }
}
