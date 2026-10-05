//
//  MediaStoreDurabilityTests.swift
//  BumpSetCutTests
//
//  The library manifest must never lose a video whose file exists, never
//  claim one that isn't on disk, and never leave files or sidecars behind:
//  save-failure rollback, lossy/last-good loading, reconcile relinking and
//  adoption, cascading deletes, import cleanup and migrations.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class MediaStoreDurabilityTests: XCTestCase {

    private var baseDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MediaStoreDurabilityTests_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        // VideoMetadata's URL helpers resolve through the global location.
        StorageManager.storageDirectoryOverride = baseDirectory
        PersistenceMonitor.shared.acknowledgeFailure()
    }

    override func tearDown() async throws {
        setWritable(baseDirectory, true)
        StorageManager.storageDirectoryOverride = nil
        try? fileManager.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> MediaStore {
        MediaStore(baseDirectory: baseDirectory)
    }

    /// A file inside the library (any bytes do — registration reads attributes only).
    @discardableResult
    private func writeFile(_ name: String, in folder: String, bytes: String = "video") throws -> URL {
        let directory = baseDirectory.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func addVideo(_ name: String, to folder: String, in store: MediaStore) throws -> VideoMetadata {
        let url = try writeFile(name, in: folder)
        XCTAssertTrue(store.addVideo(at: url, toFolder: folder))
        return try XCTUnwrap(store.getAllVideos().first { $0.fileName == name })
    }

    private func setWritable(_ url: URL, _ writable: Bool) {
        try? fileManager.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
    }

    private func sidecarNames(for videoId: UUID) -> [String] {
        let directory = baseDirectory.appendingPathComponent("ProcessedMetadata")
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(videoId.uuidString) }
    }

    private func writeSidecars(for videoId: UUID, in store: MediaStore) throws {
        try store.metadataStore.saveTrimAdjustments([0: RallyTrimAdjustment(before: 1, after: 0)], for: videoId)
        try store.metadataStore.saveGameScoring(GameScoring(), for: videoId)
    }

    private func manifestJSON(_ store: MediaStore) throws -> [String: Any] {
        let data = try Data(contentsOf: store.manifestURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Save failure rollback

    func testSaveFailureRollsBackAddVideoAndSurfacesIt() throws {
        let store = makeStore()
        let url = try writeFile("clip.mov", in: LibraryType.saved.rootPath)
        setWritable(baseDirectory, false) // manifest can't be rewritten

        XCTAssertFalse(store.addVideo(at: url, toFolder: LibraryType.saved.rootPath))

        XCTAssertNil(store.getAllVideos().first { $0.fileName == "clip.mov" }, "The in-memory change is rolled back")
        XCTAssertNotNil(PersistenceMonitor.shared.failureMessage, "The failure reaches the UI")
        setWritable(baseDirectory, true)
        let onDisk = try manifestJSON(store)["videos"] as? [String: Any]
        XCTAssertNil(onDisk?["clip.mov"])
    }

    func testSaveFailureRollsBackMoveIncludingTheFile() throws {
        let store = makeStore()
        let video = try addVideo("clip.mov", to: LibraryType.saved.rootPath, in: store)
        XCTAssertTrue(store.createFolder(name: "Team", parentPath: LibraryType.saved.rootPath))
        setWritable(baseDirectory, false)

        XCTAssertFalse(store.moveVideo(fileName: video.fileName, toFolder: "SavedGames/Team"))

        XCTAssertEqual(store.getAllVideos().first?.folderPath, LibraryType.saved.rootPath)
        XCTAssertTrue(fileManager.fileExists(atPath: store.fileURL(for: video).path), "File moved back")
    }

    func testDeleteWithFailedSaveKeepsTheFile() throws {
        let store = makeStore()
        let video = try addVideo("clip.mov", to: LibraryType.saved.rootPath, in: store)
        setWritable(baseDirectory, false)

        XCTAssertFalse(store.deleteVideo(fileName: video.fileName))

        XCTAssertNotNil(store.getAllVideos().first { $0.id == video.id })
        XCTAssertTrue(fileManager.fileExists(atPath: store.fileURL(for: video).path))
    }

    func testFailedSaveIsRetriedInTheBackground() throws {
        let store = makeStore()
        let video = try addVideo("clip.mov", to: LibraryType.saved.rootPath, in: store)
        setWritable(baseDirectory, false)

        XCTAssertFalse(store.markVideoAsProcessed(videoId: video.id, metadataFileSize: 42))
        XCTAssertTrue(store.hasUnsavedChanges, "Kept in memory, marked unsaved")

        setWritable(baseDirectory, true)
        PersistenceMonitor.shared.retryPending() // what app backgrounding triggers

        XCTAssertFalse(store.hasUnsavedChanges)
        let onDisk = try XCTUnwrap((try manifestJSON(store)["videos"] as? [String: [String: Any]])?["clip.mov"])
        XCTAssertEqual(onDisk["hasProcessingMetadata"] as? Bool, true)
    }

    // MARK: - Import

    func testImportMovesFileInAndSanitizesName() throws {
        let store = makeStore()
        let source = fileManager.temporaryDirectory.appendingPathComponent("import_\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: source)

        let imported = try store.importVideo(from: source, toFolder: LibraryType.saved.rootPath,
                                             customName: "  Finals\u{0007} ")

        XCTAssertEqual(imported.customName, "Finals")
        XCTAssertTrue(fileManager.fileExists(atPath: store.fileURL(for: imported).path))
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
    }

    func testImportFailureLeavesNoFileBehind() throws {
        let store = makeStore()
        let source = fileManager.temporaryDirectory.appendingPathComponent("import_\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: source)
        setWritable(baseDirectory, false) // the move succeeds, registration can't be saved

        XCTAssertThrowsError(try store.importVideo(from: source, toFolder: LibraryType.saved.rootPath, customName: nil))

        let savedDir = baseDirectory.appendingPathComponent(LibraryType.saved.rootPath)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: savedDir.path), [], "No untracked file in the library")
        XCTAssertFalse(fileManager.fileExists(atPath: source.path), "The temp source is cleaned up too")
        XCTAssertTrue(store.getAllVideos().isEmpty)
    }

    func testImportRejectsEscapingAndUnknownFolders() throws {
        let store = makeStore()
        for folder in ["../outside", "SavedGames/NoSuchFolder"] {
            let source = fileManager.temporaryDirectory.appendingPathComponent("import_\(UUID().uuidString).mov")
            try Data("video".utf8).write(to: source)
            XCTAssertThrowsError(try store.importVideo(from: source, toFolder: folder, customName: nil))
            XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        }
        XCTAssertTrue(store.getAllVideos().isEmpty)
    }

    // MARK: - Deletes

    func testDeletingOriginalRemovesProcessedChildEvenIfItsFileIsMissing() throws {
        let store = makeStore()
        let original = try addVideo("original.mov", to: LibraryType.saved.rootPath, in: store)
        let childURL = try writeFile("child.mov", in: LibraryType.processed.rootPath)
        let child = try XCTUnwrap(store.addProcessedVideo(at: childURL, toFolder: LibraryType.processed.rootPath,
                                                          customName: "Child", originalVideoId: original.id))
        try writeSidecars(for: original.id, in: store)
        try writeSidecars(for: child.id, in: store)
        try fileManager.removeItem(at: childURL)

        var removedIds: Set<UUID> = []
        store.onVideosRemoved = { removedIds.formUnion($0) }
        XCTAssertTrue(store.deleteVideo(fileName: original.fileName))

        XCTAssertTrue(store.getAllVideos().isEmpty, "Child entry goes with the original")
        XCTAssertTrue(sidecarNames(for: original.id).isEmpty)
        XCTAssertTrue(sidecarNames(for: child.id).isEmpty)
        XCTAssertEqual(removedIds, [original.id, child.id])
        XCTAssertFalse(fileManager.fileExists(atPath: store.fileURL(for: original).path))
    }

    func testDeletingProcessedCopyUnlinksItFromOriginal() throws {
        let store = makeStore()
        let original = try addVideo("original.mov", to: LibraryType.saved.rootPath, in: store)
        let childURL = try writeFile("child.mov", in: LibraryType.processed.rootPath)
        let child = try XCTUnwrap(store.addProcessedVideo(at: childURL, toFolder: LibraryType.processed.rootPath,
                                                          originalVideoId: original.id))

        XCTAssertTrue(store.deleteVideo(fileName: child.fileName))

        let reloaded = try XCTUnwrap(store.getAllVideos().first { $0.id == original.id })
        XCTAssertTrue(reloaded.processedVideoIds.isEmpty)
    }

    func testDeleteFolderRemovesNestedFoldersVideosAndSidecars() throws {
        let store = makeStore()
        XCTAssertTrue(store.createFolder(name: "Team", parentPath: "SavedGames"))
        XCTAssertTrue(store.createFolder(name: "Sub", parentPath: "SavedGames/Team"))
        XCTAssertTrue(store.createFolder(name: "Team B", parentPath: "SavedGames"))
        let inner = try addVideo("inner.mov", to: "SavedGames/Team/Sub", in: store)
        let sibling = try addVideo("sibling.mov", to: "SavedGames/Team B", in: store)
        try writeSidecars(for: inner.id, in: store)

        XCTAssertTrue(store.deleteFolder(at: "SavedGames/Team"))

        XCTAssertNil(store.getFolderMetadata(at: "SavedGames/Team"))
        XCTAssertNil(store.getFolderMetadata(at: "SavedGames/Team/Sub"))
        XCTAssertNotNil(store.getFolderMetadata(at: "SavedGames/Team B"), "Prefix-similar sibling untouched")
        XCTAssertEqual(store.getAllVideos().map(\.id), [sibling.id])
        XCTAssertTrue(sidecarNames(for: inner.id).isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("SavedGames/Team").path))
        XCTAssertEqual(store.getFolders(in: "SavedGames").first { $0.name == "Team B" }?.videoCount, 1)
    }

    // MARK: - Rename / move

    func testRenameFolderRewritesNestedPathsAndCounts() throws {
        let store = makeStore()
        XCTAssertTrue(store.createFolder(name: "Team", parentPath: "SavedGames"))
        XCTAssertTrue(store.createFolder(name: "Sub", parentPath: "SavedGames/Team"))
        let top = try addVideo("top.mov", to: "SavedGames/Team", in: store)
        let nested = try addVideo("nested.mov", to: "SavedGames/Team/Sub", in: store)

        XCTAssertTrue(store.renameFolder(at: "SavedGames/Team", to: "Squad"))

        let videos = Dictionary(uniqueKeysWithValues: store.getAllVideos().map { ($0.id, $0) })
        XCTAssertEqual(videos[top.id]?.folderPath, "SavedGames/Squad")
        XCTAssertEqual(videos[nested.id]?.folderPath, "SavedGames/Squad/Sub")
        XCTAssertEqual(store.getFolderMetadata(at: "SavedGames/Squad/Sub")?.parentPath, "SavedGames/Squad")
        XCTAssertNil(store.getFolderMetadata(at: "SavedGames/Team"))
        for video in videos.values {
            XCTAssertTrue(fileManager.fileExists(atPath: store.fileURL(for: video).path))
        }
        let squad = try XCTUnwrap(store.getFolders(in: "SavedGames").first { $0.name == "Squad" })
        XCTAssertEqual(squad.videoCount, 1)
        XCTAssertEqual(squad.subfolderCount, 1)
        XCTAssertEqual(store.getFolders(in: "SavedGames/Squad").first?.videoCount, 1)
    }

    func testMoveVideoUpdatesPathFileAndCounts() throws {
        let store = makeStore()
        XCTAssertTrue(store.createFolder(name: "Team", parentPath: "SavedGames"))
        let video = try addVideo("clip.mov", to: "SavedGames", in: store)

        XCTAssertTrue(store.moveVideo(fileName: video.fileName, toFolder: "SavedGames/Team"))

        let moved = try XCTUnwrap(store.getAllVideos().first)
        XCTAssertEqual(moved.folderPath, "SavedGames/Team")
        XCTAssertTrue(fileManager.fileExists(atPath: store.fileURL(for: moved).path))
        XCTAssertEqual(store.getFolders(in: "SavedGames").first { $0.name == "Team" }?.videoCount, 1)
    }

    // MARK: - Replace file

    func testReplaceVideoFileFailureKeepsOriginal() throws {
        let store = makeStore()
        let video = try addVideo("clip.mov", to: "SavedGames", in: store)
        let missing = fileManager.temporaryDirectory.appendingPathComponent("missing_\(UUID().uuidString).mov")

        XCTAssertFalse(store.replaceVideoFile(id: video.id, withFileAt: missing))

        XCTAssertEqual(try String(contentsOf: store.fileURL(for: video), encoding: .utf8), "video")
        XCTAssertNotNil(store.getAllVideos().first { $0.id == video.id })
    }

    // MARK: - Reconcile

    func testReconcileRelinksMovedFileInsteadOfDroppingIt() throws {
        let store = makeStore()
        let video = try addVideo("clip.mov", to: "SavedGames", in: store)
        let elsewhere = baseDirectory.appendingPathComponent("SavedGames/Moved", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fileManager.moveItem(at: store.fileURL(for: video), to: elsewhere.appendingPathComponent("clip.mov"))

        store.cleanupStaleEntries()

        let relinked = try XCTUnwrap(store.getAllVideos().first { $0.id == video.id }, "Never dropped")
        XCTAssertEqual(relinked.folderPath, "SavedGames/Moved")
        XCTAssertNotNil(store.getFolderMetadata(at: "SavedGames/Moved"), "Its folder becomes reachable")
    }

    func testReconcileNeverDropsEntryWhoseFileExistsButRemovesTrulyMissingOnes() throws {
        let store = makeStore()
        let kept = try addVideo("kept.mov", to: "SavedGames", in: store)
        let gone = try addVideo("gone.mov", to: "SavedGames", in: store)
        try writeSidecars(for: gone.id, in: store)
        try fileManager.removeItem(at: store.fileURL(for: gone))

        store.cleanupStaleEntries()

        XCTAssertEqual(store.getAllVideos().map(\.id), [kept.id])
        XCTAssertTrue(sidecarNames(for: gone.id).isEmpty, "A truly gone video's sidecars go too")
    }

    func testLaunchReconcileAdoptsUntrackedVideosAndSweepsOrphans() async throws {
        let store = makeStore()
        let video = try addVideo("tracked.mov", to: "SavedGames", in: store)
        try writeSidecars(for: video.id, in: store)
        let orphanId = UUID()
        try writeSidecars(for: orphanId, in: store)
        try writeFile("untracked.mov", in: "FavoriteRallies/Beach")

        // A relaunch: clean load of the saved manifest.
        let relaunched = makeStore()
        await relaunched.reconcileStorageOffMain()

        let adopted = try XCTUnwrap(relaunched.getAllVideos().first { $0.fileName == "untracked.mov" })
        XCTAssertEqual(adopted.folderPath, "FavoriteRallies/Beach")
        XCTAssertNotNil(relaunched.getFolderMetadata(at: "FavoriteRallies/Beach"))
        XCTAssertFalse(sidecarNames(for: video.id).isEmpty, "Live sidecars kept")
        XCTAssertTrue(sidecarNames(for: orphanId).isEmpty, "Orphaned sidecars swept")
    }

    // MARK: - Manifest loading

    func testLossyDecodeKeepsGoodEntriesAndBacksUpOriginal() throws {
        let store = makeStore()
        let good = try addVideo("good.mov", to: "SavedGames", in: store)
        var json = try manifestJSON(store)
        var videos = try XCTUnwrap(json["videos"] as? [String: Any])
        videos["bad.mov"] = ["id": "not-a-uuid"]
        json["videos"] = videos
        try JSONSerialization.data(withJSONObject: json).write(to: store.manifestURL)

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.loadOutcome, .partial)
        XCTAssertEqual(reloaded.getAllVideos().map(\.id), [good.id])
        let names = try fileManager.contentsOfDirectory(atPath: baseDirectory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("manifest.corrupt-") }, "The original is kept for recovery")
    }

    func testUndecodableManifestRestoresLastGoodCopy() throws {
        let store = makeStore()
        let video = try addVideo("clip.mov", to: "SavedGames", in: store)
        _ = makeStore() // clean load → writes manifest.last-good.json
        try Data("{ truncated".utf8).write(to: store.manifestURL)

        let recovered = makeStore()

        XCTAssertEqual(recovered.loadOutcome, .restoredFromLastGood)
        XCTAssertEqual(recovered.getAllVideos().map(\.id), [video.id])
        let names = try fileManager.contentsOfDirectory(atPath: baseDirectory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("manifest.corrupt-") })
        XCTAssertNoThrow(try manifestJSON(recovered), "A readable manifest was written back")
    }

    func testUnreadableManifestIsNeverOverwritten() throws {
        let store = makeStore()
        _ = try addVideo("clip.mov", to: "SavedGames", in: store)
        let original = try Data(contentsOf: store.manifestURL)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.manifestURL.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.manifestURL.path) }

        let readOnly = makeStore()

        XCTAssertEqual(readOnly.loadOutcome, .unreadable)
        XCTAssertTrue(readOnly.isReadOnly)
        XCTAssertFalse(readOnly.createFolder(name: "New", parentPath: "SavedGames"))
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.manifestURL.path)
        XCTAssertEqual(try Data(contentsOf: store.manifestURL), original)
    }

    func testCleanRelaunchDoesNotRewriteManifest() throws {
        let store = makeStore()
        _ = try addVideo("clip.mov", to: "SavedGames", in: store)
        let before = try fileManager.attributesOfItem(atPath: store.manifestURL.path)[.modificationDate] as? Date

        _ = makeStore()

        let after = try fileManager.attributesOfItem(atPath: store.manifestURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "Nothing changed, so nothing is saved at launch")
    }

    // MARK: - Migration

    func testMigrationFromVersion1ManifestLosesNothing() throws {
        let reference = Date().timeIntervalSinceReferenceDate
        func video(_ name: String, folder: String, processed: Bool = false) -> [String: Any] {
            ["id": UUID().uuidString, "fileName": name, "folderPath": folder,
             "createdDate": reference, "fileSize": 5, "isProcessed": processed]
        }
        let manifest: [String: Any] = [
            "version": 1,
            "createdDate": reference,
            "lastModified": reference,
            "folders": [
                "Team": ["id": UUID().uuidString, "name": "Team", "path": "Team",
                         "createdDate": reference, "modifiedDate": reference,
                         "videoCount": 2, "subfolderCount": 0],
            ],
            "videos": [
                "root.mov": video("root.mov", folder: ""),
                "team.mov": video("team.mov", folder: "Team"),
                "team_processed.mov": video("team_processed.mov", folder: "Team", processed: true),
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: baseDirectory.appendingPathComponent("manifest.json"))
        try writeFile("root.mov", in: "")
        try writeFile("team.mov", in: "Team")
        try writeFile("team_processed.mov", in: "Team")

        let store = makeStore()

        let byName = Dictionary(uniqueKeysWithValues: store.getAllVideos().map { ($0.fileName, $0) })
        XCTAssertEqual(byName["root.mov"]?.folderPath, "SavedGames")
        XCTAssertEqual(byName["team.mov"]?.folderPath, "SavedGames/Team")
        XCTAssertEqual(byName["team_processed.mov"]?.folderPath, "ProcessedGames/Team")
        for video in byName.values {
            XCTAssertTrue(fileManager.fileExists(atPath: store.fileURL(for: video).path), "\(video.fileName) moved with its entry")
        }
        for root in LibraryType.allCases {
            XCTAssertNotNil(store.getFolderMetadata(at: root.rootPath))
        }
        XCTAssertEqual(store.getFolders(in: "SavedGames").first { $0.name == "Team" }?.videoCount, 1)
        XCTAssertEqual(try manifestJSON(store)["version"] as? Int, MediaStore.currentManifestVersion)
    }

    // MARK: - Favorites follow timeline edits

    func testRemapFavoriteSourceIndices() throws {
        let store = makeStore()
        let source = UUID()
        for (index, name) in ["a.mp4", "b.mp4", "c.mp4"].enumerated() {
            let url = try writeFile(name, in: "FavoriteRallies")
            XCTAssertTrue(store.addVideo(at: url, toFolder: "FavoriteRallies", sourceVideoId: source, sourceRallyIndex: index))
        }

        // Rally 0 deleted, 1 → 0, 2 → 1.
        XCTAssertTrue(store.remapFavoriteSourceIndices(sourceVideoId: source, oldToNew: [1: 0, 2: 1]))

        let indices = Dictionary(uniqueKeysWithValues: store.getAllVideos().map { ($0.fileName, $0.sourceRallyIndex) })
        XCTAssertEqual(indices["a.mp4"], .some(nil))
        XCTAssertEqual(indices["b.mp4"], 0)
        XCTAssertEqual(indices["c.mp4"], 1)
    }

    // MARK: - Debug data

    func testDebugDataPathIsStoredAsFileNameAndOldAbsolutePathsDecode() throws {
        let store = makeStore()
        let video = try addVideo("clip.mov", to: "SavedGames", in: store)
        try store.saveDebugData(for: video.id, debugData: Data("{}".utf8), sessionId: UUID())

        let stored = try XCTUnwrap(store.getAllVideos().first?.debugDataPath)
        XCTAssertFalse(stored.contains("/"))
        XCTAssertNotNil(store.loadDebugData(for: video.id))

        let legacyJSON = """
        {"id":"\(UUID().uuidString)","fileName":"x.mov","folderPath":"SavedGames","createdDate":0,
         "fileSize":1,"debugDataPath":"/var/mobile/Containers/Old/.debug_data/abc.json"}
        """
        let legacy = try JSONDecoder().decode(VideoMetadata.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.debugDataPath, "abc.json")
    }
}
