//
//  WorkQueueModel.swift
//  RallyLab
//
//  The Queue tab's state: the project's work queue (WorkQueue.File), the
//  source index beside it, and the reconciler run on request. Every read of
//  the project happens off the main actor, and every read-modify-write of
//  the queue file goes through one actor in order (WorkQueueFileAccess), so
//  a refresh and a person's change can never interleave: each sees the file
//  the previous one wrote, and a refresh that began before a cancel can't
//  save its older snapshot over it (Codex, PR #134). A person's action is
//  allowed while a refresh runs; the refresh's "refreshing" flag is cleared
//  when the refresh finishes whatever else happened. Work started before the
//  project changed lands nowhere.
//

import Foundation
import Observation

/// Serialises every read-modify-write of one project's queue file within this process.
actor WorkQueueFileAccess {
    func perform<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T { try operation() }
}

@MainActor @Observable
final class WorkQueueModel {
    /// Where the queue lives: the open project's folder and name, nil without a project.
    private let location: () -> (root: URL, project: String)?
    private(set) var file: WorkQueue.File?
    private(set) var index: SourceRegistry.Index?
    private(set) var summary: WorkQueueReconciler.Summary?
    /// Why the queue could not be read or reconciled; nothing is written then.
    private(set) var problem: String?
    private(set) var refreshing = false
    private(set) var lastRefreshed: Date?
    private(set) var status = "Open a project."
    var filterKind: WorkQueue.Kind?
    var filterState: WorkQueue.State?
    var search = ""
    private let access = WorkQueueFileAccess()
    /// Every operation in flight, so a test (or a project change) can wait for them.
    private var operations: [UUID: Task<Void, Never>] = [:]
    /// Bumped on every project change: an operation started before lands nowhere.
    private var generation = 0

    init(projects: ProjectsModel) {
        location = { [weak projects] in
            guard let projects, let root = projects.projectDir, let name = projects.project?.name else { return nil }
            return (root, name)
        }
    }

    /// For tests and headless use: a fixed project folder, no ProjectsModel (and so no preference written).
    init(root: URL, project: String) {
        location = { (root, project) }
    }

    var root: URL? { location()?.root }

