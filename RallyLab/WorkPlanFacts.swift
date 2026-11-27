//
//  WorkPlanFacts.swift
//  RallyLab
//
//  What the work plan (WorkPlan) needs that only the project's files say:
//  each recording's camera group, where its coverage audit stands over
//  every draw, and the footage type a person confirmed. Read off the main
//  actor (the audit's status checks every drawn original that is on this
//  Mac), shown in the Plan tab, and published with the project's state so
//  the phone plans by the same groups and audit states.
//

import Foundation
import Observation

enum WorkPlanFacts {
    struct Local: Sendable, Equatable {
        var published: WorkPlan.Published
        /// The footage type a person confirmed, by recording (FootageProperties).
        var types: [String: String]
        /// The recordings the project's listed withheld closure names; nil when it can't be read. For the plan's
        /// counts only — what may be opened, or run a model, asks the closure with its content check, every time.
        var withheld: Set<String>?
    }

    /// Each recording's camera group, from the project's split manifest by the exporter's rule
    /// (RallyClassifierExporter.groupIds) over every recording it lists — so two recordings a third one ties
    /// together are one group here even where a dataset that leaves the third out would count two. A recording
    /// the manifest does not list (added since it was written) is not named: it counts as its own group.
    static func groups(root: URL) -> [String: String] {
        guard let manifest = DatasetSplitManifest.read(from: root.appendingPathComponent("manifests/manifest.json")) else { return [:] }
        let content = Dictionary(manifest.videos.compactMap { v in v.contentFingerprint.map { (v.video, $0) } }) { a, _ in a }
        return RallyClassifierExporter.groupIds(manifest.videos, content: content)
    }

    /// Where each drawn recording's audit stands, the later draw's word over the earlier's; nil when the draws
    /// or the project's reservations can't be read (nothing is guessed then). A recording in no draw is not named.
    /// Counts only, nothing opened: read without the per-file content check (`live: false`), so the plan still
    /// says where the audits stand while the footage is off this Mac.
    static func audits(root: URL) -> [String: WorkPlan.Audit]? {
        let dir = CoverageAudit.drawsDirectory(in: root)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }
        var out: [String: WorkPlan.Audit] = [:]
        do {
            let draws = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("-draw.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in draws {
                for status in try CoverageAudit.status(draw: try CoverageAudit.loadDraw(url), root: root, live: false) {
                    if let audit = audit(of: status) { out[status.recordingId] = audit }
                }
            }
        } catch { return nil }
        return out
    }

    /// A drawn recording's audit as the plan reads it; nil for one set aside from its draw (typed other than
    /// continuous since). Findings whose recording's marks have changed since the draw are taken as dealt
    /// with: the recording waits for the next draw.
    static func audit(of status: CoverageAudit.RecordingStatus) -> WorkPlan.Audit? {
        guard status.setAside == nil else { return nil }
        if status.state.contaminated { return status.movedIntervals > 0 ? .notDrawn : .findings }
        return status.state.partial ? .open : .clean
    }

    /// The footage type of each recording a person confirmed one for; a record that can't be read says nothing.
    static func types(root: URL) -> [String: String] {
        guard let records = try? FootageProperties.Store(root: root).loadAll().records else { return [:] }
        return records.compactMapValues { $0.recordingTypeAt == nil ? nil : $0.recordingType.rawValue }
    }

    static func read(root: URL, recordings: [String], now: Date = Date()) -> Local {
        let groups = groups(root: root), audits = audits(root: root)
        let rows = recordings.sorted().map { name in
            WorkPlan.Published.Recording(name: name, group: groups[name] ?? name, audit: audits.map { $0[name] ?? .notDrawn })
        }
        return Local(published: WorkPlan.Published(recordings: rows, publishedAt: EventReview.stamp(now)), types: types(root: root),
                     withheld: try? ScoringExposure.Closures.current(in: root).withheld)
    }
}

/// The open project's work-plan facts, read off the main actor; what a read for another project (or an older
/// read of this one) brings back lands nowhere.
@MainActor @Observable
final class WorkPlanModel {
    private(set) var facts: WorkPlanFacts.Local?
    private(set) var reading = false
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var generation = 0

    func refresh(root: URL?, recordings: [String]) {
        generation += 1
        let mine = generation
        if root != self.root { facts = nil; self.root = root }
        guard let root else { reading = false; return }
        reading = true
        Task {
            let read = await Task.detached(priority: .utility) { WorkPlanFacts.read(root: root, recordings: recordings) }.value
            guard mine == generation else { return }
            facts = read
            reading = false
        }
    }
}
