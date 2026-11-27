//
//  WorkPlan.swift
//  RallyLab (macOS and iPhone)
//
//  What a person still has to do to each recording before it can teach the
//  rally classifier, the same on the Mac and the phone: mark its rallies,
//  say what its footage is, review its unmarked time in the coverage audit —
//  and what then waits on the Mac (a new audit draw, marks to fix after a
//  finding). The marking order is the queue's (LabelQueue.markingOrder): a
//  recording from a camera group with nothing marked yet leads, since a new
//  group widens the dataset and another recording of a covered one does not.
//
//  Two facts only the project's files hold — a recording's camera group
//  (the exporter's grouping) and where its audit stands over every draw —
//  are published by the Mac with the project's state (`Published`,
//  label_project_state.work); until a phone has them, each recording is
//  its own group and the audit steps are not shown.
//

import Foundation

enum WorkPlan {

    /// Where a recording's negative-coverage audit stands over the project's draws.
    enum Audit: String, Codable, Sendable {
        /// In no draw (or set aside from the one it was in): it waits for a draw made on the Mac.
        case notDrawn = "not_drawn"
        /// Drawn, with intervals still to look at.
        case open
        /// Every interval looked at, none with a finding.
        case clean
        /// A reviewer found something in its unmarked time: its marks are fixed before it is drawn again.
        case findings
    }

    /// What only the project's files say, as the Mac publishes it. A list, not a dictionary by name: the
    /// labeling client converts every JSON key between snake and camel case, and a recording's name is not a key
    /// to convert.
    struct Published: Codable, Hashable, Sendable {
        struct Recording: Codable, Hashable, Sendable {
            var name: String
            /// The camera group, named by its smallest recording.
            var group: String
            /// nil when the Mac could not read the draws.
            var audit: Audit?
        }
        var recordings: [Recording]
        /// When the Mac wrote it (ISO 8601).
        var publishedAt: String

        var byName: [String: Recording] { Dictionary(recordings.map { ($0.name, $0) }) { a, _ in a } }
    }

    /// The footage type a person has given, as the audit reads it.
    static let continuous = "continuous"

    /// A recording as the plan sees it.
    struct Recording {
        let video: LabelQueue.Video
        /// The footage type once a person has said it ("continuous", "edited", "unknown", or a choice still on
        /// its way to the Mac); nil while nobody has.
        let type: String?
        /// nil when not known on this device.
        let audit: Audit?
    }

    enum Step: Int, CaseIterable, Sendable {
        /// Mark every rally (the marking pass).
        case mark
        /// Marked through: say whether the footage is continuous or edited.
        case type
        /// Continuous and drawn: look at its unmarked intervals.
        case audit
        /// Continuous and audited with findings: its marks are fixed (Edit rally times), then it is drawn again.
        case fix
        /// Continuous, in no draw: waits for the next audit draw, made on the Mac.
        case draw
        /// Nothing left for a person: audited clean, or not continuous (its rallies count, its unmarked time does
        /// not), or withheld (never audited), or its audit is not known here.
        case done
    }

