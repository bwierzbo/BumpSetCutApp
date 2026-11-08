//
//  LaunchGuard.swift
//  RallyLab
//
//  What a RallyLab launch is allowed to do before any project is opened. Decided from the command line alone,
//  before any model exists (a ProjectsModel restores the last project — the person's — the moment it is made):
//
//  1. A launch with any `--flag` is a headless run. If no complete headless command is present, the launch is
//     refused: it must never fall through to the window app and reopen the last project (on 2026-11-04
//     `RallyLab --status` without `--project` did exactly that, for 27 minutes, on the owner's project).
//  2. `--project-root <absolute dir>` is guarded mode, for synthetic acceptance and automation only. Everything is
//     validated here, and refused before a sampler, exporter, project or client exists:
//     - exactly one primary operation per launch — --status, --phone-sign-in <email>, --sign-out, --publish-identities,
//       --sync-phone [--labels-only] [--drop-first-settlement], --create [--add-extras <env> <files…>], or
//       --confirm-recording-type <session> <type> (the Mac's own confirmation, headless) — and any other flag
//       (--sample, --export-training-data, --pretrack, …) is refused;
//     - --project is an absolute path under the resolved root (symlinks followed), never itself a symlink, never the
//       default project location (~/Movies/RallyLab/Projects), never a folder named Scratch; without --create it must
//       hold project.json, with --create the folder must not exist at all; --add-extras files are absolute, existing
//       regular files under the root (test-only inputs);
//     - --defaults-suite is required and must begin with `rallylab.test.`; --pending-dir is required, absolute, no
//       symlink, resolving under the root. Neither ever falls back to the person's preferences or pending folder;
//     - the labeling session is kept under its own Keychain service (acceptanceKeychainService), never the app's;
//     - a guarded --sync-phone never pulls the phones' uploads into the project (LabelingSync importsPhoneUploads: false):
//       real footage a lead can see is never moved into a test namespace.
//

import Foundation

enum LaunchGuard {
    struct Refusal: Error, Equatable {
        let message: String
    }

    /// The flags that start a headless run; any other `--flag` alone is a refusal.
    static let headlessCommands: Set<String> = ["--project", "--sample", "--export-training-data", "--player-lab", "--player-lab-run"]

