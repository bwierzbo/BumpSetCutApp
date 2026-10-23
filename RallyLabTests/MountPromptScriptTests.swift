//
//  MountPromptScriptTests.swift
//  RallyLabTests
//
//  scripts/footage_share/mount_prompt.exp answers mount_smbfs's own password
//  prompt from the PW environment variable and returns mount_smbfs's exit
//  code — whether it asked (a fresh SMB session) or not (an open session
//  reused) — and never lets the password into an argument or its output.
//  A stand-in script plays mount_smbfs here.
//

import XCTest

final class MountPromptScriptTests: XCTestCase {

    private var root: URL!
    private let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/footage_share/mount_prompt.exp")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mount-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in for mount_smbfs: `body` is its shell script (its arguments are the real ones).
    private func standIn(_ body: String) throws -> URL {
        let url = root.appendingPathComponent("mount_smbfs")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func run(_ standIn: URL, password: String? = "s3cret-value", opts: String = "rdonly") throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = [script.path, "rallylab-share", "10.0.0.123", "RallyLabFootage", root.appendingPathComponent("mnt").path, opts]
        var env = ProcessInfo.processInfo.environment
        env["MOUNT_SMBFS_BIN"] = standIn.path
        env["PW"] = password
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testAnswersThePromptAndReturnsSuccessWithoutShowingThePassword() throws {
        // The stand-in checks what was typed, with the arguments mount_smbfs gets.
        let tool = try standIn("""
            [ "$1" = "-o" ] && [ "$2" = "rdonly" ] && [ "$3" = "//rallylab-share@10.0.0.123/RallyLabFootage" ] || exit 70
            printf 'Password for 10.0.0.123: '
            stty -echo 2>/dev/null; read -r typed; stty echo 2>/dev/null
            [ "$typed" = "s3cret-value" ] || { echo 'mount_smbfs: server rejected the connection: Authentication error'; exit 77; }
            exit 0
            """)
        let result = try run(tool)
        XCTAssertEqual(result.code, 0, result.output)
        XCTAssertTrue(result.output.contains("RallyLabFootage: mounted at"), result.output)
        XCTAssertFalse(result.output.contains("no prompt"), result.output)
        XCTAssertFalse(result.output.contains("s3cret-value"), "the password must never be in the output")
    }

    func testReturnsSuccessWhenNoPromptIsNeeded() throws {
        // An open SMB session is reused: mount_smbfs mounts and exits without asking.
        let tool = try standIn("exit 0")
        let result = try run(tool, opts: "")
        XCTAssertEqual(result.code, 0, result.output)
        XCTAssertTrue(result.output.contains("no prompt: an open session was reused"), result.output)
    }

    func testPropagatesAFailureAndRedactsThePasswordFromTheMessage() throws {
        let tool = try standIn("""
            printf 'Password for 10.0.0.123: '
            stty -echo 2>/dev/null; read -r typed; stty echo 2>/dev/null
            echo "mount_smbfs: server rejected the connection: Authentication error (tried $typed)"
            exit 77
            """)
        let result = try run(tool)
        XCTAssertEqual(result.code, 77, result.output)
        XCTAssertTrue(result.output.contains("mount_smbfs exit 77"), result.output)
        XCTAssertTrue(result.output.contains("Authentication error"), result.output)
        XCTAssertTrue(result.output.contains("<redacted>"), result.output)
        XCTAssertFalse(result.output.contains("s3cret-value"), "a message that echoes the password is redacted")
    }

    func testRefusesToRunWithoutAPassword() throws {
        let tool = try standIn("echo 'should not run'; exit 0")
        let result = try run(tool, password: nil)
        XCTAssertEqual(result.code, 4, result.output)
        XCTAssertFalse(result.output.contains("should not run"), result.output)
    }
}
