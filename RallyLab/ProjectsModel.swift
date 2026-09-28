//
//  ProjectsModel.swift
//  RallyLab
//
//  A project is one training set built from the standard clip plan
//  (StandardClipPlan). Give each clip as many videos as you like — links or
//  files you have — each cut (5 minutes by default) by scripts/fetch_clip.py,
//  logged with its licence, and sampled into the project's dataset as its
//  own session with its own frame count. The Sampler tab reviews them like
//  any other video.
//
//  On disk, one folder per project, wherever you create it — see
//  ProjectLayout for what's inside.
//

import AVFoundation
import CryptoKit
import Foundation
import Observation

struct PlannedClip: Identifiable, Equatable, Hashable {
    /// The Clip ID from the sheet; also the dataset session's name.
    let id: String
    var number: Int
    var environment: String
    var camera: String
    var lighting: String
    var orientation: String
    var ball: String
    var notes: String
    /// "train" or "val"; nil lets the dataset decide as each video is added.
    var split: String?
    /// The clip's videos, oldest first; each is its own dataset session.
    var videos: [ClipSource] = []

    /// A video's ID: its dataset session and its cut file's name.
    func videoId(of video: ClipSource) -> String { video.videoId ?? id }
}

extension PlannedClip: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, number, environment, camera, lighting, orientation, ball, notes, split, videos
        /// Projects saved when a clip held one video.
        case source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        environment = try c.decode(String.self, forKey: .environment)
        camera = try c.decode(String.self, forKey: .camera)
        lighting = try c.decode(String.self, forKey: .lighting)
        orientation = try c.decode(String.self, forKey: .orientation)
        ball = try c.decode(String.self, forKey: .ball)
        notes = try c.decode(String.self, forKey: .notes)
        split = try c.decodeIfPresent(String.self, forKey: .split)
        videos = try c.decodeIfPresent([ClipSource].self, forKey: .videos)
            ?? c.decodeIfPresent(ClipSource.self, forKey: .source).map { [$0] } ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(number, forKey: .number)
        try c.encode(environment, forKey: .environment)
        try c.encode(camera, forKey: .camera)
        try c.encode(lighting, forKey: .lighting)
        try c.encode(orientation, forKey: .orientation)
        try c.encode(ball, forKey: .ball)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(split, forKey: .split)
        try c.encode(videos, forKey: .videos)
    }
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
    /// See PlannedClip.videoId(of:); nil is the clip's own ID (its first
    /// video, and every video from before clips held several).
    var videoId: String?
    /// Frames wanted from this video; nil = the project's default.
    var frames: Int?
    /// Identifies the original video (see ProjectsModel.fingerprint), so a
    /// video reused on any card is recognised. nil for older videos; it's
    /// worked out from `origin` instead.
    var fingerprint: String?
}

struct Project: Codable, Equatable {
    var name: String
    var createdAt: Date
    /// Frames wanted per video unless the video sets its own.
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
    private static let openedKey = "RallyLab.projectOpenedAt"

    /// Drives the New Project sheet from the welcome window, the project
    /// menu and File ▸ New Project.
    var isCreatingProject = false

    /// Every project folder RallyLab knows about, wherever it lives.
    private(set) var knownProjects: [URL] = []
    private(set) var project: Project?
    private(set) var projectDir: URL?
    private(set) var status = "Create a project to start a training set."

    var selectedClipId: String?
    /// A video dropped on an online clip's card, for its detail pane to
    /// pick up (it needs a licence before it's cut).
    var droppedFootage: FootageDrop?

    /// Videos being cut, or whose cut failed, before they join their clip.
    private(set) var jobs: [VideoJob] = []

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

    /// Known projects, most recently opened first — the welcome window's list.
    var recentProjects: [URL] {
        let opened = UserDefaults.standard.dictionary(forKey: Self.openedKey) as? [String: Double] ?? [:]
        return knownProjects.sorted { (opened[$0.path] ?? 0) > (opened[$1.path] ?? 0) }
    }

