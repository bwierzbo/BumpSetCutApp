//
//  ProjectsModel.swift
//  RallyLab
//
//  A project is one training set built from the standard clip plan
//  (StandardClipPlan). Give each clip its footage — a video link or a file you have
//  — with a start time; the clip is cut (5 minutes by default) by
//  scripts/fetch_clip.py, logged with its licence, and sampled straight into
//  the project's dataset under the row's Clip ID. The Sampler tab reviews
//  it like any other video.
//
//  On disk, one folder per project, wherever you create it — see
//  ProjectLayout for what's inside.
//

import Foundation
import Observation

struct PlannedClip: Codable, Identifiable, Equatable, Hashable {
    /// The Clip ID from the sheet; also the dataset session's name.
    let id: String
    var number: Int
    var environment: String
    var camera: String
    var lighting: String
    var orientation: String
    var ball: String
    var notes: String
    /// "train" or "val"; nil lets the dataset decide when the clip is added.
    var split: String?
    var source: ClipSource?
}

struct ClipSource: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case link, file }
    var kind: Kind
    /// The link, or the original file's path.
    var origin: String
    var start: Double
    var length: Double
    var license: String
    var title: String
    var uploader: String
    /// The cut clip inside the project's footage folder.
    var clipFile: String
    var fetchedAt: Date
}

struct Project: Codable, Equatable {
    var name: String
    var createdAt: Date
    /// Labeled frames wanted per clip (the checklist asks for about 55).
    var targetFrames: Int
    var clips: [PlannedClip]
}

enum ClipProgress: Equatable {
    case notStarted
    case cutting(Double?)       // nil = indeterminate
    case sampling(String)
    case failed(String)
    case pulled(frames: Int, reviewed: Int)
}

@MainActor
@Observable
final class ProjectsModel {

    /// Where the New Project sheet suggests creating a project.
    static let defaultLocation = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RallyLab/Projects", isDirectory: true)
    private static let knownProjectsKey = "RallyLab.projects"
    private static let lastProjectKey = "RallyLab.lastProjectPath"

    /// Every project folder RallyLab knows about, wherever it lives.
    private(set) var knownProjects: [URL] = []
    private(set) var project: Project?
    private(set) var projectDir: URL?
    private(set) var status = "Create a project to start a training set."

    var selectedClipId: String?

    // Per-clip transient state for the running cut.
    private(set) var cutting: [String: Double?] = [:]
    private(set) var failures: [String: String] = [:]

    let sampler: SamplerModel

    init(sampler: SamplerModel) {
        self.sampler = sampler
        loadKnownProjects()
        if let last = UserDefaults.standard.string(forKey: Self.lastProjectKey) {
            let dir = URL(fileURLWithPath: last, isDirectory: true)
            if knownProjects.contains(dir) { open(dir) }
        }
    }

    func note(_ message: String) {
        status = message
    }

    var selectedClip: PlannedClip? {
        project?.clips.first { $0.id == selectedClipId }
    }

    // MARK: - Projects

    private static func isProject(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.json").path)
    }

