//
//  WorkQueue.swift
//  RallyLab
//
//  RallyLab 2.0, phase 1: persistent labeling tasks. One record per unit of
//  labeling work on a recording — its Stage 1 rally boundaries, its dense
//  ball tracks, its net corners, and (later) its contact labels per rally —
//  with a deterministic id, so asking for the same task twice yields the one
//  record, an explicit lifecycle, and a history of every change. The file
//  is `<project>/tasks/work-queue.json`, written whole and atomically; one
//  that exists but can't be read is an error, never an empty queue, so a
//  crash can neither duplicate a task nor lose one by overwriting.
//
//  A task records work; it never holds an annotation. What is complete is
//  learned from the files that own the annotations (WorkQueueReconciler),
//  and a machine proposal is never counted as a person's label.
//

import Foundation

enum WorkQueue {
    static let schemaVersion = 1

    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Stage 1 (D-024): every rally's serve contact and ball dead over the whole recording, in rallyevents.json.
        case rallyBoundaries = "rally_boundaries"
        /// Dense ball tracks (the L2 detector's labels): finished rallies with checked frames, in the session.
        case ballTracks = "ball_tracks"
        /// The net's four corners on one frame, in net-labels.json.
        case netCorners = "net_corners"
        /// Per-rally contact labels (Stage 2, D-024): defined now, scoped by the rally's persistent id; nothing creates them yet.
        case contactLabels = "contact_labels"