    var visible: [WorkQueue.Task] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (file?.tasks ?? []).filter { t in
            (filterKind == nil || t.kind == filterKind) && (filterState == nil || t.state == filterState)
                && (needle.isEmpty || t.video.lowercased().contains(needle) || (t.observed?.summary.lowercased().contains(needle) ?? false))
        }
        .sorted { ($0.kind.rawValue, Self.order($0.state), $0.video) < ($1.kind.rawValue, Self.order($1.state), $1.video) }
    }

    private static func order(_ s: WorkQueue.State) -> Int { WorkQueue.State.allCases.firstIndex(of: s) ?? 0 }

    func source(of task: WorkQueue.Task) -> SourceRegistry.Source? { index?.byVideo[task.video] }

    /// Waits for every operation in flight (tests).
    func settle() async {
        while let task = operations.values.first { await task.value }
    }

    /// Runs `work` as one operation off the main actor (its file access through `access`, never at the same time
    /// as another operation's); its result is published only while the project is still the one it started on.
    /// `done` runs on the main actor with the result, after the operation's own bookkeeping.
    @discardableResult
    private func operation<T: Sendable>(_ work: @escaping @Sendable () async throws -> T, done: @escaping @MainActor (Result<T, Error>) -> Void) -> Task<Void, Never> {
        let mine = generation
        let id = UUID()
        let task = Task { [weak self] in
            let result: Result<T, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await work()) } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.operations.removeValue(forKey: id)
            guard mine == self.generation else { return }
            done(result)
        }
        operations[id] = task
        return task
    }

    /// The last mutation submitted: the next one waits for it, so a person's actions land in the order they were
    /// made. The actor alone orders nothing — it only keeps two operations from running at once — and a cancel
    /// then a reopen of one task could land as reopen then cancel, the next cancel then refused as a same-state
    /// move and lost (seen in the revision-2 test under load). A refresh is not in this order: its reconcile is
    /// applied over the file as it is when its turn on the actor comes, after its own slow reading.
    private var lastMutation: Task<Void, Never>?

    /// The queue as written, without reconciling: quick, so the tab shows the last state at once.
    func load() {
        guard let (root, _) = location() else { file = nil; index = nil; status = "Open a project."; return }
        let access = self.access
        operation({ try await access.perform { try WorkQueue.Store(root: root).load() } }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let f):
                self.file = f
                self.problem = nil
                self.status = f.map { "\($0.tasks.count) tasks as of \($0.updatedAt). Refresh reconciles them with the annotation files." } ?? "No queue yet: Refresh builds it from the project's annotations."
            case .failure(let e):
                self.file = nil
                self.problem = e.localizedDescription
                self.status = "The queue can't be read."
            }
        }
    }

    /// Reconcile the queue with the annotation files and the source index, then write it. The slow part (reading
    /// the project) runs first; the queue file is then read, reconciled and written as one serialised operation,
    /// so a change made meanwhile is reconciled, never overwritten. Nothing is written when an input can't be read.
    func refresh() {
        guard let (root, project) = location(), !refreshing else { return }
        refreshing = true
        status = "Reconciling the queue with the project's annotations…"
        let access = self.access
        operation({ () async throws -> (WorkQueue.File, WorkQueueReconciler.Summary, SourceRegistry.Index) in
            let policy = try await access.perform { try WorkQueue.Store(root: root).load()?.policy } ?? WorkQueue.Policy()
            // The slow part — every session, the inventory, the index — outside the serialised access.
            let inputs = try WorkQueueReconciler.gather(root: root, policy: policy)
            let index = try SourceRegistry.load(root: root)
            let (file, summary) = try await access.perform {
                let store = WorkQueue.Store(root: root)
                var file = try store.load() ?? WorkQueue.File(project: project, updatedAt: WorkQueue.stamp(inputs.now))
                let summary = WorkQueueReconciler.apply(inputs, to: &file)
                try store.save(file)
                return (file, summary)
            }
            return (file, summary, index)
        }) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            switch result {
            case .success(let (file, summary, index)):
                self.file = file
                self.summary = summary
                self.index = index
                self.problem = nil
                self.lastRefreshed = Date()
                self.status = WorkQueueReconciler.statusLines(file, summary: summary).joined(separator: "  ·  ")
            case .failure(let e):
                self.problem = e.localizedDescription
                self.status = "Not reconciled; the queue on disk is unchanged."
            }
        }
    }

    func retry(_ id: String) { mutate("retry") { try $0.retry(id, now: Date()) } }
    func cancel(_ id: String) { mutate("cancel") { try $0.cancel(id, now: Date()) } }
    func reopen(_ id: String) { mutate("reopen") { try $0.reopen(id, now: Date()) } }

    /// A person's change: the queue is read from disk, changed and written back as one serialised operation, so
    /// neither a refresh nor a headless run in between is overwritten; an unreadable file refuses the change.
    private func mutate(_ what: String, _ change: @escaping @Sendable (inout WorkQueue.File) throws -> Void) {
        guard let (root, _) = location() else { return }
        let access = self.access
        let previous = lastMutation
        lastMutation = operation({
            await previous?.value
            return try await access.perform { () throws -> WorkQueue.File in
            let store = WorkQueue.Store(root: root)
            guard var file = try store.load() else { throw WorkQueue.Failure.invalid("no queue on disk to \(what)") }
            try change(&file)
            try store.save(file)
            return file
        } }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let file):
                self.file = file; self.problem = nil
                self.status = what == "cancel" ? "\(what): saved." : "\(what): saved — the task is pending, not openable, until Refresh judges it from the project's records."
            case .failure(let e): self.problem = e.localizedDescription
            }
        }
    }

    /// The project changed or closed: nothing of the old one stays, and work in flight lands nowhere.
    func projectChanged() {
        generation += 1
        refreshing = false
        file = nil; index = nil; summary = nil; problem = nil; lastRefreshed = nil
        load()
    }
}
