//
//  CoverageAuditCopyTests.swift
//  RallyLabTests
//
//  The Audit tab plays a small copy of a recording too heavy to play at 2× and 3× (a 4K original at 60 frames a
//  second) — and only a copy whose frames are the original's, time for time. These tests hold the rule for
//  "heavy", and that a copy is kept and played only when it passes that check: the published one if it does,
//  else one made here, else the original.
//

import XCTest
@testable import RallyLab

final class CoverageAuditCopyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("covcopy-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: "mp4") ?? bundle.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
    }

    /// A stand-in that "makes" or "fetches" a copy by putting this file there.
    private func puts(_ file: URL) -> LabelingSync.SmallCopy {
        { _, out in try FileManager.default.copyItem(at: file, to: out) }
    }

    private func source(_ original: URL) -> CoverageAuditCopy.Source {
        .init(original: original, fingerprint: "sha256:abc/def", recordingId: "rec", project: "P")
    }

    func testOnlyMoreThanFourKAtThirtyFramesASecondIsHeavy() {
        XCTAssertTrue(CoverageAuditCopy.isHeavy(width: 3840, height: 2160, framesPerSecond: 60))
        XCTAssertTrue(CoverageAuditCopy.isHeavy(width: 2160, height: 3840, framesPerSecond: 59.94), "upright too")
        XCTAssertFalse(CoverageAuditCopy.isHeavy(width: 3840, height: 2160, framesPerSecond: 30))
        XCTAssertFalse(CoverageAuditCopy.isHeavy(width: 3840, height: 2160, framesPerSecond: 30.01), "a nominal rate a hair over 30 is still 30")
        XCTAssertFalse(CoverageAuditCopy.isHeavy(width: 1920, height: 1080, framesPerSecond: 60))
        XCTAssertFalse(CoverageAuditCopy.isHeavy(width: 1920, height: 1080, framesPerSecond: 120))
    }

    func testAFixtureThatIsNotHeavyGetsNoCopy() async throws {
        let copies = CoverageAuditCopy(directory: directory, fetch: { _, _, _ in XCTFail("nothing is fetched"); return false },
                                       encode: { _, _ in XCTFail("nothing is made") })
        let outcome = await copies.make(source(try fixture("trimmed-mid-frame")))
        XCTAssertEqual(outcome, .notNeeded)
    }

    func testThePublishedCopyIsKeptWhenItsFramesAreTheOriginals() async throws {
        let original = try fixture("trimmed-mid-frame")
        let copies = CoverageAuditCopy(directory: directory,
                                       fetch: { id, project, out in
                                           XCTAssertEqual(id, "rec"); XCTAssertEqual(project, "P")
                                           return (try? FileManager.default.copyItem(at: original, to: out)) != nil
                                       },
                                       encode: { _, _ in XCTFail("the published copy passed: none is made here") })
        let noneYet = await copies.ready(for: "sha256:abc/def")
        XCTAssertNil(noneYet)
        let outcome = await copies.makeCopy(source(original))
        let kept = copies.url(for: "sha256:abc/def")
        XCTAssertEqual(outcome, .made(kept))
        XCTAssertEqual(kept.deletingLastPathComponent().path, directory.path, "the fingerprint's slash does not make a folder")
        let ready = await copies.ready(for: "sha256:abc/def")
        XCTAssertEqual(ready, kept)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2, "the copy and its frame identity, no work file")
    }

    func testAPublishedCopyWithOtherFramesIsNotKeptAndOneIsMadeHere() async throws {
        let original = try fixture("trimmed-mid-frame"), other = try fixture("open-gop-hevc-leading3")
        let copies = CoverageAuditCopy(directory: directory,
                                       fetch: { _, _, out in (try? FileManager.default.copyItem(at: other, to: out)) != nil },
                                       encode: puts(original))
        let outcome = await copies.makeCopy(source(original))
        XCTAssertEqual(outcome, .made(copies.url(for: "sha256:abc/def")))
        XCTAssertEqual(try Data(contentsOf: copies.url(for: "sha256:abc/def")), try Data(contentsOf: original))
    }

    func testACopyMadeHereWithOtherFramesIsNotKept() async throws {
        let original = try fixture("trimmed-mid-frame")
        let copies = CoverageAuditCopy(directory: directory, fetch: { _, _, _ in false }, encode: puts(try fixture("open-gop-hevc-leading3")))
        guard case .failed(let why) = await copies.makeCopy(source(original)) else { return XCTFail("a copy with other frames was kept") }
        XCTAssertTrue(why.contains("does not have the original's frames"), why)
        let ready = await copies.ready(for: "sha256:abc/def")
        XCTAssertNil(ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], "nothing is left behind")
    }

    func testAKeptCopyThatWasDamagedSinceIsNotPlayed() async throws {
        let original = try fixture("trimmed-mid-frame")
        let copies = CoverageAuditCopy(directory: directory, fetch: { _, _, _ in false }, encode: puts(original))
        _ = await copies.makeCopy(source(original))
        let kept = copies.url(for: "sha256:abc/def")
        try FileManager.default.removeItem(at: kept)
        try FileManager.default.copyItem(at: try fixture("open-gop-hevc-leading3"), to: kept)
        let ready = await copies.ready(for: "sha256:abc/def")
        XCTAssertNil(ready)
    }
}
