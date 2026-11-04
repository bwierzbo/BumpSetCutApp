//
//  LaunchGuardTests.swift
//  RallyLabTests
//
//  A launch with flags never falls through to the window app, and guarded mode (--project-root) opens only an
//  existing project under its root — never the default location, never Scratch, never through a symlink, never created.
//

import XCTest
@testable import RallyLab

final class LaunchGuardTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func files(existing: Set<String>, symlinks: Set<String> = [], resolved: [String: String] = [:]) -> LaunchGuard.Files {
        LaunchGuard.Files(
            exists: { existing.contains($0.standardizedFileURL.path) },
            isSymlink: { symlinks.contains($0.standardizedFileURL.path) },
            resolve: { URL(fileURLWithPath: resolved[$0.standardizedFileURL.path] ?? $0.standardizedFileURL.path, isDirectory: true) })
    }

    private func refusal(_ args: [String], _ files: LaunchGuard.Files? = nil) -> String? {
        LaunchGuard.refusal(for: ["RallyLab"] + args, home: home, files: files ?? self.files(existing: []))?.message
    }

    // MARK: - Rule 1: flags without a headless command

    func testFlagsWithoutAHeadlessCommandAreRefusedBeforeAnythingOpens() {
        XCTAssertNotNil(refusal(["--status"]), "the 2026-11-04 incident: --status alone reopened the last project")
        XCTAssertNotNil(refusal(["--sync-phone", "--labels-only"]))
        XCTAssertNotNil(refusal(["--defaults-suite", "x"]))
        XCTAssertNotNil(refusal(["--project-root", "/t"]), "a root without --project is a flagged launch with no command")
    }

    func testALaunchWithoutDoubleDashFlagsOpensTheWindowApp() {
        XCTAssertNil(refusal([]))
        XCTAssertNil(refusal(["-NSDocumentRevisionsDebugMode", "YES"]), "Xcode's single-dash arguments are not headless flags")
    }

    func testHeadlessCommandsAreLetThrough() {
        XCTAssertNil(refusal(["--project", "v3", "--status"]))
        XCTAssertNil(refusal(["--sample", "/x/a.mov"]))
        XCTAssertNil(refusal(["--export-training-data"]))
    }

    // MARK: - Rule 2: guarded mode

    private let goodFiles: LaunchGuard.Files = LaunchGuard.Files(
        exists: { $0.standardizedFileURL.path == "/t/root/Accept-052/project.json" },
        isSymlink: { _ in false },
        resolve: { $0.standardizedFileURL })

    func testGuardedModeOpensAnExistingProjectUnderTheRoot() throws {
        let dir = try LaunchGuard.guardedProject(arguments: ["RallyLab", "--project", "/t/root/Accept-052", "--project-root", "/t/root", "--sync-phone"],
                                                 home: home, files: goodFiles).get()
        XCTAssertEqual(dir.path, "/t/root/Accept-052")
        XCTAssertNil(refusal(["--project", "/t/root/Accept-052", "--project-root", "/t/root", "--sync-phone"], goodFiles))
    }

    func testGuardedModeRequiresAbsolutePathsAndAnExistingProject() {
        XCTAssertNotNil(refusal(["--project", "Accept-052", "--project-root", "/t/root"], goodFiles), "a bare name is never guarded")
        XCTAssertNotNil(refusal(["--project", "/t/root/Accept-052", "--project-root", "t/root"], goodFiles))
        XCTAssertNotNil(refusal(["--project", "/t/root/Other", "--project-root", "/t/root"], goodFiles), "no project.json: nothing is created")
        XCTAssertNotNil(refusal(["--project", "/t/root", "--project-root", "/t/root"], goodFiles), "the root itself is not a project under it")
    }

    func testGuardedModeRefusesTheDefaultLocationAndScratchAnywhere() {
        let files = self.files(existing: ["/Users/someone/Movies/RallyLab/Projects/Scratch/project.json",
                                          "/t/root/Scratch/project.json", "/t/root/x/project.json"])
        XCTAssertNotNil(refusal(["--project", "/Users/someone/Movies/RallyLab/Projects/Scratch", "--project-root", "/Users/someone/Movies/RallyLab/Projects"], files))
        XCTAssertNotNil(refusal(["--project", "/Users/someone/Movies/RallyLab/Projects/Scratch", "--project-root", "/Users/someone/Movies"], files))
        XCTAssertNotNil(refusal(["--project", "/t/root/Scratch", "--project-root", "/t/root"], files), "a folder named Scratch is refused wherever it is")
        XCTAssertNil(refusal(["--project", "/t/root/x", "--project-root", "/t/root"], files))
    }

    func testGuardedModeFollowsSymlinksForContainmentAndRefusesALinkedProject() {
        // /t/root/link → /elsewhere/project (escapes the root); /t/root/alias is itself a symlink.
        let files = self.files(existing: ["/elsewhere/project/project.json", "/t/root/real/project.json"],
                               symlinks: ["/t/root/alias"],
                               resolved: ["/t/root/link": "/elsewhere/project"])
        XCTAssertNotNil(refusal(["--project", "/t/root/link", "--project-root", "/t/root"], files), "resolves outside the root")
        XCTAssertNotNil(refusal(["--project", "/t/root/alias", "--project-root", "/t/root"], files), "the project path itself is a link")
        XCTAssertNil(refusal(["--project", "/t/root/real", "--project-root", "/t/root"], files))
    }

    func testGuardedModeOnTheRealFileSystem() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("launch-guard-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let project = root.appendingPathComponent("Accept-052", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for dir in [project, empty, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("{}".utf8).write(to: project.appendingPathComponent("project.json"))
        try Data("{}".utf8).write(to: outside.appendingPathComponent("project.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let args = { (p: URL) in ["RallyLab", "--project", p.path, "--project-root", root.path, "--status"] }
        XCTAssertEqual(try LaunchGuard.guardedProject(arguments: args(project), home: home).get().standardizedFileURL.path,
                       project.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertNotNil(LaunchGuard.refusal(for: args(empty), home: home), "no project.json")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(root.appendingPathComponent("link")), home: home), "a symlink escaping the root")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(outside), home: home), "outside the root")
    }

    // MARK: - Isolation

    func testPendingDirectoryAndDefaultsSuiteComeFromTheRun() {
        XCTAssertEqual(LaunchGuard.pendingDirectory(for: ["RallyLab", "--pending-dir", "/t/pending"]).path, "/t/pending")
        XCTAssertEqual(LaunchGuard.pendingDirectory(for: ["RallyLab"]), Pending.defaultDirectory)
        XCTAssertNotEqual(LaunchGuard.defaults(for: ["RallyLab", "--defaults-suite", "rallylab.launch-guard.test"]), UserDefaults.standard)
        XCTAssertEqual(LaunchGuard.defaults(for: ["RallyLab"]), UserDefaults.standard)
    }
}
