//
//  MultipartFileWriterTests.swift
//  BumpSetCutTests
//
//  Locks down the streamed multipart body used for video uploads: exact
//  boundary/header framing, byte-exact payload across the 64KB chunk
//  boundary, and failing loudly instead of writing a truncated body.
//

import XCTest
@testable import BumpSetCut

final class MultipartFileWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartFileWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func expectedBody(boundary: String, fileName: String, payload: Data) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: video/mp4\r\n\r\n".utf8))
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func writeAndRead(payload: Data, boundary: String = "Boundary-TEST", fileName: String = "user/clip.mp4") throws -> (written: Data, expected: Data) {
        let input = tempDir.appendingPathComponent("input.mp4")
        let output = tempDir.appendingPathComponent("body.tmp")
        try payload.write(to: input)
        try SupabaseAPIClient.writeMultipartFile(boundary: boundary, fileURL: input, fileName: fileName, to: output)
        return (try Data(contentsOf: output), expectedBody(boundary: boundary, fileName: fileName, payload: payload))
    }

    func testFramesPayloadWithBoundaryAndHeaders() throws {
        let result = try writeAndRead(payload: Data("hello volleyball".utf8))
        XCTAssertEqual(result.written, result.expected)

        let text = String(decoding: result.written, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--Boundary-TEST\r\n"))
        XCTAssertTrue(text.contains("filename=\"user/clip.mp4\""))
        XCTAssertTrue(text.contains("Content-Type: video/mp4\r\n\r\nhello volleyball"))
        XCTAssertTrue(text.hasSuffix("\r\n--Boundary-TEST--\r\n"))
    }

    func testPayloadSpanningSeveralChunksIsByteExact() throws {
        // 64KB read buffer: cover an exact multiple plus a partial tail.
        let size = 65_536 * 3 + 123
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let result = try writeAndRead(payload: payload)
        XCTAssertEqual(result.written.count, result.expected.count)
        XCTAssertEqual(result.written, result.expected)
    }

    func testEmptyPayloadStillWritesHeaderAndFooter() throws {
        let result = try writeAndRead(payload: Data())
        XCTAssertEqual(result.written, result.expected)
    }

    func testUnwritableOutputThrowsInsteadOfTruncating() throws {
        let input = tempDir.appendingPathComponent("input.mp4")
        try Data("x".utf8).write(to: input)
        let output = tempDir.appendingPathComponent("missing-dir/body.tmp")
        XCTAssertThrowsError(
            try SupabaseAPIClient.writeMultipartFile(boundary: "B", fileURL: input, fileName: "f.mp4", to: output)
        )
    }
}
