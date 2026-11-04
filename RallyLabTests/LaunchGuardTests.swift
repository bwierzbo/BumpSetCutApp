//
//  LaunchGuardTests.swift
//  RallyLabTests
//
//  A launch with flags never falls through to the window app, and guarded mode (--project-root) runs only the
//  synthetic-acceptance operations, on an existing (or explicitly created) project under its root — never the default
//  location, never Scratch, never through a symlink — with its own preferences suite, pending folder and Keychain item.
//  Every check here uses injected file checks or a temporary folder of its own; no project, network or session.
//

import XCTest
@testable import RallyLab

final class LaunchGuardTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    /// project.json files declare the name of their folder unless `names` says otherwise.
    private func files(existing: Set<String>, symlinks: Set<String> = [], resolved: [String: String] = [:], regular: Set<String>? = nil,
                       names: [String: String] = [:]) -> LaunchGuard.Files {
        LaunchGuard.Files(
            exists: { existing.contains($0.standardizedFileURL.path) },
            isSymlink: { symlinks.contains($0.standardizedFileURL.path) },
            isRegularFile: { (regular ?? existing).contains($0.standardizedFileURL.path) },
            resolve: { URL(fileURLWithPath: resolved[$0.standardizedFileURL.path] ?? $0.standardizedFileURL.path, isDirectory: true) },
            projectName: { url in
                let path = url.standardizedFileURL.path
                guard existing.contains(path) else { return nil }
                return names[path] ?? url.deletingLastPathComponent().lastPathComponent
            })
    }

    /// An existing project /t/root/Accept-052 and a media file /t/root/media/A.mov.
    private var good: LaunchGuard.Files {
        files(existing: ["/t/root", "/t/root/Accept-052/project.json", "/t/root/media/A.mov", "/elsewhere/B.mov"],
              regular: ["/t/root/media/A.mov", "/elsewhere/B.mov"])
    }
    private let isolation = ["--defaults-suite", "rallylab.test.accept", "--pending-dir", "/t/root/pending"]
    private func guarded(_ ops: [String], project: String = "/t/root/Accept-052", root: String = "/t/root", iso: [String]? = nil) -> [String] {
        ["--project", project, "--project-root", root] + (iso ?? isolation) + ops
    }

    private func refusal(_ args: [String], _ files: LaunchGuard.Files? = nil) -> String? {
        LaunchGuard.refusal(for: ["RallyLab"] + args, home: home, files: files ?? good)?.message
    }

    // MARK: - Rule 1: flags without a complete headless command

    func testFlagsWithoutAHeadlessCommandAreRefusedBeforeAnythingOpens() {
        XCTAssertNotNil(refusal(["--status"]), "the 2026-11-04 incident: --status alone reopened the last project")
        XCTAssertNotNil(refusal(["--sync-phone", "--labels-only"]))
        XCTAssertNotNil(refusal(["--defaults-suite", "x"]))
        XCTAssertNotNil(refusal(["--project-root", "/t"]), "a root without --project is a flagged launch with no command")
    }

    func testAProjectCommandWithoutItsValueIsRefused() {
        XCTAssertNotNil(refusal(["--project"]))
        XCTAssertNotNil(refusal(["--project", "--status"]))
        XCTAssertNotNil(refusal(["--project-root", "/t/root", "--project"]))
        XCTAssertNil(refusal(["--project", "v3"]))
    }

    func testALaunchWithoutDoubleDashFlagsOpensTheWindowApp() {
        XCTAssertNil(refusal([]))
        XCTAssertNil(refusal(["-NSDocumentRevisionsDebugMode", "YES"]), "Xcode's single-dash arguments are not headless flags")
    }

    func testOrdinaryHeadlessCommandsAreUnchanged() {
        XCTAssertNil(refusal(["--project", "v3", "--status"]))
        XCTAssertNil(refusal(["--project", "v3", "--pretrack", "--defaults-suite", "anything"]), "unguarded runs keep every flag they had")
        XCTAssertNil(refusal(["--sample", "/x/a.mov"]))
        XCTAssertNil(refusal(["--export-training-data"]))
    }

    // MARK: - Guarded mode: operations

    func testGuardedModeAcceptsOnlyTheAcceptanceOperations() {
        XCTAssertNil(refusal(guarded(["--status"])))
        XCTAssertNil(refusal(guarded(["--phone-sign-in", "lead@example.com"])))
        XCTAssertNil(refusal(guarded(["--sign-out"])))
        XCTAssertNil(refusal(guarded(["--publish-identities"])))
        XCTAssertNil(refusal(guarded(["--sync-phone", "--labels-only"])))
        XCTAssertNil(refusal(guarded(["--create"], project: "/t/root/Accept-new")))
        XCTAssertNotNil(refusal(guarded([])), "a launch with no primary operation has no purpose and is refused")
    }

    func testGuardedModeRunsExactlyOnePrimaryOperation() {
        XCTAssertNotNil(refusal(guarded(["--create", "--phone-sign-in", "lead@example.com"], project: "/t/root/Accept-new")), "creation + authentication")
        XCTAssertNotNil(refusal(guarded(["--phone-sign-in", "lead@example.com", "--sync-phone"])), "authentication + synchronisation")
        XCTAssertNotNil(refusal(guarded(["--create", "--sync-phone"], project: "/t/root/Accept-new")), "creation + synchronisation")
        XCTAssertNotNil(refusal(guarded(["--status", "--sync-phone"])))
        XCTAssertNotNil(refusal(guarded(["--sign-out", "--publish-identities"])))
        XCTAssertNotNil(refusal(guarded(["--publish-identities", "--sync-phone", "--labels-only"])))
        XCTAssertNotNil(refusal(guarded(["--labels-only"])), "--labels-only is only part of --sync-phone")
        XCTAssertNotNil(refusal(guarded(["--status", "--labels-only"])))
        XCTAssertNotNil(refusal(guarded(["--sync-phone", "--add-extras", "Beach", "/t/root/media/A.mov"])), "--add-extras is only part of --create")
        for op in [["--status"], ["--phone-sign-in", "lead@example.com"], ["--sign-out"], ["--publish-identities"], ["--sync-phone"], ["--sync-phone", "--labels-only"]] {
            XCTAssertNil(refusal(guarded(op)), op.joined(separator: " "))
        }
        XCTAssertNil(refusal(guarded(["--create", "--add-extras", "Beach", "/t/root/media/A.mov"], project: "/t/root/Accept-new")))
    }

    func testGuardedModeRefusesOtherRunnersAndOperations() {
        XCTAssertNotNil(refusal(guarded(["--sample", "/t/root/media/A.mov"])), "the sampler runner never runs in guarded mode")
        XCTAssertNotNil(refusal(guarded(["--export-training-data"])), "the exporter never runs in guarded mode")
        XCTAssertNotNil(refusal(guarded(["--pretrack"])))
        XCTAssertNotNil(refusal(guarded(["--get", "x", "y"])))
        XCTAssertNotNil(refusal(guarded(["--remake-copies"])))
        XCTAssertNotNil(refusal(guarded(["--phone-sign-in"])), "sign-in needs its email")
        XCTAssertNotNil(refusal(guarded(["--add-extras", "Beach", "/t/root/media/A.mov"])), "adding footage is only part of --create")
    }

    // MARK: - Guarded mode: the project

    func testGuardedModeOpensAnExistingProjectUnderTheRoot() throws {
        let g = try LaunchGuard.guarded(arguments: ["RallyLab"] + guarded(["--sync-phone"]), home: home, files: good).get()
        XCTAssertEqual(g.project.path, "/t/root/Accept-052")
        XCTAssertEqual(g.root.path, "/t/root")
        XCTAssertEqual(g.defaultsSuite, "rallylab.test.accept")
        XCTAssertEqual(g.pendingDirectory.path, "/t/root/pending")
        XCTAssertFalse(g.create)
        XCTAssertEqual(g.extras, [])
    }

    func testGuardedModeRequiresAbsolutePathsAndAnExistingProject() {
        XCTAssertNotNil(refusal(guarded(["--status"], project: "Accept-052")), "a bare name is never guarded")
        XCTAssertNotNil(refusal(guarded(["--status"], root: "t/root")))
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/t/root/Accept-other")), "no project.json: nothing is created without --create")
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/t/root")), "the root itself is not a project under it")
    }

    func testGuardedModeRefusesTheDefaultLocationAndScratchAnywhere() {
        let files = self.files(existing: ["/Users/someone/Movies/RallyLab/Projects/Scratch/project.json", "/Users/someone/Movies/RallyLab/Projects",
                                          "/Users/someone/Movies", "/t/root", "/t/root/Scratch/project.json", "/t/root/Accept-x/project.json"])
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/Users/someone/Movies/RallyLab/Projects/Scratch", root: "/Users/someone/Movies/RallyLab/Projects",
                                        iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "/Users/someone/Movies/RallyLab/Projects/p"]), files))
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/Users/someone/Movies/RallyLab/Projects/Scratch", root: "/Users/someone/Movies",
                                        iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "/Users/someone/Movies/p"]), files),
                        "a root above the default location is refused too")
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/t/root/Scratch"), files), "a folder named Scratch is refused wherever it is")
        XCTAssertNil(refusal(guarded(["--status"], project: "/t/root/Accept-x"), files))
    }

    func testGuardedModeFollowsSymlinksForContainmentAndRefusesALinkedProject() {
        let files = self.files(existing: ["/t/root", "/elsewhere/Accept-052/project.json", "/t/root/Accept-real/project.json"],
                               symlinks: ["/t/root/alias"],
                               resolved: ["/t/root/link": "/elsewhere/Accept-052"])
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/t/root/link"), files), "resolves outside the root")
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/t/root/alias"), files), "the project path itself is a link")
        XCTAssertNil(refusal(guarded(["--status"], project: "/t/root/Accept-real"), files))
    }

    // MARK: - Guarded mode: the identity the server will see

    func testGuardedModeRefusesAProjectWhoseDeclaredNameIsNotItsTestFolder() {
        let copied = files(existing: ["/t/root", "/t/root/Accept-052/project.json"], names: ["/t/root/Accept-052/project.json": "Scratch"])
        XCTAssertNotNil(refusal(guarded(["--publish-identities"]), copied), "a copy of Scratch under a test folder would publish Scratch's withheld list")
        let renamed = files(existing: ["/t/root", "/t/root/Accept-052/project.json"], names: ["/t/root/Accept-052/project.json": "Accept-053"])
        XCTAssertNotNil(refusal(guarded(["--sync-phone"]), renamed), "a renamed folder")
        let unreadable = LaunchGuard.Files(exists: { _ in true }, isSymlink: { _ in false }, isRegularFile: { _ in true },
                                           resolve: { $0.standardizedFileURL }, projectName: { _ in nil })
        XCTAssertNotNil(refusal(guarded(["--status"]), unreadable), "a project.json without a decodable name")
        XCTAssertNil(refusal(guarded(["--publish-identities"])), "the folder's own name, in the test namespace")
    }

    func testGuardedProjectsMustBeNamedInTheTestNamespace() {
        let prod = files(existing: ["/t/root", "/t/root/Scratch2/project.json", "/t/root/Test1/project.json", "/t/root/Mine/project.json"])
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/t/root/Mine"), prod), "no Accept- prefix")
        XCTAssertNotNil(refusal(guarded(["--status"], project: "/t/root/Test1"), prod), "a production name")
        XCTAssertNotNil(refusal(guarded(["--create"], project: "/t/root/Mine-new"), prod), "creation outside the namespace")
        XCTAssertTrue(LaunchGuard.isTestNamespace("Accept-052"))
        XCTAssertFalse(LaunchGuard.isTestNamespace("Scratch"))
        XCTAssertFalse(LaunchGuard.isTestNamespace("Accept"))
    }

    func testGuardedCreationRefusesABasenameThatNormalisationWouldChange() {
        XCTAssertNotNil(refusal(guarded(["--create"], project: "/t/root/Accept 052")), "a space becomes _ on creation: another folder")
        XCTAssertNotNil(refusal(guarded(["--create"], project: "/t/root/Accept-052.v2")), "a dot becomes _ on creation")
        XCTAssertNil(refusal(guarded(["--create"], project: "/t/root/Accept-052_v2")))
    }

    // MARK: - Guarded mode: isolation parameters

    func testGuardedModeRequiresATestDefaultsSuite() {
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--pending-dir", "/t/root/pending"])), "no suite: no fallback to the person's preferences")
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "--pending-dir", "/t/root/pending"])), "a suite without a value")
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.accept052", "--pending-dir", "/t/root/pending"])), "not a test-designated suite")
        XCTAssertNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.test.accept052", "--pending-dir", "/t/root/pending"])))
    }

    func testGuardedModeRequiresAPendingFolderInsideTheRoot() {
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.test.x"])), "no pending folder: no fallback to Application Support")
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "pending"])), "relative")
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "/t/other/pending"])), "outside the root")
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "/t/root"])), "the root itself is not inside it")
        let escaping = files(existing: ["/t/root", "/t/root/Accept-052/project.json"], symlinks: ["/t/root/plink"], resolved: ["/t/root/pending": "/var/pending"])
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "/t/root/pending"]), escaping), "resolves outside through a link")
        XCTAssertNotNil(refusal(guarded(["--status"], iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "/t/root/plink"]), escaping), "is itself a link")
    }

    // MARK: - Guarded creation

    func testGuardedCreationNeedsAFreshFolderUnderTheRootAndTestOnlyInputs() throws {
        let g = try LaunchGuard.guarded(arguments: ["RallyLab"] + guarded(["--create", "--add-extras", "Beach", "/t/root/media/A.mov"], project: "/t/root/Accept-new"),
                                        home: home, files: good).get()
        XCTAssertTrue(g.create)
        XCTAssertEqual(g.project.path, "/t/root/Accept-new")
        XCTAssertEqual(g.extras.map(\.path), ["/t/root/media/A.mov"])
        XCTAssertNil(refusal(guarded(["--create"], project: "/t/root/Accept-new")), "creation without footage is allowed")
        XCTAssertNotNil(refusal(guarded(["--create"])), "an existing project is never re-created")
        let occupied = files(existing: ["/t/root", "/t/root/Accept-empty", "/t/root/Accept-full", "/t/root/Accept-full/notes.txt", "/t/root/media/A.mov"], regular: ["/t/root/Accept-full/notes.txt", "/t/root/media/A.mov"])
        XCTAssertNotNil(refusal(guarded(["--create"], project: "/t/root/Accept-empty"), occupied), "an existing empty folder is not a new folder")
        XCTAssertNotNil(refusal(guarded(["--create"], project: "/t/root/Accept-full"), occupied), "an existing folder with other files")
        XCTAssertNil(refusal(guarded(["--create"], project: "/t/root/Accept-absent"), occupied), "a genuinely absent folder")
        XCTAssertNotNil(refusal(guarded(["--create"], project: "/t/missing/Accept-new", root: "/t/missing",
                                        iso: ["--defaults-suite", "rallylab.test.x", "--pending-dir", "/t/missing/p"])), "the root must exist")
        XCTAssertNotNil(refusal(guarded(["--create", "--add-extras", "Beach", "/elsewhere/B.mov"], project: "/t/root/Accept-new")), "an input outside the root")
        XCTAssertNotNil(refusal(guarded(["--create", "--add-extras", "Beach", "media/A.mov"], project: "/t/root/Accept-new")), "a relative input")
        XCTAssertNotNil(refusal(guarded(["--create", "--add-extras", "Beach", "/t/root/media/missing.mov"], project: "/t/root/Accept-new")), "a missing input")
        XCTAssertNotNil(refusal(guarded(["--create", "--add-extras", "Beach", "/t/root/media"], project: "/t/root/Accept-new")), "not a video file")
        XCTAssertNotNil(refusal(guarded(["--create", "--add-extras", "Space", "/t/root/media/A.mov"], project: "/t/root/Accept-new")), "not an environment")
        XCTAssertNotNil(refusal(guarded(["--create", "--add-extras", "Beach"], project: "/t/root/Accept-new")), "no files")
        let linked = files(existing: ["/t/root", "/t/root/media/L.mov"], symlinks: ["/t/root/media/L.mov"])
        XCTAssertNotNil(refusal(guarded(["--create", "--add-extras", "Beach", "/t/root/media/L.mov"], project: "/t/root/Accept-new"), linked), "a linked input")
    }

    // MARK: - On the real file system

    func testGuardedModeOnTheRealFileSystem() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("launch-guard-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let project = root.appendingPathComponent("Accept-052", isDirectory: true)
        let empty = root.appendingPathComponent("Accept-empty", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for dir in [project, empty, outside, root.appendingPathComponent("media")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(#"{"name":"Accept-052"}"#.utf8).write(to: project.appendingPathComponent("project.json"))
        try Data(#"{"name":"Accept-052"}"#.utf8).write(to: outside.appendingPathComponent("project.json"))
        let copied = root.appendingPathComponent("Accept-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
        try Data(#"{"name":"Scratch"}"#.utf8).write(to: copied.appendingPathComponent("project.json"))
        try Data("x".utf8).write(to: root.appendingPathComponent("media/A.mov"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("plink"), withDestinationURL: outside)
        let iso = { (pending: URL) in ["--defaults-suite", "rallylab.test.fs", "--pending-dir", pending.path] }
        let args = { (p: URL, pending: URL, ops: [String]) in ["RallyLab", "--project", p.path, "--project-root", root.path] + iso(pending) + ops }
        let pending = root.appendingPathComponent("pending")

        let opened = try LaunchGuard.guarded(arguments: args(project, pending, ["--status"]), home: home).get()
        XCTAssertEqual(opened.project.path, LaunchGuard.canonical(project).path)
        XCTAssertEqual(opened.pendingDirectory.path, LaunchGuard.canonical(pending).path)
        XCTAssertNotNil(LaunchGuard.refusal(for: args(empty, pending, ["--status"]), home: home), "no project.json")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(copied, pending, ["--publish-identities"]), home: home), "project.json declares Scratch")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(root.appendingPathComponent("link"), pending, ["--status"]), home: home), "a symlink escaping the root")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(outside, pending, ["--status"]), home: home), "outside the root")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(project, root.appendingPathComponent("plink"), ["--status"]), home: home), "a pending folder escaping through a link")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(empty, pending, ["--create"]), home: home), "an existing empty folder is refused for --create")
        let populated = root.appendingPathComponent("Accept-populated", isDirectory: true)
        try FileManager.default.createDirectory(at: populated, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: populated.appendingPathComponent("notes.txt"))
        XCTAssertNotNil(LaunchGuard.refusal(for: args(populated, pending, ["--create"]), home: home), "an existing populated folder is refused for --create")
        XCTAssertNotNil(LaunchGuard.refusal(for: args(project, pending, ["--create"]), home: home), "an existing project is refused for --create")
        let created = try LaunchGuard.guarded(arguments: args(root.appendingPathComponent("Accept-new"), pending, ["--create", "--add-extras", "Beach", root.appendingPathComponent("media/A.mov").path]), home: home).get()
        XCTAssertTrue(created.create)
        XCTAssertEqual(created.extras.count, 1)
        XCTAssertNotNil(LaunchGuard.refusal(for: args(root.appendingPathComponent("Accept-new"), pending, ["--create", "--add-extras", "Beach", outside.appendingPathComponent("project.json").path]), home: home), "an input outside the root")
    }

    func testCanonicalPathsKeepThePrivatePrefixForExistingAndAbsentPathsAlike() throws {
        // /tmp is a symlink to /private/tmp on macOS. An existing folder and an absent child must canonicalise to the same
        // spelling, or a guarded --create under /private/tmp/… is refused as "outside the root" (2026-11-04).
        let name = "launch-guard-canon-\(UUID().uuidString)"
        let viaTmp = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: viaTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: viaTmp) }
        let viaPrivate = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        XCTAssertEqual(LaunchGuard.canonical(viaTmp).path, "/private/tmp/\(name)")
        XCTAssertEqual(LaunchGuard.canonical(viaPrivate).path, "/private/tmp/\(name)")
        XCTAssertEqual(LaunchGuard.canonical(viaTmp.appendingPathComponent("absent/child")).path, "/private/tmp/\(name)/absent/child")
        XCTAssertEqual(LaunchGuard.canonical(viaPrivate.appendingPathComponent("absent")).path, "/private/tmp/\(name)/absent")
        XCTAssertTrue(LaunchGuard.isSameFolder(viaTmp, viaPrivate))
        // The guarded create that was refused: root given as /private/tmp/…, destination absent under it.
        let args = ["RallyLab", "--project", viaPrivate.appendingPathComponent("Projects/Accept-new").path, "--project-root", viaPrivate.path,
                    "--defaults-suite", "rallylab.test.canon", "--pending-dir", viaPrivate.appendingPathComponent("pending").path, "--create"]
        try FileManager.default.createDirectory(at: viaPrivate.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let g = try LaunchGuard.guarded(arguments: args, home: home).get()
        XCTAssertEqual(g.project.path, "/private/tmp/\(name)/Projects/Accept-new")
        XCTAssertEqual(g.root.path, "/private/tmp/\(name)")
        XCTAssertEqual(g.pendingDirectory.path, "/private/tmp/\(name)/pending")
        // And with the root spelled /tmp/… and the project /private/tmp/…: still the same root.
        let mixed = ["RallyLab", "--project", viaPrivate.appendingPathComponent("Projects/Accept-new").path, "--project-root", viaTmp.path,
                     "--defaults-suite", "rallylab.test.canon", "--pending-dir", viaTmp.appendingPathComponent("pending").path, "--create"]
        XCTAssertNil(LaunchGuard.refusal(for: mixed, home: home))
    }

    func testIsSameFolderFollowsSymlinksOnBothSides() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("launch-guard-same-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(LaunchGuard.isSameFolder(link, real))
        XCTAssertFalse(LaunchGuard.isSameFolder(base, real))
    }

    // MARK: - Isolation of the run's state

    func testGuardedRunIsTheValidatedRunOrNil() {
        XCTAssertEqual(LaunchGuard.guardedRun(for: ["RallyLab"] + guarded(["--status"]), home: home, files: good)?.project.path, "/t/root/Accept-052")
        XCTAssertNil(LaunchGuard.guardedRun(for: ["RallyLab", "--project", "/t/root/Accept-052"], home: home, files: good), "unguarded: nil")
        XCTAssertNil(LaunchGuard.guardedRun(for: ["RallyLab"] + guarded(["--status"], project: "/t/root/Accept-other"), home: home, files: good))
    }

    @MainActor func testASamplerBuiltForTheRunKeepsItsDatasetOutOfTheStandardDefaults() throws {
        let suite = "rallylab.test.sampler.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-guard-ds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = UserDefaults.standard.string(forKey: "RallyLab.datasetRoot")
        let sampler = SamplerModel(defaults: defaults, root: root)
        XCTAssertEqual(sampler.datasetRoot.standardizedFileURL.path, root.standardizedFileURL.path, "starts on the given root, not the person's dataset")
        sampler.setDatasetRoot(root)
        XCTAssertEqual(defaults.string(forKey: "RallyLab.datasetRoot"), root.path, "remembered in the run's suite")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "RallyLab.datasetRoot"), before, "the person's preference is untouched")
    }

    func testTheAcceptanceKeychainServiceIsNotTheAppsAndTheDefaultIsUnchanged() {
        XCTAssertEqual(LabelingClient.keychainService, "app.BumpSetCut.labeling", "the app's service, untouched by the tests' host")
        XCTAssertNotEqual(LaunchGuard.acceptanceKeychainService, LabelingClient.keychainService)
        XCTAssertTrue(LaunchGuard.acceptanceKeychainService.hasPrefix("app.BumpSetCut.labeling."))
    }

    func testTheHostRunsUnderXCTestAndRestoresNoProject() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"], "ProjectsModel.init skips the last-project restore under this variable (PR #85)")
    }
}