    /// The remembered list, plus anything in the default location, minus
    /// folders that have since been moved or deleted.
    private func loadKnownProjects() {
        let saved = (UserDefaults.standard.stringArray(forKey: Self.knownProjectsKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let inDefault = (try? FileManager.default.contentsOfDirectory(
            at: Self.defaultLocation, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        knownProjects = (saved + inDefault)
            .map(\.standardizedFileURL)
            .filter { Self.isProject($0) && seen.insert($0.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        storeKnownProjects()
    }

    private func storeKnownProjects() {
        UserDefaults.standard.set(knownProjects.map(\.path), forKey: Self.knownProjectsKey)
    }

    private func remember(_ dir: URL) {
        let dir = dir.standardizedFileURL
        guard !knownProjects.contains(dir) else { return }
        knownProjects.append(dir)
        knownProjects.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        storeKnownProjects()
    }

    /// Take a project off the list. Its folder is left untouched.
    func forget(_ dir: URL) {
        knownProjects.removeAll { $0 == dir.standardizedFileURL }
        storeKnownProjects()
        if projectDir == dir.standardizedFileURL {
            project = nil
            projectDir = nil
            UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
        }
    }

    /// The folder a new project called `name` would get inside `location`.
    static func folder(for name: String, in location: URL) -> URL {
        location.appendingPathComponent(DatasetStore.safeName(name.trimmingCharacters(in: .whitespacesAndNewlines)),
                                        isDirectory: true)
    }

    /// Make `<location>/<name>/` with its whole layout up front, seeded with
    /// the standard clip plan. An existing project there is opened instead.
    func create(name: String, in location: URL) {
        let clean = DatasetStore.safeName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty else { return }
        let dir = Self.folder(for: clean, in: location)
        if Self.isProject(dir) { open(dir); return }
        do {
            try ProjectLayout.create(at: dir)
        } catch {
            status = "Couldn't create \(dir.path): \(error.localizedDescription)"
            return
        }
        project = Project(name: clean, createdAt: Date(), targetFrames: StandardClipPlan.targetFrames,
                          clips: StandardClipPlan.clips)
        projectDir = dir.standardizedFileURL
        save()
        remember(dir)
        activate()
        status = "Created \(clean) at \(dir.path) with the \(StandardClipPlan.clips.count)-clip plan."
    }

    /// Open a project folder (one with a project.json).
    func open(_ dir: URL) {
        let url = dir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url) else {
            status = "\(dir.lastPathComponent) isn't a RallyLab project (no project.json)."
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode(Project.self, from: data) else {
            status = "\(dir.lastPathComponent)/project.json is unreadable."
            return
        }
        project = loaded
        projectDir = dir.standardizedFileURL
        try? ProjectLayout.create(at: dir)
        addNewPlanClips()
        selectedClipId = nil
        cutting = [:]
        failures = [:]
        remember(dir)
        activate()
        status = "\(loaded.name): \(loaded.clips.count) planned clips."
    }

    /// Point the Sampler at this project's dataset.
    private func activate() {
        guard let dir = projectDir else { return }
        sampler.setDatasetRoot(dir)
        UserDefaults.standard.set(dir.path, forKey: Self.lastProjectKey)
    }

    private func save() {
        guard let project, let dir = projectDir else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        } catch {
            status = "Couldn't save the project: \(error.localizedDescription)"
        }
    }

    func setTargetFrames(_ n: Int) {
        guard project != nil else { return }
        project?.targetFrames = max(0, n)
        save()
    }

    // MARK: - Plan

    /// Clips added to the standard plan after this project was created join
    /// it on open; existing clips and their footage are left alone.
    private func addNewPlanClips() {
        guard let existing = project?.clips.map(\.id) else { return }
        let known = Set(existing)
        let missing = StandardClipPlan.clips.filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return }
        project?.clips = ((project?.clips ?? []) + missing).sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        save()
    }

    func setSplit(_ split: String?, for clipId: String) {
        guard let i = project?.clips.firstIndex(where: { $0.id == clipId }) else { return }
        project?.clips[i].split = split
        save()
    }

    // MARK: - Progress

    func session(for clip: PlannedClip) -> VideoSession? {
        sampler.sessions.first { $0.name == DatasetStore.safeName(clip.id) }
    }

    func progress(of clip: PlannedClip) -> ClipProgress {
        if let value = cutting[clip.id] { return .cutting(value) }
        if let job = sampler.queue.last(where: { $0.sessionName == DatasetStore.safeName(clip.id) }) {
            switch job.state {
            case .pending: return .sampling("Waiting to sample…")
            case .running(let text): return .sampling(text)
            case .failed(let why): return .failed(why)
            case .done: break
            }
        }
        if let why = failures[clip.id] { return .failed(why) }
        if let session = session(for: clip) {
            return .pulled(frames: session.frames.count, reviewed: session.reviewedCount)
        }
        return .notStarted
    }

    struct Tally { var total = 0, recorded = 0, pulled = 0, labeled = 0 }

    /// The same four numbers as the checklist's Progress block, per environment.
    func tallies() -> [(String, Tally)] {
        guard let project else { return [] }
        var byEnv: [String: Tally] = [:]
        var all = Tally()
        for clip in project.clips {
            let env = clip.environment.isEmpty ? "Other" : clip.environment
            var t = byEnv[env, default: Tally()]
            t.total += 1; all.total += 1
            if clip.source != nil { t.recorded += 1; all.recorded += 1 }
            if let s = session(for: clip) {
                t.pulled += 1; all.pulled += 1
                if !s.frames.isEmpty, s.reviewedCount == s.frames.count { t.labeled += 1; all.labeled += 1 }
            }
            byEnv[env] = t
        }
        return byEnv.sorted { $0.key < $1.key } + [("All", all)]
    }

    // MARK: - Getting footage

    /// Cut `length` seconds from `start` out of a link or a local file, log
    /// it, then sample it into the dataset under the clip's ID. Replaces any
    /// footage and frames the clip already had.
    func getFootage(for clipId: String, source: String, start: Double, length: Double, license: String) {
        guard let project, let dir = projectDir,
              let clip = project.clips.first(where: { $0.id == clipId }) else { return }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = license.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "Paste a link or choose a file first."; return }
        guard !note.isEmpty else { status = "Add the licence or permission this clip is used under."; return }
        guard cutting[clipId] == nil else { return }
        guard let script = Self.fetchScript else {
            status = "scripts/fetch_clip.py wasn't found next to the RallyLab sources."
            return
        }

        let isFile = FileManager.default.fileExists(atPath: (trimmed as NSString).expandingTildeInPath)
        var args = [script.path, trimmed,
                    "--id", clip.id, "--license", note,
                    "--start", String(start), "--length", String(length),
                    "--root", dir.appendingPathComponent("footage").path,
                    "--force", "--result-json"]
        if let env = Self.envFlag(clip) { args += ["--env", env] }

        failures[clipId] = nil
        // updateValue, not subscript: assigning nil through the subscript
        // would delete the entry, and a file cut has no percentage to show.
        cutting.updateValue(isFile ? nil : 0, forKey: clipId)
        status = "\(clip.id): \(isFile ? "cutting the file" : "downloading the section")…"

        Task {
            let outcome = await Self.runFetch(args: args) { [weak self] fraction in
                Task { @MainActor in
                    if self?.cutting[clipId] != nil { self?.cutting.updateValue(fraction, forKey: clipId) }
                }
            }
            cutting.removeValue(forKey: clipId)
            switch outcome {
            case .failure(let failure):
                failures[clipId] = failure.message
                status = "\(clip.id): \(failure.message)"
            case .success(let result):
                recordSource(clipId: clipId, result: result, kind: isFile ? .file : .link,
                             origin: trimmed, license: note, length: length)
                let session = DatasetStore.safeName(clip.id)
                if let old = sampler.sessions.first(where: { $0.name == session }) {
                    sampler.deleteSession(old)
                }
                sampler.enqueueClip(URL(fileURLWithPath: result.file), sessionName: session,
                                    split: clip.split, targetFrames: self.project?.targetFrames)
                status = "\(clip.id): cut \(Int(result.duration.rounded()))s, sampling…"
            }
        }
    }

    private func recordSource(clipId: String, result: FetchResult, kind: ClipSource.Kind,
                              origin: String, license: String, length: Double) {
        guard let i = project?.clips.firstIndex(where: { $0.id == clipId }) else { return }
        project?.clips[i].source = ClipSource(
            kind: kind, origin: kind == .link ? result.url : origin,
            start: result.start, length: result.duration, license: license,
            title: result.title, uploader: result.uploader,
            clipFile: result.file, fetchedAt: Date()
        )
        save()
    }

    /// The checklist's Env column as fetch_clip's --env, when it's one of
    /// the three (negatives are routed by their ID).
    private static func envFlag(_ clip: PlannedClip) -> String? {
        let env = clip.environment.lowercased()
        return ["indoor", "beach", "grass"].contains(env) ? env : nil
    }

    // MARK: - Running fetch_clip.py

    struct FetchResult: Decodable {
        let file: String
        let duration: Double
        let start: Double
        let title: String
        let uploader: String
        let url: String
    }

    /// The script ships in the repo RallyLab is built from.
    static var fetchScript: URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fetch_clip.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A GUI app starts with a bare PATH; python3, yt-dlp and ffmpeg live in
    /// the usual install locations.
    private nonisolated static var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin",
                     "/Library/Frameworks/Python.framework/Versions/Current/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return env
    }

    private nonisolated static func runFetch(
        args: [String], progress: @escaping @Sendable (Double) -> Void
    ) async -> Result<FetchResult, FetchFailure> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + args
            process.environment = toolEnvironment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out

            let lines = LineCollector()
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in lines.append(data) {
                    // yt-dlp --newline: "[download]  42.1% of ..."
                    if line.hasPrefix("[download]"),
                       let pct = line.split(separator: " ").first(where: { $0.hasSuffix("%") }),
                       let value = Double(pct.dropLast()) {
                        progress(value / 100)
                    }
                }
            }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                _ = lines.append(rest)
                let all = lines.all
                if proc.terminationStatus == 0,
                   let line = all.last(where: { $0.hasPrefix("RESULT ") }),
                   let data = line.dropFirst(7).data(using: .utf8),
                   let result = try? JSONDecoder().decode(FetchResult.self, from: data) {
                    continuation.resume(returning: .success(result))
                } else {
                    let why = all.last(where: { $0.hasPrefix("❌") }).map { String($0.dropFirst(2)) }
                        ?? all.last(where: { $0.lowercased().contains("error") })
                        ?? "fetch_clip.py exited with status \(proc.terminationStatus)"
                    continuation.resume(returning: .failure(FetchFailure(message: why)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(FetchFailure(message: error.localizedDescription)))
            }
        }
    }

