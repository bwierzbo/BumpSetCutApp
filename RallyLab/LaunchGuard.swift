//
//  LaunchGuard.swift
//  RallyLab
//
//  What a RallyLab launch is allowed to do before any project is opened. Two rules, both decided from the
//  command line alone, before a ProjectsModel exists (a ProjectsModel restores the last project — the person's —
//  the moment it is made):
//
//  1. A launch with any `--flag` is a headless run. If none of the headless commands is present, the launch is
//     refused: it must never fall through to the window app and reopen the last project (on 2026-11-04
//     `RallyLab --status` without `--project` did exactly that, for 27 minutes, on the owner's project).
//  2. `--project-root <absolute dir>` is guarded mode, for tests and automation: `--project` must be an absolute
//     path to an EXISTING project (project.json present) that resolves, symlinks followed, to a folder under the
//     resolved root; the path itself may not be a symlink; the default project location (~/Movies/RallyLab/Projects)
//     and any folder named Scratch are refused wherever they are. Nothing is created in guarded mode.
//     `--defaults-suite <name>` keeps the run's preferences (remembered and last project) out of the person's, and
//     `--pending-dir <dir>` keeps its queued phone decisions out of ~/Library/Application Support/RallyLab.
//

import Foundation

enum LaunchGuard {
    struct Refusal: Error, Equatable {
        let message: String
    }

    /// The flags that start a headless run; any other `--flag` alone is a refusal.
    static let headlessCommands: Set<String> = ["--project", "--sample", "--export-training-data"]

    /// A headless command that will actually start a run: `--project` must carry its value (HeadlessProjects returns
    /// false without one, which would fall through to the window app); `--sample` exits on its own without inputs;
    /// `--export-training-data` takes an optional path.
    static func hasHeadlessCommand(_ arguments: [String]) -> Bool {
        value(after: "--project", in: arguments) != nil || arguments.contains("--sample") || arguments.contains("--export-training-data")
    }

    /// The file checks the rules need, injectable for tests.
    struct Files {
        var exists: (URL) -> Bool
        var isSymlink: (URL) -> Bool
        var resolve: (URL) -> URL

        static let real = Files(
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            isSymlink: { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil },
            resolve: { $0.resolvingSymlinksInPath().standardizedFileURL })
    }

    /// Why this launch must not go on, or nil when it may.
    static func refusal(for arguments: [String], home: URL, files: Files = .real) -> Refusal? {
        let args = Array(arguments.dropFirst())
        let flags = args.filter { $0.hasPrefix("--") }
        if !flags.isEmpty, !hasHeadlessCommand(arguments) {
            return Refusal(message: "no complete headless command among \(flags.joined(separator: " ")): a launch with flags never opens the window app (it would reopen the last project). Headless runs start with --project <name or path>, --sample <inputs…> or --export-training-data.")
        }
        if args.contains("--project-root") {
            if case .failure(let refusal) = guardedProject(arguments: arguments, home: home, files: files) { return refusal }
        }
        return nil
    }

    /// Guarded mode: the existing project `--project` names, validated against `--project-root`.
    static func guardedProject(arguments: [String], home: URL, files: Files = .real) -> Result<URL, Refusal> {
        guard let root = value(after: "--project-root", in: arguments) else {
            return .failure(Refusal(message: "--project-root needs a directory"))
        }
        guard root.hasPrefix("/") else {
            return .failure(Refusal(message: "--project-root must be an absolute path, not \(root)"))
        }
        guard let project = value(after: "--project", in: arguments) else {
            return .failure(Refusal(message: "--project-root needs --project <absolute path of an existing project>"))
        }
        guard project.hasPrefix("/") else {
            return .failure(Refusal(message: "with --project-root, --project must be an absolute path, not \(project)"))
        }
        let given = URL(fileURLWithPath: project, isDirectory: true)
        if files.isSymlink(given) {
            return .failure(Refusal(message: "\(project) is a symbolic link: give the project's real folder"))
        }
        let resolvedRoot = files.resolve(URL(fileURLWithPath: root, isDirectory: true))
        let resolved = files.resolve(given)
        let defaultLocation = files.resolve(home.appendingPathComponent("Movies/RallyLab/Projects", isDirectory: true))
        for dir in [resolvedRoot, resolved] where isSame(dir, as: defaultLocation) || isInside(dir, of: defaultLocation) {
            return .failure(Refusal(message: "\(dir.path) is in the default project location \(defaultLocation.path): never a test root or test project"))
        }
        if resolved.pathComponents.contains("Scratch") || resolvedRoot.pathComponents.contains("Scratch") {
            return .failure(Refusal(message: "\(resolved.path) is or is under a folder named Scratch: refused in guarded mode"))
        }
        guard isInside(resolved, of: resolvedRoot) else {
            return .failure(Refusal(message: "\(project) resolves to \(resolved.path), outside --project-root \(resolvedRoot.path)"))
        }
        guard files.exists(resolved.appendingPathComponent("project.json")) else {
            return .failure(Refusal(message: "\(resolved.path) has no project.json: not an existing project, and guarded mode creates none"))
        }
        return .success(resolved)
    }

    /// The validated project folder of a guarded run, nil for an unguarded run (or a guarded one the guard already
    /// refused — the launch never gets here then).
    static func guardedRoot(for arguments: [String], home: URL, files: Files = .real) -> URL? {
        guard arguments.contains("--project-root") else { return nil }
        return try? guardedProject(arguments: arguments, home: home, files: files).get()
    }

    /// `--defaults-suite <name>`: a preferences domain of the run's own, else the person's.
    static func defaults(for arguments: [String]) -> UserDefaults {
        guard let suite = value(after: "--defaults-suite", in: arguments), let defaults = UserDefaults(suiteName: suite) else { return .standard }
        return defaults
    }

    /// `--pending-dir <dir>`: where the run keeps queued phone decisions, else the usual Application Support folder.
    static func pendingDirectory(for arguments: [String]) -> URL {
        guard let dir = value(after: "--pending-dir", in: arguments) else { return Pending.defaultDirectory }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func isSame(_ a: URL, as b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }

    /// The same folder, symlinks followed on both sides.
    static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isInside(_ dir: URL, of root: URL) -> Bool {
        let d = dir.standardizedFileURL.pathComponents, r = root.standardizedFileURL.pathComponents
        return d.count > r.count && Array(d.prefix(r.count)) == r
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1), !args[idx + 1].hasPrefix("--") else { return nil }
        return args[idx + 1]
    }
}