    /// Everything a guarded run may say on its command line.
    static let guardedFlags: Set<String> = ["--project", "--project-root", "--defaults-suite", "--pending-dir",
                                            "--create", "--add-extras", "--status", "--phone-sign-in", "--sign-out",
                                            "--publish-identities", "--sync-phone", "--labels-only",
                                            "--confirm-recording-type", "--drop-first-settlement"]
    /// A guarded launch does exactly one of these; --add-extras belongs to --create, --labels-only and
    /// --drop-first-settlement to --sync-phone.
    static let primaryOperations: Set<String> = ["--create", "--status", "--phone-sign-in", "--sign-out", "--publish-identities", "--sync-phone",
                                                 "--confirm-recording-type"]
    /// `--confirm-recording-type <session> <type>`: the Mac's own confirmation (the footage-type sheet's writer) for a
    /// synthetic recording, so the "a newer decision on the Mac wins" case can be exercised without the window app.
    static let recordingTypes: Set<String> = ["continuous", "edited", "unknown"]
    static let testSuitePrefix = "rallylab.test."
    /// A guarded project's name — the folder's name and the name project.json declares — begins with this, so the
    /// server namespace it publishes to (withheld list, rows, plan) can only ever be a test namespace.
    static let testNamespacePrefix = "Accept-"
    /// The Keychain service a guarded run keeps its labeling session under: a separate item from the app's
    /// `app.BumpSetCut.labeling`, which the app never reads and `--sign-out` clears.
    static let acceptanceKeychainService = "app.BumpSetCut.labeling.acceptance"
    static let extraEnvironments: Set<String> = ["Indoor", "Beach", "Grass"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// A validated guarded run.
    struct Guarded: Equatable {
        let root: URL
        let project: URL
        let defaultsSuite: String
        let pendingDirectory: URL
        let create: Bool
        let extras: [URL]
    }

    /// The file checks the rules need, injectable for tests.
    struct Files {
        var exists: (URL) -> Bool
        var isSymlink: (URL) -> Bool
        var isRegularFile: (URL) -> Bool
        var resolve: (URL) -> URL
        /// The `name` a project.json declares, nil when the file can't be read or decoded.
        var projectName: (URL) -> String?

        static let real = Files(
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            isSymlink: { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil },
            isRegularFile: { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeRegular },
            resolve: { canonical($0) },
            projectName: { url in
                struct Named: Decodable { let name: String }
                return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Named.self, from: $0) }?.name
            })
    }

    /// Whether `name` is a test namespace: the designated prefix, and never a known production project.
    static func isTestNamespace(_ name: String) -> Bool {
        name.hasPrefix(testNamespacePrefix) && !["Scratch", "Test1"].contains(name)
    }

    /// A headless command that will actually start a run: `--project` must carry its value (HeadlessProjects returns
    /// false without one, which would fall through to the window app); `--sample` exits on its own without inputs;
    /// `--export-training-data` takes an optional path; `--player-lab <experiment>` and `--player-lab-run <experiment>`
    /// (PlayerLab, the player-feasibility research) need their experiment folder and never open a project.
    static func hasHeadlessCommand(_ arguments: [String]) -> Bool {
        value(after: "--project", in: arguments) != nil || arguments.contains("--sample") || arguments.contains("--export-training-data")
            || value(after: "--player-lab", in: arguments) != nil || value(after: "--player-lab-run", in: arguments) != nil
    }

    /// Why this launch must not go on, or nil when it may.
    static func refusal(for arguments: [String], home: URL, files: Files = .real) -> Refusal? {
        let args = Array(arguments.dropFirst())
        let flags = args.filter { $0.hasPrefix("--") }
        if !flags.isEmpty, !hasHeadlessCommand(arguments) {
            return Refusal(message: "no complete headless command among \(flags.joined(separator: " ")): a launch with flags never opens the window app (it would reopen the last project). Headless runs start with --project <name or path>, --sample <inputs…> or --export-training-data.")
        }
        if args.contains("--project-root") {
            if case .failure(let refusal) = guarded(arguments: arguments, home: home, files: files) { return refusal }
        }
        return nil
    }

    /// Guarded mode, fully validated, or why not.
    static func guarded(arguments: [String], home: URL, files: Files = .real) -> Result<Guarded, Refusal> {
        let args = Array(arguments.dropFirst())
        let flags = args.filter { $0.hasPrefix("--") }
        if let other = flags.first(where: { !guardedFlags.contains($0) }) {
            return .failure(Refusal(message: "\(other) is not an operation of guarded mode (allowed: \(guardedFlags.sorted().joined(separator: " ")))"))
        }
        // One primary operation per launch: creation, authentication and synchronisation never share a process.
        let primaries = Set(flags).intersection(primaryOperations).sorted()
        guard primaries.count == 1 else {
            return .failure(Refusal(message: "a guarded launch does exactly one of \(primaryOperations.sorted().joined(separator: ", ")); this one has \(primaries.isEmpty ? "none" : primaries.joined(separator: " "))"))
        }
        if flags.contains("--add-extras"), primaries[0] != "--create" {
            return .failure(Refusal(message: "--add-extras is only part of --create"))
        }
        if flags.contains("--labels-only"), primaries[0] != "--sync-phone" {
            return .failure(Refusal(message: "--labels-only is only part of --sync-phone"))
        }
        // Fault injection for the lost-acknowledgement case: the first settlement after a written record is dropped as
        // if the network had failed — only with --sync-phone, only in guarded mode, only on a test project.
        if flags.contains("--drop-first-settlement"), primaries[0] != "--sync-phone" {
            return .failure(Refusal(message: "--drop-first-settlement is only part of --sync-phone"))
        }
        if primaries[0] == "--confirm-recording-type" {
            guard let i = arguments.firstIndex(of: "--confirm-recording-type"), arguments.indices.contains(i + 2),
                  !arguments[i + 1].hasPrefix("--"), recordingTypes.contains(arguments[i + 2]) else {
                return .failure(Refusal(message: "--confirm-recording-type needs <session name> <continuous|edited|unknown>"))
            }
        }
        guard let root = value(after: "--project-root", in: arguments) else {
            return .failure(Refusal(message: "--project-root needs a directory"))
        }
        guard root.hasPrefix("/") else {
            return .failure(Refusal(message: "--project-root must be an absolute path, not \(root)"))
        }
        guard let project = value(after: "--project", in: arguments) else {
            return .failure(Refusal(message: "--project-root needs --project <absolute path of the test project>"))
        }
        guard project.hasPrefix("/") else {
            return .failure(Refusal(message: "with --project-root, --project must be an absolute path, not \(project)"))
        }
        let resolvedRoot = files.resolve(URL(fileURLWithPath: root, isDirectory: true))
        let defaultLocation = files.resolve(home.appendingPathComponent("Movies/RallyLab/Projects", isDirectory: true))
        if isSame(resolvedRoot, as: defaultLocation) || isInside(resolvedRoot, of: defaultLocation) || isInside(defaultLocation, of: resolvedRoot) {
            return .failure(Refusal(message: "--project-root \(resolvedRoot.path) overlaps the default project location \(defaultLocation.path): never a test root"))
        }
        if resolvedRoot.pathComponents.contains("Scratch") {
            return .failure(Refusal(message: "--project-root \(resolvedRoot.path) is or is under a folder named Scratch: refused"))
        }
        let given = URL(fileURLWithPath: project, isDirectory: true)
        if files.isSymlink(given) {
            return .failure(Refusal(message: "\(project) is a symbolic link: give the project's real folder"))
        }
        let resolved = files.resolve(given)
        if isSame(resolved, as: defaultLocation) || isInside(resolved, of: defaultLocation) {
            return .failure(Refusal(message: "\(resolved.path) is in the default project location \(defaultLocation.path): never a test project"))
        }
        if resolved.pathComponents.contains("Scratch") {
            return .failure(Refusal(message: "\(resolved.path) is or is under a folder named Scratch: refused in guarded mode"))
        }
        guard isInside(resolved, of: resolvedRoot) else {
            return .failure(Refusal(message: "\(project) resolves to \(resolved.path), outside --project-root \(resolvedRoot.path)"))
        }
        let create = arguments.contains("--create")
        let folderName = resolved.lastPathComponent
        // The identity the server will see is the project's NAME (project.json), not the folder: both must be the same
        // test namespace, so a copy or rename of a production project can never publish under its name (Codex on #146).
        guard isTestNamespace(folderName) else {
            return .failure(Refusal(message: "\(folderName) is not a test project name: guarded projects are named \(testNamespacePrefix)<something>"))
        }
        let projectJSON = resolved.appendingPathComponent("project.json")
        let hasProjectJSON = files.exists(projectJSON)
        if create {
            // The destination must not exist at all: not a project, not an empty folder, not a folder of anything.
            if hasProjectJSON {
                return .failure(Refusal(message: "\(resolved.path) already holds a project (project.json): --create refuses to touch it"))
            }
            if files.exists(resolved) {
                return .failure(Refusal(message: "\(resolved.path) already exists: --create makes a new folder only, never writes into one that is there"))
            }
            if !files.exists(resolvedRoot) {
                return .failure(Refusal(message: "--project-root \(resolvedRoot.path) does not exist: --create makes the project, not the root"))
            }
            // ProjectsModel.create names the project DatasetStore.safeName(folder name) and makes THAT folder: a basename
            // that normalisation would change could create or open a folder other than the validated one.
            if DatasetStore.safeName(folderName) != folderName {
                return .failure(Refusal(message: "\(folderName) would be normalised to \(DatasetStore.safeName(folderName)) on creation: name the folder that way"))
            }
        } else {
            if !hasProjectJSON {
                return .failure(Refusal(message: "\(resolved.path) has no project.json: not an existing project, and guarded mode creates none without --create"))
            }
            guard let declared = files.projectName(projectJSON) else {
                return .failure(Refusal(message: "\(projectJSON.path) does not decode a project name: refused"))
            }
            guard declared == folderName else {
                return .failure(Refusal(message: "\(projectJSON.path) names the project \"\(declared)\", not \"\(folderName)\": a copied or renamed project is refused (its server namespace would be \"\(declared)\")"))
            }
        }
        // Isolation: required, never defaulted.
        guard let suite = value(after: "--defaults-suite", in: arguments), !suite.isEmpty else {
            return .failure(Refusal(message: "guarded mode needs --defaults-suite \(testSuitePrefix)<name>: a run's preferences never go to the person's"))
        }
        guard suite.hasPrefix(testSuitePrefix) else {
            return .failure(Refusal(message: "--defaults-suite \(suite) is not a test suite (it must begin with \(testSuitePrefix))"))
        }
        guard let pending = value(after: "--pending-dir", in: arguments) else {
            return .failure(Refusal(message: "guarded mode needs --pending-dir <absolute dir under --project-root>: queued phone decisions never go to the person's folder"))
        }
        guard pending.hasPrefix("/") else {
            return .failure(Refusal(message: "--pending-dir must be an absolute path, not \(pending)"))
        }
        let pendingURL = URL(fileURLWithPath: pending, isDirectory: true)
        if files.isSymlink(pendingURL) {
            return .failure(Refusal(message: "--pending-dir \(pending) is a symbolic link: refused"))
        }
        let resolvedPending = files.resolve(pendingURL)
        guard isInside(resolvedPending, of: resolvedRoot) else {
            return .failure(Refusal(message: "--pending-dir \(pending) resolves to \(resolvedPending.path), outside --project-root \(resolvedRoot.path)"))
        }
        // Operations with values.
        if arguments.contains("--phone-sign-in"), value(after: "--phone-sign-in", in: arguments) == nil {
            return .failure(Refusal(message: "--phone-sign-in needs the account's email (the password comes from RALLYLAB_PASSWORD, never the command line)"))
        }
        // Inputs for creation: test-only files under the root.
        var extras: [URL] = []
        if let i = arguments.firstIndex(of: "--add-extras") {
            guard arguments.indices.contains(i + 1), extraEnvironments.contains(arguments[i + 1]) else {
                return .failure(Refusal(message: "--add-extras needs <Indoor|Beach|Grass> <absolute files…>"))
            }
            let paths = arguments[(i + 2)...].prefix { !$0.hasPrefix("--") }
            guard !paths.isEmpty else {
                return .failure(Refusal(message: "--add-extras names no files"))
            }
            for path in paths {
                guard path.hasPrefix("/") else { return .failure(Refusal(message: "--add-extras file \(path) is not an absolute path")) }
                let url = URL(fileURLWithPath: path)
                guard videoExtensions.contains(url.pathExtension.lowercased()) else { return .failure(Refusal(message: "--add-extras file \(path) is not a .mov/.mp4/.m4v")) }
                if files.isSymlink(url) { return .failure(Refusal(message: "--add-extras file \(path) is a symbolic link: refused")) }
                let file = files.resolve(url)
                guard isInside(file, of: resolvedRoot) else { return .failure(Refusal(message: "--add-extras file \(path) resolves to \(file.path), outside --project-root: only test-only inputs under the root")) }
                guard files.exists(file), files.isRegularFile(file) else { return .failure(Refusal(message: "--add-extras file \(path) is not an existing regular file")) }
                extras.append(file)
            }
        }
        return .success(Guarded(root: resolvedRoot, project: resolved, defaultsSuite: suite, pendingDirectory: resolvedPending, create: create, extras: extras))
    }

    /// The validated guarded run, nil for an unguarded run.
    static func guardedRun(for arguments: [String], home: URL, files: Files = .real) -> Guarded? {
        guard arguments.contains("--project-root") else { return nil }
        return try? guarded(arguments: arguments, home: home, files: files).get()
    }

    /// The same folder, symlinks followed on both sides.
    static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        canonical(a).path == canonical(b).path
    }

    /// The canonical form of a path that may not exist yet: its longest existing ancestor through realpath(3), then the
    /// remaining components as given. Foundation's `resolvingSymlinksInPath` drops the `/private` prefix of an existing
    /// `/private/tmp/…` but leaves an absent `/private/tmp/…/new` as it is, so a root and a destination under it could
    /// come out on different spellings and fail containment (seen on 2026-11-04, the first guarded --create).
    static func canonical(_ url: URL) -> URL {
        // The longest existing prefix is taken with its `.` and `..` components as given, so realpath(3) resolves a
        // symlink BEFORE a `..` that follows it (`root/link/..` is the link target's parent, not `root`; Codex on #147).
        // Only the absent remainder is normalised by hand — nothing in it can be a symlink.
        let raw = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var existingCount = raw.count
        while existingCount > 0, !FileManager.default.fileExists(atPath: "/" + raw.prefix(existingCount).joined(separator: "/")) {
            existingCount -= 1
        }
        let existingPath = "/" + raw.prefix(existingCount).joined(separator: "/")
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base = realpath(existingPath, &buffer).map { String(cString: $0) } ?? existingPath
        var components = base.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in raw.dropFirst(existingCount) {
            switch part {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(part)
            }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }

    // Paths here are already canonical (Files.resolve): compared as given — Foundation's standardising calls would
    // strip `/private` from the one that exists and not from the one that doesn't.
    private static func isSame(_ a: URL, as b: URL) -> Bool { a.path == b.path }

    private static func isInside(_ dir: URL, of root: URL) -> Bool {
        let d = dir.pathComponents, r = root.pathComponents
        return d.count > r.count && Array(d.prefix(r.count)) == r
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1), !args[idx + 1].hasPrefix("--") else { return nil }
        return args[idx + 1]
    }
}
