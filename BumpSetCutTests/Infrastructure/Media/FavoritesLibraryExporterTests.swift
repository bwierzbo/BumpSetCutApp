//
//  FavoritesLibraryExporterTests.swift
//  BumpSetCutTests
//
//  Favorited rallies land in the Favorites library once, are re-filed when a
//  collection is chosen later, and invalid ranges are skipped — against a
//  real clip in an isolated library.
//

import XCTest
import AVFoundation
@testable import BumpSetCut

@MainActor
final class FavoritesLibraryExporterTests: XCTestCase {

    private var baseDirectory: URL!
    private var store: MediaStore!
    private var source: VideoMetadata!

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesLibraryExporterTests_\(UUID().uuidString)", isDirectory: true)
        let savedDir = baseDirectory.appendingPathComponent(LibraryType.saved.rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: savedDir, withIntermediateDirectories: true)
        // VideoMetadata's URL helpers resolve through the global location.
        StorageManager.storageDirectoryOverride = baseDirectory
        store = MediaStore(baseDirectory: baseDirectory)

        let clip = try TestVideoFactory.writeVideo(to: savedDir.appendingPathComponent("game.mp4"), duration: 2.0)
        XCTAssertTrue(store.addVideo(at: clip, toFolder: LibraryType.saved.rootPath))
        source = try XCTUnwrap(store.getAllVideos().first { $0.fileName == "game.mp4" })
    }

    override func tearDown() async throws {
        StorageManager.storageDirectoryOverride = nil
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    private func rally(_ index: Int, collection: String? = nil, start: Double = 0.2, end: Double = 1.0)
        -> FavoritesLibraryExporter.Rally {
        .init(index: index, startTime: start, endTime: end, crop: nil, collection: collection)
    }

    private var favorites: [VideoMetadata] {
        store.getAllVideos(in: .favorites).filter { $0.sourceVideoId == source.id }
    }

    func testExportsEachRallyOnceAcrossRepeatedRuns() async {
        let exporter = FavoritesLibraryExporter(mediaStore: store)

        let firstFailures = await exporter.export([rally(0), rally(2)], from: source)
        let secondFailures = await exporter.export([rally(0), rally(2)], from: source)

        XCTAssertEqual(firstFailures, 0)
        XCTAssertEqual(secondFailures, 0)
        XCTAssertEqual(favorites.compactMap(\.sourceRallyIndex).sorted(), [0, 2], "no duplicates on re-run")
        for clip in favorites {
            XCTAssertEqual(clip.folderPath, LibraryType.favorites.rootPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: clip.originalURL.path))
            XCTAssertEqual(clip.displayName, "\(source.displayName) - Rally \(clip.sourceRallyIndex! + 1)")
        }
    }

    func testChosenCollectionIsCreatedAndExistingClipRefiled() async throws {
        let exporter = FavoritesLibraryExporter(mediaStore: store)
        _ = await exporter.export([rally(1)], from: source)

        let failures = await exporter.export([rally(1, collection: "Aces"), rally(3, collection: "Aces")], from: source)

        XCTAssertEqual(failures, 0)
        let path = "\(LibraryType.favorites.rootPath)/Aces"
        XCTAssertTrue(store.getAllFolders(in: .favorites).contains { $0.path == path })
        XCTAssertEqual(favorites.count, 2)
        XCTAssertTrue(favorites.allSatisfy { $0.folderPath == path }, "existing clip re-filed, new one filed there")
    }

    func testEmptyRangeIsSkippedNotFailed() async {
        let failures = await FavoritesLibraryExporter(mediaStore: store)
            .export([rally(0, start: 1.0, end: 1.0)], from: source)

        XCTAssertEqual(failures, 0)
        XCTAssertTrue(favorites.isEmpty)
    }
}
