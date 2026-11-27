//
//  LabelQueue.swift
//  RallyLab (macOS and iPhone)
//
//  What to label next, the same on the Mac and the phone. Marking leads:
//  every video not marked all the way through is a job, the ones started
//  and left first, then round-robin over the surfaces (the one with the
//  fewest marked videos first) so the decision model's labels stay mixed —
//  a recording of a camera group with nothing marked yet before another of
//  a group already covered, clips under a minute after the longer ones, and
//  recordings withheld from the models (marked for scoring only) last.
//  Between them, rallies to track from the videos the plan wants frames
//  from (one each, so they spread over many videos). A video set aside
//  (the backlog: it won't be good to mark) is no job of either kind until
//  someone puts it back. A recording the project withholds from every model
//  (LabelAccess) is never a track job — the detectors propose every frame
//  of one — and, for an ordinary labeler, no job at all.
//

import Foundation

/// Why a recording was set aside (the backlog, migration 053): the fixed words both devices offer; anything else
/// a person typed is kept as it is.
enum BacklogReason: String, CaseIterable, Codable, Sendable {
    case poorFootage = "poor footage"
    case notAMatch = "not a match"
    case wrongCamera = "wrong camera"
    case other = "other"

    var title: String {
        switch self {
        case .poorFootage: return "Poor footage"
        case .notAMatch: return "Not a match"
        case .wrongCamera: return "Wrong camera"
        case .other: return "Other"
        }
    }
}

/// What may be done with a recording on this device, by what the device knows of its project's withheld list
/// (final test, candidates, lineage holdout, legacy holdout and every alias; owner decisions of 2026-11-12, D-036
/// §5C and §5E). The Mac reads the list from the project; the phone has only what the server serves
/// (`label_withheld`, published by the Mac's sync) — so "not known" is a state of its own, never read as "not
/// withheld". The rule is the same for every account, the lead's included: the server's protection (migration 049)
/// exempts a lead, this does not.
enum LabelAccess: Equatable, Sendable {
    /// Not withheld: every task.
    case open
    /// Withheld, or not known not to be, where annotation by hand goes on (the Mac; a lead's phone): the marking
    /// pass, the footage type, the frames of rallies already tracked checked by hand. Nothing new that runs a
    /// model over the recording or carries what one found in it: no track task, no found rallies to confirm, no
    /// ball path to snap to.
    case byHandOnly(Why)
    /// Withheld, or not known not to be, for an ordinary labeler: nothing is offered (the server refuses the same
    /// once its list is current).
    case closed(Why)

    enum Why: Equatable, Sendable {
        case withheld
        /// No list could be read: none published for the project, or it could not be loaded.
        case unknown
    }

    /// `withheld`: whether the project's list names the recording; nil when that is not known. `byHand`: whether
    /// annotation by hand goes on for such a recording here — on the Mac (the project's own files, where a
    /// withheld recording gets its marks) and for a lead on the phone; not for an ordinary labeler.
    init(withheld: Bool?, byHand: Bool) {
        switch withheld {
        case false?: self = .open
        case true?: self = byHand ? .byHandOnly(.withheld) : .closed(.withheld)
        case nil: self = byHand ? .byHandOnly(.unknown) : .closed(.unknown)
        }
    }

    /// Why no task that runs a model over the recording, or offers what the pipeline found in it, may start; nil
    /// when one may.
    var modelRefusal: String? {
        switch self {
        case .open:
            return nil
        case .byHandOnly(.withheld), .closed(.withheld):
            return "This recording is withheld from every model: no detector is run over it, and no rallies or ball path the pipeline found in it are offered."
        case .byHandOnly(.unknown), .closed(.unknown):
            return "Whether this recording is withheld from the models is not known here: its project's withheld list is not published, "
                + "or could not be read. No detector is run over it until it can be."
        }
    }

    /// The marking pass (by hand) is offered.
    var offersMarking: Bool {
        if case .closed = self { return false }
        return true
    }
}

/// Model work and model output over a recording, across time. An admission is true of the moment it was given:
/// a detector runs for seconds over hundreds of frames and windows, a download or an upload takes as long, and
/// the withheld list can change under either. Two rules, each with its one way through:
///
/// - **Before every unit a model runs** — a frame, a heatmap window, a crop — the work asks again. The detectors
///   run off the main actor, so the answer is kept here where any thread can read it (`isOpen`,
///   `question(for:)`), set at every change of what the device knows (`set(open:)`). The finders take the
///   question as `whileAllowed` and stop themselves at the next unit.
/// - **What a model produced, or the server returned, across a suspension** is handed on only if the recording
///   is still open to it afterwards (`delivered`): a late result for a recording withheld meanwhile is dropped.
final class ModelLeave: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Set<UUID> = []

    /// The recordings no model is kept from, as the device knows now. Any other — withheld, not known, or never
    /// heard of — is not open.
    func set(open ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        open = ids
    }

    func isOpen(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return open.contains(id)
    }

    /// What model work over one recording asks before every unit it runs.
    func question(for id: UUID) -> @Sendable () -> Bool { { [self] in isOpen(id) } }

    /// `produce`'s result — a download, a computation — only if `allowed` held before it started and still holds
    /// once it is back; nil otherwise, and nothing is produced at all when it did not hold to begin with.
    @MainActor
    static func delivered<Output>(if allowed: () -> Bool, _ produce: () async throws -> Output) async rethrows -> Output? {
        guard allowed() else { return nil }
        let output = try await produce()
        return allowed() ? output : nil
    }

    /// `units` run in order, the question asked before each: the results, or nil from the moment the answer is no
    /// (the units left are not run, and what the earlier ones gave is not handed on).
    static func each<Unit, Result>(_ units: some Sequence<Unit>, whileAllowed allowed: () -> Bool, _ run: (Unit) -> Result) -> [Result]? {
        var results: [Result] = []
        for unit in units {
            guard allowed() else { return nil }
            results.append(run(unit))
        }
        return allowed() ? results : nil
    }
}

