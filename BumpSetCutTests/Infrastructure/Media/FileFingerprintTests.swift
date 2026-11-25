//
//  FileFingerprintTests.swift
//  BumpSetCutTests
//
//  A file's identity: its size and the hash of its first and last 4 MB.
//

import CryptoKit
import XCTest
@testable import BumpSetCut

final class FileFingerprintTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileFingerprintTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ data: Data) throws -> String {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    private func expected(_ data: Data) -> String {
        let chunk = 4 << 20
        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data.prefix(chunk))
        if data.count > chunk { hasher.update(data: data.suffix(min(chunk, data.count - chunk))) }
        return "file:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func testASmallFileIsHashedWholeWithItsSize() throws {
        let data = Data("volleyball".utf8)
        XCTAssertEqual(FileFingerprint.read(atPath: try write("a", data)), expected(data))
        XCTAssertEqual(FileFingerprint.read(atPath: try write("copy", data)), expected(data))
        XCTAssertNotEqual(FileFingerprint.read(atPath: try write("b", data + Data([0]))), expected(data))
    }

    func testALargeFileIsHashedAtItsEnds() throws {
        var data = Data(count: 9 << 20)
        data[0] = 1; data[data.count - 1] = 2
        XCTAssertEqual(FileFingerprint.read(atPath: try write("big", data)), expected(data))
        // Between 4 and 8 MB the two ends meet without overlapping.
        var middling = Data(count: 6 << 20)
        middling[5 << 20] = 7
        XCTAssertEqual(FileFingerprint.read(atPath: try write("mid", middling)), expected(middling))
        var changedEnd = data
        changedEnd[data.count - 1] = 3
        XCTAssertNotEqual(FileFingerprint.read(atPath: try write("big2", changedEnd)), expected(data))
    }

    func testAMissingFileHasNoFingerprint() {
        XCTAssertNil(FileFingerprint.read(atPath: dir.appendingPathComponent("nope").path))
    }
}