    struct FetchFailure: Error, Equatable { let message: String }
}

/// Splits a byte stream into lines across reads, keeping every line for the
/// final result/error scan. yt-dlp redraws progress with \r, so both
/// separators end a line.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private(set) var all: [String] = []

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        var complete: [String] = []
        while let range = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r")) {
            let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(..<range.upperBound)
            if !line.isEmpty { complete.append(line); all.append(line) }
        }
        return complete
    }
}

/// The folders a project is made of, created when the project is so the
/// structure is there to look at before any footage arrives:
///
///   project.json                    the plan + each clip's source
///   footage/raw/self/<env>/          clips you recorded
///   footage/raw/online/<env>/        clips from links
///   footage/raw/negatives/           hard-negative clips
///   footage/meta/sources.csv         where every clip came from, and its licence
///   images/{train,val}/              frames that train / validate the model
///   labels/{train,val}/              one YOLO label file per image
///   sessions/                        each clip's frames and review state
///   excluded/                        unreviewed or discarded frames, parked
///   runs/                            training output
///   data.yaml                        what `yolo train` reads
enum ProjectLayout {
    static let folders: [String] = {
        let envs = ["indoor", "beach", "grass"]
        return envs.map { "footage/raw/self/\($0)" }
            + envs.map { "footage/raw/online/\($0)" }
            + ["footage/raw/negatives", "footage/meta",
               "images/train", "images/val", "labels/train", "labels/val",
               "sessions", "excluded", "runs"]
    }()

    static func create(at dir: URL) throws {
        let fm = FileManager.default
        for folder in folders {
            try fm.createDirectory(at: dir.appendingPathComponent(folder, isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        try DatasetStore(root: dir).writeDataYAML()
    }
}