enum LabelQueue {

    enum Job: Hashable {
        /// Track this rally of the named video.
        case track(String, LabelRally)
        /// Mark every rally in the named video.
        case review(String)

        var video: String {
            switch self { case .track(let v, _), .review(let v): return v }
        }
    }

    /// A video as the queue sees it.
    struct Video {
        let plan: PlanVideo
        /// The next rally to track in it, if any.
        let nextRally: LabelRally?
        /// Rallies RallyLab found in it.
        let found: Int
        /// Rallies marked in it so far.
        let marked: Int
        /// Every rally in it is marked.
        let complete: Bool
        /// Set aside (the backlog): no job of either kind until it is put back.
        var backlog: Bool = false
        /// What the project's withheld list leaves open for it.
        var access: LabelAccess = .open
        /// Its camera group (the exporter's grouping, published by the Mac); nil when not known here.
        var group: String? = nil
        /// Seconds of footage, when known.
        var seconds: Double? = nil

        /// The group it counts toward: its own when none is known.
        var groupKey: String { group ?? plan.name }
        /// Too short to hold much unmarked time: marked after the longer recordings.
        var isShort: Bool { seconds.map { $0 < LabelQueue.shortClip } ?? false }

        /// A rally of it may be a track job: not set aside, and no model is kept from it.
        var offersTracking: Bool { !backlog && access == .open }
    }

    /// Track jobs between marking jobs.
    static let tracksPerReview = 3
    /// A recording shorter than this (seconds) is a short clip.
    static let shortClip = 60.0

    static func jobs(_ videos: [Video], round: TrainingPlan.Round?) -> [Job] {
        // A recording set aside, or one no model may run over, is no candidate for the plan either (its slot goes
        // to another recording), while its frames still count in the round's totals.
        let progress = PlanProgress(videos: videos.map { $0.offersTracking ? $0.plan : $0.plan.unavailable }, round: round)
        let byName = Dictionary(videos.map { ($0.plan.name, $0) }) { a, _ in a }
        var track: [Job] = progress.queue.compactMap { p in
            byName[p.name].flatMap { $0.offersTracking ? $0.nextRally.map { .track(p.name, $0) } : nil }
        }
        var review = markingJobs(videos)
        var out: [Job] = []
        while !track.isEmpty || !review.isEmpty {
            if !review.isEmpty { out.append(review.removeFirst()) }
            out += track.prefix(tracksPerReview)
            track.removeFirst(min(tracksPerReview, track.count))
        }
        return out
    }

    /// Why `job` may not be opened for a recording with this access, or nil: a track job runs the detectors over
    /// its rally, so it opens only for a recording no model is kept from; a marking job is by hand.
    static func refusal(of job: Job, access: LabelAccess) -> String? {
        switch job {
        case .track: return access.modelRefusal
        case .review: return access.offersMarking ? nil : "This recording is not open to labeling here."
        }
    }

    /// The marking jobs, in `markingOrder`.
    static func markingJobs(_ videos: [Video]) -> [Job] {
        markingOrder(videos).map { .review($0.plan.name) }
    }

    /// Every video not marked through, in the order to mark them: started ones first; then the recordings no
    /// model is kept from, the ones of a minute or more before the short clips; then the withheld ones (marking
    /// is by hand, so they stay jobs wherever marking is offered — they are scored on, never trained on). Within
    /// each of those, one surface at a time, the surface with the fewest marked videos leading, and in a surface
    /// a recording whose camera group has nothing marked or begun before one whose group has, then the most
    /// found rallies, then the longest. `playableOnly`: leave out the ones whose footage can't be played here.
    static func markingOrder(_ videos: [Video], playableOnly: Bool = true) -> [Video] {
        let open = videos.filter { (!playableOnly || $0.plan.available) && !$0.complete && !$0.backlog && $0.access.offersMarking }
        let started = open.filter { $0.marked > 0 }.sorted { ($0.marked, $0.found) > ($1.marked, $1.found) }
        let fresh = open.filter { $0.marked == 0 }
        var done = Dictionary(grouping: videos.filter(\.complete), by: \.plan.surface).mapValues(\.count)
        var covered = Set(videos.filter { $0.access == .open && ($0.complete || $0.marked > 0) }.map(\.groupKey))
        var ordered: [Video] = []

        func take(_ tier: [Video]) {
            var pool: [String: [Video]] = [:]
            for v in tier { pool[v.plan.surface, default: []].append(v) }
            for k in pool.keys { pool[k]!.sort { ($0.found, $0.seconds ?? 0) > ($1.found, $1.seconds ?? 0) } }
            // New camera groups first, then whatever is left.
            for newGroupsOnly in [true, false] {
                while true {
                    let ready = pool.filter { _, list in list.contains { !newGroupsOnly || !covered.contains($0.groupKey) } }
                    // The surface with the fewest marked videos, ties by name.
                    guard let surface = ready.keys.min(by: { (done[$0, default: 0], $0) < (done[$1, default: 0], $1) }) else { break }
                    let i = pool[surface]!.firstIndex { !newGroupsOnly || !covered.contains($0.groupKey) }!
                    let v = pool[surface]!.remove(at: i)
                    ordered.append(v)
                    covered.insert(v.groupKey)
                    done[surface, default: 0] += 1
                }
            }
        }
        take(fresh.filter { $0.access == .open && !$0.isShort })
        take(fresh.filter { $0.access == .open && $0.isShort })
        take(fresh.filter { $0.access != .open })
        return started + ordered
    }
}