    struct Item: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let surface: String
        let group: String
        let step: Step
        /// Seconds of footage, when known.
        let seconds: Double?
        /// Withheld from every model, or not known not to be: marked by hand for scoring, never training data.
        let held: Bool
        /// A marking job that is the first of a camera group with nothing marked through.
        let newGroup: Bool
        /// Its footage can be played on this device.
        let playable: Bool
    }

    /// One surface's recordings that can teach the classifier (not withheld, not set aside).
    struct Surface: Hashable {
        let surface: String
        var recordings = 0
        var marked = 0
        /// Marked through and typed continuous: the ones whose unmarked time can become negatives.
        var continuous = 0
        /// Of those, audited clean.
        var clean = 0
        var groups = 0
        /// Groups with a recording marked through.
        var groupsMarked = 0
        /// Groups with a recording audited clean.
        var groupsClean = 0
    }

    struct Plan {
        /// Every recording not set aside: the marking jobs in the queue's order, then the rest by name.
        let items: [Item]
        /// Indoor, Grass, Beach in plan order, then any other surface with recordings.
        let surfaces: [Surface]
        /// Whether the audit steps are known here (the Mac's facts have arrived).
        let auditKnown: Bool
        /// Set aside (the backlog).
        let backlog: Int

        func items(_ step: Step, held: Bool? = false) -> [Item] {
            items.filter { $0.step == step && (held == nil || $0.held == held) }
        }

        /// Footage still to watch in the marking jobs that can teach the classifier.
        var markingSeconds: Double { items(.mark).reduce(0) { $0 + ($1.seconds ?? 0) } }
        /// Marking jobs that open a camera group.
        var newGroups: Int { items(.mark).filter(\.newGroup).count }
        var total: Surface {
            surfaces.reduce(into: Surface(surface: "All")) { t, s in
                t.recordings += s.recordings; t.marked += s.marked; t.continuous += s.continuous; t.clean += s.clean
                t.groups += s.groups; t.groupsMarked += s.groupsMarked; t.groupsClean += s.groupsClean
            }
        }
    }

    static func step(of r: Recording) -> Step {
        guard r.video.complete else { return .mark }
        guard let type = r.type else { return .type }
        guard type == continuous, r.video.access == .open, let audit = r.audit else { return .done }
        switch audit {
        case .notDrawn: return .draw
        case .open: return .audit
        case .findings: return .fix
        case .clean: return .done
        }
    }

    static func plan(_ recordings: [Recording]) -> Plan {
        let live = recordings.filter { !$0.video.backlog }
        let byName = Dictionary(live.map { ($0.video.plan.name, $0) }) { a, _ in a }
        let order = LabelQueue.markingOrder(live.map(\.video), playableOnly: false).map(\.plan.name)
        let usable = live.filter { $0.video.access == .open }
        var covered = Set(usable.filter(\.video.complete).map(\.video.groupKey))

        func item(_ r: Recording, newGroup: Bool) -> Item {
            Item(name: r.video.plan.name, surface: r.video.plan.surface, group: r.video.groupKey, step: step(of: r), seconds: r.video.seconds,
                 held: r.video.access != .open, newGroup: newGroup, playable: r.video.plan.available)
        }
        var items: [Item] = order.compactMap { name in
            byName[name].map { r in item(r, newGroup: r.video.access == .open && covered.insert(r.video.groupKey).inserted) }
        }
        let queued = Set(order)
        items += live.filter { !queued.contains($0.video.plan.name) }.sorted { $0.video.plan.name < $1.video.plan.name }.map { item($0, newGroup: false) }

        var rows: [String: Surface] = [:]
        var groups: [String: (all: Set<String>, marked: Set<String>, clean: Set<String>)] = [:]
        for r in usable {
            let s = r.video.plan.surface, g = r.video.groupKey
            let continuous = r.video.complete && r.type == continuous
            let clean = continuous && r.audit == .clean
            rows[s, default: Surface(surface: s)].recordings += 1
            groups[s, default: ([], [], [])].all.insert(g)
            if r.video.complete { rows[s]!.marked += 1; groups[s]!.marked.insert(g) }
            if continuous { rows[s]!.continuous += 1 }
            if clean { rows[s]!.clean += 1; groups[s]!.clean.insert(g) }
        }
        for (s, g) in groups { rows[s]!.groups = g.all.count; rows[s]!.groupsMarked = g.marked.count; rows[s]!.groupsClean = g.clean.count }
        let named = TrainingPlan.surfaces
        let surfaces = (named + rows.keys.filter { !named.contains($0) }.sorted()).compactMap { rows[$0] }
        return Plan(items: items, surfaces: surfaces, auditKnown: live.contains { $0.audit != nil }, backlog: recordings.count - live.count)
    }
}
