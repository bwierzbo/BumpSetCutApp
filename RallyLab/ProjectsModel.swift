//
//  ProjectsModel.swift
//  RallyLab
//
//  A project is one training set built from a clip checklist. Import the
//  sheet, then give each row its footage — a video link or a file you have
//  — with a start time; the clip is cut (5 minutes by default) by
//  scripts/fetch_clip.py, logged with its licence, and sampled straight into
//  the project's dataset under the row's Clip ID. The Sampler tab reviews
//  it like any other video.
//
//  On disk, one folder per project:
//    ~/Movies/RallyLab/Projects/<name>/project.json   the plan + each clip's source
//    ~/Movies/RallyLab/Projects/<name>/footage/        cut clips + meta/sources.csv
//    ~/Movies/RallyLab/Projects/<name>/images|labels|sessions|data.yaml
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
    var checklistFile: String?
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

    static let projectsRoot = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RallyLab/Projects", isDirectory: true)
    private static let lastProjectKey = "RallyLab.lastProject"

    private(set) var projectNames: [String] = []
    private(set) var project: Project?
    private(set) var status = "Create a project, then import your clip checklist."

    var selectedClipId: String?

    // Per-clip transient state for the running cut.
    private(set) var cutting: [String: Double?] = [:]
    private(set) var failures: [String: String] = [:]

    let sampler: SamplerModel

    init(sampler: SamplerModel) {
        self.sampler = sampler
        reloadProjectList()
        if let last = UserDefaults.standard.string(forKey: Self.lastProjectKey), projectNames.contains(last) {
            open(last)
        }
    }

    var projectDir: URL? {
        project.map { Self.projectsRoot.appendingPathComponent(DatasetStore.safeName($0.name), isDirectory: true) }
    }

    var selectedClip: PlannedClip? {
        project?.clips.first { $0.id == selectedClipId }
    }

    // MARK: - Projects

    func reloadProjectList() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Self.projectsRoot, includingPropertiesForKeys: nil)) ?? []
        projectNames = dirs
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    func create(name: String) {
        let clean = DatasetStore.safeName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty else { return }
        guard !projectNames.contains(clean) else { open(clean); return }
        project = Project(name: clean, createdAt: Date(), checklistFile: nil, targetFrames: 55, clips: [])
        save()
        reloadProjectList()
        activate()
        status = "Created \(clean). Import your clip checklist next."
    }

    func open(_ name: String) {
        let url = Self.projectsRoot.appendingPathComponent(name).appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url) else { status = "Couldn't open \(name)."; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode(Project.self, from: data) else { status = "\(name)/project.json is unreadable."; return }
        project = loaded
        selectedClipId = nil
        cutting = [:]
        failures = [:]
        activate()
        status = "\(loaded.name): \(loaded.clips.count) planned clips."
    }

    /// Point the Sampler at this project's dataset.
    private func activate() {
        guard let dir = projectDir, let project else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sampler.setDatasetRoot(dir)
        UserDefaults.standard.set(DatasetStore.safeName(project.name), forKey: Self.lastProjectKey)
    }

    private func save() {
        guard let project, let dir = projectDir else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    // MARK: - Checklist

    /// Merge a checklist into the project: new Clip IDs are added, existing
    /// ones keep their footage and split but take the sheet's descriptions.
    func importChecklist(_ url: URL) {
        guard project != nil else { status = "Create or open a project first."; return }
        do {
            let incoming = try ChecklistImporter.clips(from: url)
            guard !incoming.isEmpty else { status = "No clips found in \(url.lastPathComponent)."; return }
            var byId = Dictionary(uniqueKeysWithValues: (project?.clips ?? []).map { ($0.id, $0) })
            var added = 0
            for var clip in incoming {
                if let existing = byId[clip.id] {
                    clip.split = existing.split
                    clip.source = existing.source
                } else {
                    added += 1
                }
                byId[clip.id] = clip
            }
            project?.clips = byId.values.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
            project?.checklistFile = url.path
            save()
            status = "Imported \(incoming.count) clips from \(url.lastPathComponent) (\(added) new)."
        } catch {
            status = error.localizedDescription
        }
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
