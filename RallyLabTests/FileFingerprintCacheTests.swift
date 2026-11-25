//
//  FileFingerprintCacheTests.swift
//  RallyLabTests
//
//  The fingerprint of an unchanged file is read once per process; a changed
//  file (size or modification time) is read again; a file that can't be read
//  is never cached; two links to one file share one entry.
//

import XCTest
@testable import RallyLab

final class FileFingerprintCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testUnchangedFileIsReadOnce() throws {
        let file = dir.appendingPathComponent("a.bin")
        try Data(repeating: 1, count: 10_000).write(to: file)
        let cache = FileFingerprintCache()
        var reads = 0
        func read() -> String? { reads += 1; return ProjectsModel.readFileFingerprint(atPath: file.path) }
        let first = cache.fingerprint(atPath: file.path, compute: read)
        let second = cache.fingerprint(atPath: file.path, compute: read)
        XCTAssertEqual(first, second)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(cache.computations, 1)
        XCTAssertEqual(first, ProjectsModel.readFileFingerprint(atPath: file.path), "the cached value is the file's")
    }

    func testChangedFileIsReadAgain() throws {
        let file = dir.appendingPathComponent("b.bin")
        try Data(repeating: 1, count: 10_000).write(to: file)
        let cache = FileFingerprintCache()
        var reads = 0
        func read() -> String? { reads += 1; return ProjectsModel.readFileFingerprint(atPath: file.path) }
        let before = cache.fingerprint(atPath: file.path, compute: read)
        // Other content, other size: a new stamp.
        try Data(repeating: 2, count: 20_000).write(to: file)
        let after = cache.fingerprint(atPath: file.path, compute: read)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(reads, 2)
        // Same size, but a later modification time: read again too.
        try Data(repeating: 3, count: 20_000).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let third = cache.fingerprint(atPath: file.path, compute: read)
        XCTAssertNotEqual(after, third)
        XCTAssertEqual(reads, 3)
    }

    func testMissingOrUnreadableFileIsNotCached() {
        let cache = FileFingerprintCache()
        var reads = 0
        let missing = dir.appendingPathComponent("none.bin").path
        XCTAssertNil(cache.fingerprint(atPath: missing) { reads += 1; return nil })
        XCTAssertNil(cache.fingerprint(atPath: missing) { reads += 1; return nil })
        XCTAssertEqual(reads, 2, "asked again next time")
        XCTAssertEqual(cache.count, 0)
    }

    func testSymlinkSharesTheTargetEntry() throws {
        let file = dir.appendingPathComponent("c.bin")
        try Data(repeating: 7, count: 5_000).write(to: file)
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let cache = FileFingerprintCache()
        var reads = 0
        func read(_ path: String) -> () -> String? { { reads += 1; return ProjectsModel.readFileFingerprint(atPath: path) } }
        let a = cache.fingerprint(atPath: file.path, compute: read(file.path))
        let b = cache.fingerprint(atPath: link.path, compute: read(link.path))
        XCTAssertEqual(a, b)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(cache.count, 1)
    }

    func testProjectsModelFingerprintGoesThroughTheSharedCache() throws {
        let file = dir.appendingPathComponent("d.bin")
        try Data(repeating: 9, count: 5_000).write(to: file)
        let before = FileFingerprintCache.shared.computations
        _ = ProjectsModel.fileFingerprint(atPath: file.path)
        _ = ProjectsModel.fileFingerprint(atPath: file.path)
        XCTAssertEqual(FileFingerprintCache.shared.computations - before, 1)
    }
}