    func lastOpened(_ dir: URL) -> Date? {
        let opened = UserDefaults.standard.dictionary(forKey: Self.openedKey) as? [String: Double] ?? [:]
        return opened[dir.standardizedFileURL.path].map(Date.init(timeIntervalSince1970:))
    }

    private func markOpened(_ dir: URL) {
        var opened = UserDefaults.standard.dictionary(forKey: Self.openedKey) as? [String: Double] ?? [:]
        opened[dir.standardizedFileURL.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(opened, forKey: Self.openedKey)
    }

    /// Back to the welcome window. The project stays on the list, and
    /// isn't reopened on the next launch.
    func close() {
        project = nil
        projectDir = nil
        selectedClipId = nil
        UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
        status = "Create a project to start a training set."
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
        jobs = []
        remember(dir)
        activate()
        status = "\(loaded.name): \(loaded.clips.count) planned clips."
    }

    /// Point the Sampler at this project's dataset.
    private func activate() {
        guard let dir = projectDir else { return }
        sampler.setDatasetRoot(dir)
        UserDefaults.standard.set(dir.path, forKey: Self.lastProjectKey)
        markOpened(dir)
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

    func session(named videoId: String) -> VideoSession? {
        sampler.sessions.first { $0.name == DatasetStore.safeName(videoId) }
    }

    func sessions(for clip: PlannedClip) -> [VideoSession] {
        clip.videos.compactMap { session(named: clip.videoId(of: $0)) }
    }

    /// Recorded videos, then ones still being cut.
    private func videoIds(of clip: PlannedClip) -> [String] {
        clip.videos.map(clip.videoId(of:)) + jobs.filter { $0.clipId == clip.id }.map(\.id)
    }

    func progress(ofVideo videoId: String) -> ClipProgress {
        if let job = jobs.first(where: { $0.id == videoId }) {
            return job.failure.map { .failed($0) } ?? .cutting(job.fraction)
        }
        if let job = sampler.queue.last(where: { $0.sessionName == DatasetStore.safeName(videoId) }) {
            switch job.state {
            case .pending: return .sampling("Waiting to sample…")
            case .running(let text): return .sampling(text)
            case .failed(let why): return .failed(why)
            case .done: break
            }
        }
        if let session = session(named: videoId) {
            return .pulled(frames: session.frames.count, reviewed: session.reviewedCount)
        }
        return .notStarted
    }

    /// The clip's videos taken together: busy while any is, failed while
    /// any failure is unresolved, otherwise their frames summed.
    func progress(of clip: PlannedClip) -> ClipProgress {
        var cutting: [Double?] = []
        var sampling: String?
        var failure: String?
        var pulled: (frames: Int, reviewed: Int)?
        for progress in videoIds(of: clip).map(progress(ofVideo:)) {
            switch progress {
            case .cutting(let fraction): cutting.append(fraction)
            case .sampling(let text): sampling = sampling ?? text
            case .failed(let why): failure = failure ?? why
            case .pulled(let frames, let reviewed):
                pulled = ((pulled?.frames ?? 0) + frames, (pulled?.reviewed ?? 0) + reviewed)
            case .notStarted: break
            }
        }
        if !cutting.isEmpty {
            let known = cutting.compactMap { $0 }
            return .cutting(known.count == cutting.count ? known.reduce(0, +) / Double(known.count) : nil)
        }
        if let sampling { return .sampling(sampling) }
        if let failure { return .failed(failure) }
        if let pulled { return .pulled(frames: pulled.frames, reviewed: pulled.reviewed) }
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
            if !clip.videos.isEmpty { t.recorded += 1; all.recorded += 1 }
            let sessions = sessions(for: clip)
            if !sessions.isEmpty {
                t.pulled += 1; all.pulled += 1
                if sessions.allSatisfy({ !$0.frames.isEmpty && $0.reviewedCount == $0.frames.count }) {
                    t.labeled += 1; all.labeled += 1
                }
            }
            byEnv[env] = t
        }
        return byEnv.sorted { $0.key < $1.key } + [("All", all)]
    }

    // MARK: - Getting footage

    /// Videos dropped straight onto a clip's card. Your own recordings are
    /// each added right away (five minutes from the middle) unless that
    /// stretch is already used on any card; an online clip needs its licence
    /// first, so its video opens in the detail pane.
    func dropFootage(_ urls: [URL], on clipId: String) {
        guard let clip = project?.clips.first(where: { $0.id == clipId }) else { return }
        selectedClipId = clipId
        let videos = urls.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        guard let first = videos.first else {
            status = "Drop videos (.mov, .mp4 or .m4v)."
            return
        }
        if clip.kind == .online {
            droppedFootage = FootageDrop(clipId: clipId, path: first.path)
            status = "Add the licence or permission for \(first.lastPathComponent), then Add Video."
                + (videos.count > 1 ? " Online videos go in one at a time." : "")
        } else {
            for video in videos { cutMiddle(of: video, into: clipId) }
            status = "Adding \(videos.count) video\(videos.count == 1 ? "" : "s") to \(clipId)…"
        }
    }

    // MARK: - Extras

    /// Footage beyond the plan: any number of your own videos per
    /// environment, each its own clip (and dataset session), cut and
    /// sampled the same way as a planned clip.
    func addExtras(_ urls: [URL], environment: String) {
        guard let project else { return }
        let videos = urls.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { status = "Drop videos (.mov, .mp4 or .m4v)."; return }
        let prefix = Self.envPrefix[environment] ?? "ind"
        let stem = "\(prefix)_extra_self_"
        var next = project.clips.compactMap { clip in
            clip.id.hasPrefix(stem) ? Int(clip.id.dropFirst(stem.count)) : nil
        }.max() ?? 0
        var added: [(PlannedClip, URL)] = []
        for video in videos {
            next += 1
            let clip = PlannedClip(id: stem + String(format: "%02d", next), number: 1000 + next,
                                   environment: environment, camera: Self.extraCamera,
                                   lighting: "", orientation: "", ball: "",
                                   notes: video.deletingPathExtension().lastPathComponent)
            self.project?.clips.append(clip)
            added.append((clip, video))
        }
        save()
        for (clip, video) in added {
            cutMiddle(of: video, into: clip.id)
        }
        status = "Added \(added.count) extra \(environment.lowercased()) video\(added.count == 1 ? "" : "s")."
    }

    /// Remove an extra clip with its footage and frames. Planned clips stay.
    func removeExtra(_ clipId: String) {
        guard let clip = project?.clips.first(where: { $0.id == clipId }), clip.kind == .extra,
              !jobs.contains(where: { $0.clipId == clipId }) else { return }
        for video in clip.videos { deleteFootage(of: video, in: clip) }
        project?.clips.removeAll { $0.id == clipId }
        if selectedClipId == clipId { selectedClipId = nil }
        save()
        status = "Removed \(clipId)."
    }

    /// Cut `length` seconds from the middle of a local video — past the
    /// warm-ups at the start and pack-up at the end. Shorter videos are
    /// used whole.
    func cutMiddle(of video: URL, into clipId: String, length: Double = dropClipLength,
                   license: String = ownFootageLicense, frames: Int? = nil, allowDuplicate: Bool = false) {
        Task {
            let duration = (try? await AVURLAsset(url: video).load(.duration).seconds) ?? 0
            let start = duration.isFinite ? max(0, (duration - length) / 2) : 0
            addVideo(to: clipId, source: video.path, start: start.rounded(.down), length: length,
                     license: license, frames: frames, allowDuplicate: allowDuplicate)
        }
    }

    // MARK: - A clip's videos

    /// Change how many frames a video should give. Takes effect on Re-pull.
    func setFrames(_ frames: Int, forVideo videoId: String, in clipId: String) {
        guard let c = project?.clips.firstIndex(where: { $0.id == clipId }),
              let v = project?.clips[c].videos.firstIndex(where: { project?.clips[c].videoId(of: $0) == videoId })
        else { return }
        project?.clips[c].videos[v].frames = frames
        save()
    }

    /// Sample a video's cut again at its current frame count. Its frames,
    /// reviewed or not, are replaced; the footage isn't re-cut.
    func repull(_ videoId: String, in clipId: String) {
        guard let clip = project?.clips.first(where: { $0.id == clipId }),
              let video = clip.videos.first(where: { clip.videoId(of: $0) == videoId }) else { return }
        if let old = session(named: videoId) { sampler.deleteSession(old) }
        sampler.enqueueClip(URL(fileURLWithPath: video.clipFile), sessionName: DatasetStore.safeName(videoId),
                            split: clip.split, targetFrames: video.frames ?? project?.targetFrames)
        status = "\(videoId): re-pulling \(video.frames ?? project?.targetFrames ?? 0) frames…"
    }

    /// Remove one video from a clip, with its cut footage and frames.
    func removeVideo(_ videoId: String, from clipId: String) {
        guard let c = project?.clips.firstIndex(where: { $0.id == clipId }), let clip = project?.clips[c],
              let video = clip.videos.first(where: { clip.videoId(of: $0) == videoId }) else { return }
        deleteFootage(of: video, in: clip)
        project?.clips[c].videos.removeAll { clip.videoId(of: $0) == videoId }
        save()
        status = "Removed \(videoId)."
    }

    /// Videos on their way to another card.
    private(set) var moving: Set<String> = []

    /// Put a video on a different card. Its existing cut is copied across
    /// (nothing is downloaded again) and sampled there at the same frame
    /// count; it leaves this card only once that worked. Frames already
    /// reviewed are re-pulled, so they need reviewing again.
    func moveVideo(_ videoId: String, from clipId: String, to targetId: String) {
        guard targetId != clipId, !moving.contains(videoId),
              let clip = project?.clips.first(where: { $0.id == clipId }),
              let video = clip.videos.first(where: { clip.videoId(of: $0) == videoId }),
              project?.clips.contains(where: { $0.id == targetId }) == true else { return }
        moving.insert(videoId)
        let started = addVideo(to: targetId, source: video.clipFile, start: 0, length: video.length + 1,
                               license: video.license, frames: video.frames, allowDuplicate: true,
                               provenance: video) { [weak self] worked in
            guard let self else { return }
            self.moving.remove(videoId)
            if worked {
                self.removeVideo(videoId, from: clipId)
                self.status = "Moved \(videoId) to \(targetId)."
            }
        }
        if started == nil { moving.remove(videoId) }
    }

    /// Removing a video with reviewed frames asks first; others go straight away.
    func needsConfirmToRemove(_ videoId: String) -> Bool {
        (session(named: videoId)?.reviewedCount ?? 0) > 0
    }

    /// Forget a failed cut.
    func dismissFailure(_ videoId: String) {
        jobs.removeAll { $0.id == videoId && $0.failure != nil }
    }

    private func deleteFootage(of video: ClipSource, in clip: PlannedClip) {
        if let session = session(named: clip.videoId(of: video)) { sampler.deleteSession(session) }
        try? FileManager.default.removeItem(atPath: video.clipFile)
    }

    /// The clip's ID for its first video, then <id>_v2, _v3…
    private func nextVideoId(for clip: PlannedClip) -> String {
        let taken = Set(videoIds(of: clip))
        guard taken.contains(clip.id) else { return clip.id }
        var n = 2
        while taken.contains("\(clip.id)_v\(n)") { n += 1 }
        return "\(clip.id)_v\(n)"
    }

    static let dropClipLength: Double = 300
    static let extraCamera = "Extra"
    private static let envPrefix = ["Indoor": "ind", "Beach": "bch", "Grass": "grs"]

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let ownFootageLicense = "Own footage"

    /// Cut `length` seconds from `start` out of a link or a local file, log
    /// it, then sample it into the dataset as a new video of the clip.
    /// Returns the new video's ID, or nil if it couldn't start.
    /// `provenance` is the video being moved here from another card: its
    /// origin, licence and fingerprint carry over, and `finished` hears
    /// whether the cut worked.
    @discardableResult
    func addVideo(to clipId: String, source: String, start: Double, length: Double,
                  license: String, frames: Int? = nil, allowDuplicate: Bool = false,
                  provenance: ClipSource? = nil, finished: ((Bool) -> Void)? = nil) -> String? {
        guard project != nil, let dir = projectDir,
              let clip = project?.clips.first(where: { $0.id == clipId }) else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = license.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "Paste a link or choose a file first."; return nil }
        guard !note.isEmpty else { status = "Add the licence or permission this video is used under."; return nil }
        guard let script = Self.fetchScript else {
            status = "scripts/fetch_clip.py wasn't found next to the RallyLab sources."
            return nil
        }

        let fingerprint = provenance.flatMap { self.fingerprint(of: $0) } ?? fingerprint(of: trimmed)
        let overlapping = uses(of: fingerprint).filter { $0.overlaps(start: start, length: length) }
        if !allowDuplicate, let use = overlapping.first {
            status = "Already used: \(Self.displayName(of: trimmed)) \(use.range) is in \(use.videoId)"
                + (use.clipId == clipId ? " on this card." : ".")
            return nil
        }

        let videoId = nextVideoId(for: clip)
        let isFile = FileManager.default.fileExists(atPath: (trimmed as NSString).expandingTildeInPath)
        var args = [script.path, trimmed,
                    "--id", videoId, "--license", note,
                    "--start", String(start), "--length", String(length),
                    "--root", dir.appendingPathComponent("footage").path,
                    "--force", "--result-json"]
        if let env = Self.envFlag(clip) { args += ["--env", env] }

        let name = provenance.map { $0.title.isEmpty ? Self.displayName(of: $0.origin) : $0.title }
            ?? Self.displayName(of: trimmed)
        jobs.append(VideoJob(id: videoId, clipId: clipId, name: name,
                             fraction: isFile ? nil : 0, fingerprint: fingerprint, start: start, length: length))
        status = "\(videoId): \(isFile ? "cutting the file" : "downloading the section")…"

        Task {
            let outcome = await Self.runFetch(args: args) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, let i = self.jobs.firstIndex(where: { $0.id == videoId }) else { return }
                    self.jobs[i].fraction = fraction
                }
            }
            switch outcome {
            case .failure(let failure):
                if let i = jobs.firstIndex(where: { $0.id == videoId }) { jobs[i].failure = failure.message }
                status = "\(videoId): \(failure.message)"
                finished?(false)
            case .success(let result):
                jobs.removeAll { $0.id == videoId }
                recordVideo(videoId, in: clipId, result: result, kind: isFile ? .file : .link,
                            origin: trimmed, license: note, frames: frames, fingerprint: fingerprint,
                            provenance: provenance)
                // A session left by an earlier video with this ID.
                if let old = session(named: videoId) { sampler.deleteSession(old) }
                let split = project?.clips.first(where: { $0.id == clipId })?.split
                sampler.enqueueClip(URL(fileURLWithPath: result.file), sessionName: DatasetStore.safeName(videoId),
                                    split: split, targetFrames: frames ?? project?.targetFrames)
                status = "\(videoId): cut \(Int(result.duration.rounded()))s, sampling…"
                finished?(true)
            }
        }
        return videoId
    }

    private func recordVideo(_ videoId: String, in clipId: String, result: FetchResult, kind: ClipSource.Kind,
                             origin: String, license: String, frames: Int?, fingerprint: String?,
                             provenance: ClipSource?) {
        guard let i = project?.clips.firstIndex(where: { $0.id == clipId }) else { return }
        project?.clips[i].videos.append(ClipSource(
            kind: provenance?.kind ?? kind,
            origin: provenance?.origin ?? (kind == .link ? result.url : origin),
            start: provenance?.start ?? result.start, length: result.duration, license: license,
            title: provenance?.title ?? result.title, uploader: provenance?.uploader ?? result.uploader,
            clipFile: result.file, fetchedAt: provenance?.fetchedAt ?? Date(),
            videoId: videoId == clipId ? nil : videoId, frames: frames, fingerprint: fingerprint
        ))
        save()
    }

    // MARK: - Recognising a video used before

    /// Where a video has been used: on which card, as which video, and
    /// which stretch of it.
    struct VideoUse: Equatable {
        let clipId: String
        let videoId: String
        let start: Double
        let length: Double

        /// Sharing more than a second: cuts land on keyframes, so back-to-back
        /// stretches can touch by a fraction of a second.
        func overlaps(start other: Double, length otherLength: Double) -> Bool {
            min(start + length, other + otherLength) - max(start, other) > 1
        }

        var range: String {
            "\(Self.clock(start))–\(Self.clock(start + length))"
        }

        private static func clock(_ seconds: Double) -> String {
            let s = Int(seconds.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                             : String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    /// Every use of a video across the project, cut or still being cut.
    func uses(of fingerprint: String?, excluding videoId: String? = nil) -> [VideoUse] {
        guard let fingerprint, let project else { return [] }
        var found: [VideoUse] = []
        for clip in project.clips {
            for video in clip.videos where self.fingerprint(of: video) == fingerprint {
                found.append(VideoUse(clipId: clip.id, videoId: clip.videoId(of: video),
                                      start: video.start, length: video.length))
            }
        }
        for job in jobs where job.fingerprint == fingerprint && job.failure == nil {
            found.append(VideoUse(clipId: job.clipId, videoId: job.id, start: job.start, length: job.length))
        }
        return found.filter { $0.videoId != videoId }
    }

    func fingerprint(of video: ClipSource) -> String? {
        video.fingerprint ?? fingerprint(of: video.origin)
    }

    @ObservationIgnored private var fingerprintCache: [String: String] = [:]

    /// A link's video ID (YouTube links in any of their forms come out the
    /// same), or a file's content: its size plus a hash of its first and last
    /// 4 MB, so a video dragged in twice from Photos matches whatever it was
    /// called.
    func fingerprint(of source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = (trimmed as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return Self.linkFingerprint(trimmed) }
        if let cached = fingerprintCache[path] { return cached }
        guard let handle = FileHandle(forReadingAtPath: path),
              let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        let chunk: UInt64 = 4 << 20
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: Int(chunk)) { hasher.update(data: head) }
        if size > chunk {
            try? handle.seek(toOffset: size - min(chunk, size - chunk))
            if let tail = try? handle.readToEnd() { hasher.update(data: tail) }
        }
        let print = "file:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        fingerprintCache[path] = print
        return print
    }

    static func linkFingerprint(_ link: String) -> String? {
        guard var parts = URLComponents(string: link), let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        if host == "youtu.be", let id = path.first {
            return "youtube:" + id
        }
        if host.hasSuffix("youtube.com") {
            if let id = parts.queryItems?.first(where: { $0.name == "v" })?.value { return "youtube:" + id }
            if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) { return "youtube:" + path[1] }
        }
        // Anything else: the address without tracking, timestamps or fragment.
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter {
            !["t", "si", "feature", "start"].contains($0.name) && !$0.name.hasPrefix("utm_")
        }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return "link:" + host.replacingOccurrences(of: "www.", with: "") + parts.path
            + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    static func displayName(of source: String) -> String {
        let path = (source as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path).lastPathComponent : source
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

    private nonisolated static func runFetch(
        args: [String], progress: @escaping @Sendable (Double) -> Void
    ) async -> Result<FetchResult, FetchFailure> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + args
            process.environment = ToolEnvironment.variables
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
///   models/                          trained models brought back (Models tab)
///   exports/                         training packages (Models tab)
///   data.yaml                        what `yolo train` reads
enum ProjectLayout {
    static let folders: [String] = {
        let envs = ["indoor", "beach", "grass"]
        return envs.map { "footage/raw/self/\($0)" }
            + envs.map { "footage/raw/online/\($0)" }
            + ["footage/raw/negatives", "footage/meta",
               "images/train", "images/val", "labels/train", "labels/val",
               "sessions", "excluded", "runs", "models", "exports"]
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

struct FootageDrop: Equatable {
    let clipId: String
    let path: String
}

/// A video being cut for a clip, or whose cut failed.
struct VideoJob: Identifiable, Equatable {
    /// The video ID it will have.
    let id: String
    let clipId: String
    let name: String
    var fraction: Double?
    var failure: String?
    let fingerprint: String?
    let start: Double
    let length: Double
}