        var title: String {
            switch self {
            case .rallyBoundaries: return "Rally boundaries"
            case .ballTracks: return "Ball tracks"
            case .netCorners: return "Net corners"
            case .contactLabels: return "Contact labels"
            }
        }
    }

    enum State: String, Codable, CaseIterable, Sendable {
        case pending, ready
        case inProgress = "in_progress"
        case needsReview = "needs_review"
        case complete, blocked, failed, quarantined, cancelled

        var title: String {
            switch self {
            case .inProgress: return "In progress"
            case .needsReview: return "Needs review"
            default: return rawValue.capitalized
            }
        }
        /// Nothing moves a cancelled task but an explicit reopen.
        var isFinal: Bool { self == .cancelled }
    }

    /// Who moved a task.
    enum Actor: String, Codable, Sendable {
        /// The reconciler, from what the annotation files say.
        case reconcile
        /// A person, in the queue (retry, cancel, reopen).
        case user
    }

    struct Transition: Codable, Equatable, Sendable {
        var from: State?
        var to: State
        var at: String
        var by: Actor
        var note: String?
    }

    /// What the reconciler saw in the annotation files: facts, kept apart from the state they led to.
    struct Observed: Codable, Equatable, Sendable {
        var at: String
        var summary: String
        /// The legacy "marked every rally" declaration (session.ralliesMarked): the owner said the whole clip was
        /// marked. A declaration, not verified timeline coverage; it never completes a Stage 1 task on its own.
        var declaredComplete: Bool?
        /// Stage 1 reviewed coverage of the timeline, 0…1 (rallyevents.json), nil without a record.
        var verifiedCoverage: Double?
        /// Rallies a person labeled (LineagePackage.isHumanLabeled), for ball tracks.
        var humanLabeled: Int?
        /// Pre-tracked rallies nobody has said are or aren't rallies: proposals, never labels.
        var machineProposed: Int?
        /// Rallies someone started and hasn't finished.
        var open: Int?
        /// A model's proposal is on file awaiting the person's confirmation (net corners).
        var proposalPending: Bool?
    }

    struct Task: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let kind: Kind
        /// The dataset session name.
        let video: String
        /// The rally's persistent id for per-rally kinds; nil for per-recording kinds.
        let scope: String?
        /// SourceRegistry.Source.identityKey when the task was created, so a video id reused for another recording is visible.
        var identityKey: String?
        var state: State
        var createdAt: String
        var updatedAt: String
        var attempts: Int
        /// Why it is blocked, failed or quarantined.
        var reason: String?
        var observed: Observed?
        var history: [Transition]

        static func id(kind: Kind, video: String, scope: String?) -> String {
            scope.map { "\(kind.rawValue):\(video):\($0)" } ?? "\(kind.rawValue):\(video)"
        }
    }

    struct Policy: Codable, Equatable, Sendable {
        /// Rallies with human-labeled ball tracks a recording needs before its ball-track task is complete.
        var ballTrackRalliesPerRecording = 2
        init(ballTrackRalliesPerRecording: Int = 2) { self.ballTrackRalliesPerRecording = ballTrackRalliesPerRecording }
        private enum CodingKeys: String, CodingKey { case ballTrackRalliesPerRecording }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ballTrackRalliesPerRecording = try c.decodeIfPresent(Int.self, forKey: .ballTrackRalliesPerRecording) ?? 2
        }
    }

    struct File: Codable, Equatable, Sendable {
        var schemaVersion: Int = WorkQueue.schemaVersion
        var project: String
        var policy: Policy = Policy()
        var updatedAt: String
        var tasks: [Task] = []

        init(project: String, policy: Policy = Policy(), updatedAt: String, tasks: [Task] = []) {
            self.project = project; self.policy = policy; self.updatedAt = updatedAt; self.tasks = tasks
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, project, policy, updatedAt, tasks }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == WorkQueue.schemaVersion else { throw Failure.unsupportedVersion(schemaVersion) }
            project = try c.decode(String.self, forKey: .project)
            policy = try c.decodeIfPresent(Policy.self, forKey: .policy) ?? Policy()
            updatedAt = try c.decode(String.self, forKey: .updatedAt)
            tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) ?? []
            var seen = Set<String>()
            for t in tasks { guard seen.insert(t.id).inserted else { throw Failure.invalid("task id \(t.id) appears twice") } }
        }

        func task(_ id: String) -> Task? { tasks.first { $0.id == id } }
        func tasks(_ kind: Kind) -> [Task] { tasks.filter { $0.kind == kind } }
        func count(_ state: State, kind: Kind? = nil) -> Int { tasks.filter { $0.state == state && (kind == nil || $0.kind == kind) }.count }

        // MARK: Mutations (the only ways a task changes)

        /// The task for this work, created `pending` if there is none; asking again returns the one that exists,
        /// unchanged (no history entry).
        @discardableResult
        mutating func enqueue(kind: Kind, video: String, scope: String? = nil, identityKey: String? = nil, now: Date) -> (task: Task, created: Bool) {
            let id = Task.id(kind: kind, video: video, scope: scope)
            if let existing = task(id) { return (existing, false) }
            let stamp = WorkQueue.stamp(now)
            let t = Task(id: id, kind: kind, video: video, scope: scope, identityKey: identityKey, state: .pending, createdAt: stamp, updatedAt: stamp,
                         attempts: 0, reason: nil, observed: nil, history: [Transition(from: nil, to: .pending, at: stamp, by: .reconcile, note: "created")])
            tasks.append(t)
            updatedAt = stamp
            return (t, true)
        }

        /// Move a task, if the move is allowed for `by` (WorkQueue.allowed). The reconciler's move to the state a task
        /// is in records nothing; a person's is refused, so a retry of a task that has not failed, or a second
        /// cancel, is an error rather than a silent no-op.
        mutating func transition(_ id: String, to: State, by: Actor, now: Date, note: String? = nil, reason: String? = nil) throws {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw Failure.noSuchTask(id) }
            let from = tasks[i].state
            if from == to {
                if by == .user { throw Failure.illegalTransition(id: id, from: from, to: to, by: by) }
                return
            }
            guard WorkQueue.allowed(from: from, to: to, by: by) else { throw Failure.illegalTransition(id: id, from: from, to: to, by: by) }
            let stamp = WorkQueue.stamp(now)
            tasks[i].state = to
            tasks[i].updatedAt = stamp
            tasks[i].reason = [.blocked, .failed, .quarantined].contains(to) ? reason : nil
            tasks[i].history.append(Transition(from: from, to: to, at: stamp, by: by, note: note))
            updatedAt = stamp
        }

        /// A person tries a failed task again: back to pending, one more attempt on the count.
        mutating func retry(_ id: String, now: Date) throws {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw Failure.noSuchTask(id) }
            guard tasks[i].state == .failed else { throw Failure.illegalTransition(id: id, from: tasks[i].state, to: .pending, by: .user) }
            try transition(id, to: .pending, by: .user, now: now, note: "retry after: \(tasks[i].reason ?? "failure")")
            tasks[i].attempts += 1
        }

        mutating func cancel(_ id: String, now: Date, note: String? = nil) throws {
            try transition(id, to: .cancelled, by: .user, now: now, note: note)
        }

        /// A cancelled task back into the queue (the only way out of cancelled).
        mutating func reopen(_ id: String, now: Date) throws {
            try transition(id, to: .pending, by: .user, now: now, note: "reopened")
        }

        /// The reconciler's verdict: what the files show, recorded every time; the state changed only when it differs
        /// (and never on a cancelled task). Returns whether the state changed.
        @discardableResult
        mutating func reconcile(_ id: String, state: State, reason: String?, observed: Observed, now: Date) throws -> Bool {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw Failure.noSuchTask(id) }
            guard !tasks[i].state.isFinal else { return false }
            let changed = tasks[i].state != state
            tasks[i].observed = observed
            if changed {
                try transition(id, to: state, by: .reconcile, now: now, note: observed.summary, reason: reason)
            } else if tasks[i].reason != reason, [.blocked, .failed, .quarantined].contains(state) {
                tasks[i].reason = reason
                tasks[i].updatedAt = WorkQueue.stamp(now)
                updatedAt = tasks[i].updatedAt
            }
            return changed
        }
    }

    // MARK: - Lifecycle

    /// pending → ready → in_progress → needs_review → complete; blocked, failed, quarantined and cancelled beside them.
    /// The reconciler may set any non-final state from any non-final state, since the files are the truth of what is
    /// done; a person may retry (failed → pending), cancel (anything not final), or reopen (cancelled → pending).
    static func allowed(from: State, to: State, by: Actor) -> Bool {
        guard from != to else { return true }
        switch by {
        case .reconcile:
            return !from.isFinal && !to.isFinal
        case .user:
            switch (from, to) {
            case (.failed, .pending), (.cancelled, .pending): return true
            case (_, .cancelled): return !from.isFinal
            default: return false
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case invalid(String)
        case unreadable(URL, String)
        case noSuchTask(String)
        case illegalTransition(id: String, from: State, to: State, by: Actor)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "work-queue.json is schema \(v); this build reads \(WorkQueue.schemaVersion)."
            case .invalid(let why): return "work-queue.json is not valid: \(why)"
            case .unreadable(let url, let why): return "\(url.path) exists but can't be read, and it holds the queue's history; repair or restore it before the queue is written again: \(why)"
            case .noSuchTask(let id): return "no task \(id)"
            case .illegalTransition(let id, let from, let to, let by): return "\(id): \(from.rawValue) → \(to.rawValue) is not a move \(by.rawValue) may make"
            }
        }
    }

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - The file

    static func url(in root: URL) -> URL { root.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent("work-queue.json") }

    struct Store: Sendable {
        let url: URL
        init(root: URL) { url = WorkQueue.url(in: root) }
        init(url: URL) { self.url = url }

        /// The queue as written, nil when there is none; a file that exists but can't be read throws (never empty).
        func load() throws -> File? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable(url, error.localizedDescription) }
            do { return try JSONDecoder().decode(File.self, from: data) } catch let f as Failure { throw f } catch { throw Failure.unreadable(url, error.localizedDescription) }
        }

        /// Written whole, atomically (a temporary file renamed into place): a reader sees the old file or the new one.
        func save(_ file: File) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        }
    }
}
