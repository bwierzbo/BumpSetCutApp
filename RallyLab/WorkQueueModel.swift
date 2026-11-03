//
//  WorkQueueModel.swift
//  RallyLab
//
//  The Queue tab's state: the project's work queue (WorkQueue.File), the
//  source index beside it, and the reconciler run on request. Every read of
//  the project and every write of the queue happens off the main actor; a
//  refresh started before the project changed lands nowhere.
//

import Foundation
import Observation

@MainActor @Observable
final class WorkQueueModel {
    let projects: ProjectsModel
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
    private var work: Task<Void, Never>?
    /// Bumped on every project change: work started before lands nowhere.
    private var generation = 0

    init(projects: ProjectsModel) {
        self.projects = projects
    }

    var root: URL? { projects.projectDir }

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

    /// The queue as written, without reconciling: quick, so the tab shows the last state at once.
    func load() {
        guard let root else { file = nil; index = nil; status = "Open a project."; return }
        work?.cancel()
        generation += 1
        let mine = generation
        work = Task { [weak self] in
            let loaded: Result<WorkQueue.File?, Error> = await Task.detached(priority: .userInitiated) { Result { try WorkQueue.Store(root: root).load() } }.value
            guard let self, mine == self.generation else { return }
            switch loaded {
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

    /// Reconcile the queue with the annotation files and the source index, then write it. Nothing is written when
    /// an input can't be read (the reconciler fails closed).
    func refresh() {
        guard let root, let project = projects.project?.name else { return }
        work?.cancel()
        generation += 1
        let mine = generation
        refreshing = true
        status = "Reconciling the queue with the project's annotations…"
        work = Task { [weak self] in
            let result: Result<(WorkQueue.File, WorkQueueReconciler.Summary, SourceRegistry.Index), Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let (file, summary) = try WorkQueueReconciler.run(root: root, project: project)
                    let index = try SourceRegistry.load(root: root)
                    return (file, summary, index)
                }
            }.value
            guard let self, mine == self.generation else { return }
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

    /// A person's change: the queue is read from disk again, changed, and written back, so a headless run in between
    /// is not overwritten; an unreadable file refuses the change.
    private func mutate(_ what: String, _ change: @escaping @Sendable (inout WorkQueue.File) throws -> Void) {
        guard let root else { return }
        generation += 1
        let mine = generation
        work = Task { [weak self] in
            let result: Result<WorkQueue.File, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let store = WorkQueue.Store(root: root)
                    guard var file = try store.load() else { throw WorkQueue.Failure.invalid("no queue on disk to \(what)") }
                    try change(&file)
                    try store.save(file)
                    return file
                }
            }.value
            guard let self, mine == self.generation else { return }
            switch result {
            case .success(let file): self.file = file; self.problem = nil; self.status = "\(what): saved."
            case .failure(let e): self.problem = e.localizedDescription
            }
        }
    }

    /// The project changed or closed: nothing of the old one stays, and work in flight lands nowhere.
    func projectChanged() {
        work?.cancel()
        generation += 1
        refreshing = false
        file = nil; index = nil; summary = nil; problem = nil; lastRefreshed = nil
        load()
    }
}
