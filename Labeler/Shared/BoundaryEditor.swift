//
//  BoundaryEditor.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  The editing logic of the Rally Boundaries review (Stage 1, D-024), the same on both
//  platforms and kept apart from any window so it can be tested: a key press becomes an `Action`, an action
//  changes the draft rally, the spans, the coverage or the record through
//  `EventReview.Mutation`, and the record is written only on a commit. Nothing here
//  touches the player, the ledger or the legacy marks; nothing here writes a file.
//

import Foundation

/// The video's frame times, for stepping frame by frame on the original footage.
struct FrameClock: Equatable {
    /// Presentation times in seconds, ascending, from the video track's sample cursor.
    let times: [Double]
    let frameRate: Double

    init(times: [Double], frameRate: Double) {
        self.times = times
        self.frameRate = frameRate
    }

    var isEmpty: Bool { times.isEmpty }

    /// The index of the frame shown at `t`: the last frame starting at or before it (a hair of
    /// tolerance, since seconds round), or 0 before the first.
    func index(at t: Double) -> Int {
        guard !times.isEmpty else { return 0 }
        var lo = 0, hi = times.count - 1
        if t + 1e-6 < times[0] { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t + 1e-6 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The frame's start time, `count` frames from the one shown at `t`, clamped to the video.
    func step(from t: Double, by count: Int) -> Double {
        guard !times.isEmpty else { return max(0, t + Double(count) / max(frameRate, 1)) }
        let i = min(max(0, index(at: t) + count), times.count - 1)
        return times[i]
    }

    /// `m:ss.mmm · frame N` for the readout.
    func label(at t: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        let frame = times.isEmpty ? Int((t * frameRate).rounded(.down)) : index(at: t)
        return String(format: "%d:%06.3f · frame %d", m, s, frame)
    }
}

/// Where relative moves start from while a seek is in flight: the position last asked for, not the
/// frame the player still shows — so each arrow press advances one frame even when presses outrun seeks.
struct SeekClock: Equatable {
    private(set) var pending: Double?

    /// A seek to `t` was requested.
    mutating func request(_ t: Double) { pending = t }
    /// The player landed and no further seek is queued.
    mutating func settled() { pending = nil }
    /// The time a relative move counts from.
    func base(playerTime: Double) -> Double { pending ?? playerTime }
}

struct BoundaryEditor: Equatable {
    /// The rally being built or edited: the selected rally's copy, or a fresh one.
    struct Draft: Equatable {
        var rallyId: UUID?
        var kind: EventReview.RallyKind = .rally
        var contact: EventReview.EventTime?
        var dead: EventReview.EventTime?
        var edge: EventReview.Edge?
        var flags: [String] = []
        var legacyIndex: Int?
        var legacyStart: Double?
        var legacyEnd: Double?

        var isEmpty: Bool { contact == nil && dead == nil && edge == nil && flags.isEmpty }

        static func of(_ r: EventReview.Rally) -> Draft {
            Draft(rallyId: r.rallyId, kind: r.kind, contact: r.contact, dead: r.dead, edge: r.edge,
                  flags: r.flags.filter { $0 != "ambiguous_contact" && $0 != "ambiguous_dead" && $0 != "second_review_before_edit" },
                  legacyIndex: r.legacyIndex, legacyStart: r.legacyStart, legacyEnd: r.legacyEnd)
        }
    }

    enum Event: Equatable { case contact, dead }
    enum Bound: Equatable { case earliest, latest }

    enum Action: Equatable {
        /// `S` / `⇧S`, `D` / `⇧D`: one press sets both bounds; the shifted press widens to an interval.
        case mark(Event, Bound)
        case cycleKind                      // K
        case toggleOccluded                 // O: the last event marked
        case toggleFlag(String)             // A: `ambiguous` (the rubric's own flags are derived on commit)
        case cycleEdge                      // E: none → start → end → none
        case span(EventReview.SpanKind)     // N / T / U: start, then end, a span of that kind
        case reviewedThrough                // R: coverage from the last reviewed end (or 0) to here
        case commit                         // ⏎
        case complete                       // ⌘⏎
        case withdraw                       // ⌫ the selected rally
        case undo                           // Z
        case select(UUID?)
        case cancel                         // ⎋: drop the draft and an open span
    }

    /// The rally being edited changed on the other side while the draft was open: the draft's base and what
    /// arrived. Nothing is committed over it until the reviewer decides (keep mine, or take theirs).
    struct DraftConflict: Equatable {
        var base: EventReview.Rally
        var incoming: EventReview.Rally
    }

    struct Outcome: Equatable {
        var message: String
        /// The record changed: write it.
        var changed: Bool
        var refused: Bool = false
    }

    private(set) var file: EventReview.File
    private(set) var draft = Draft()
    private(set) var openSpan: (kind: EventReview.SpanKind, start: Double)?
    private(set) var selected: UUID?
    private(set) var lastMarked: Event?
    private(set) var draftConflict: DraftConflict?
    private var history: [EventReview.File] = []
    let annotator: String
    let tool: String
    /// How many records the undo stack keeps.
    static let undoDepth = 50

    static func == (a: BoundaryEditor, b: BoundaryEditor) -> Bool {
        a.file == b.file && a.draft == b.draft && a.selected == b.selected && a.openSpan?.kind == b.openSpan?.kind && a.openSpan?.start == b.openSpan?.start
    }

    init(file: EventReview.File, annotator: String, tool: String) {
        self.file = file
        self.annotator = annotator
        self.tool = tool
    }

    var canUndo: Bool { !history.isEmpty }

    /// A synchronised version of this record arrived (a push's reply or a pull): take it, keeping the draft and
    /// an open span — a draft is not in the record — and the selection when its rally still exists. Equal content
    /// only updates the revision bookkeeping. Returns whether the content changed.
    @discardableResult
    mutating func adopt(_ synced: EventReview.File) -> Bool {
        let changed = !RallyEventsSync.sameContent(file, synced)
        if changed { push() }
        let before = selectedRally
        file = synced
        // A selected rally that the other side withdrew (or that is gone) can no longer be edited: deselect it.
        guard let id = selected, let now = file.rallies.first(where: { $0.rallyId == id && $0.reviewState != .withdrawn }) else {
            if selected != nil { selected = nil; draft = Draft(); draftConflict = nil }
            return changed
        }
        // The rally under the draft changed on the other side: an untouched draft follows it; an edited draft
        // keeps its base and waits for the reviewer's decision — never committed over the newer version unseen.
        if let before, before != now, draft.rallyId == id {
            if draft == Draft.of(before) { draft = Draft.of(now) } else { draftConflict = DraftConflict(base: before, incoming: now) }
        }
        return changed
    }

    /// The reviewer decided a draft conflict: keep mine (the draft goes on over the incoming rally and the next
    /// commit replaces it, explicitly), or take theirs (the draft reloads from the incoming rally).
    mutating func resolveDraftConflict(keepMine: Bool) {
        guard let c = draftConflict else { return }
        if !keepMine { draft = Draft.of(c.incoming); lastMarked = c.incoming.dead != nil ? .dead : (c.incoming.contact != nil ? .contact : nil) }
        draftConflict = nil
    }

    /// The original's frame identity, recorded once (the next commit writes it); never overwritten.
    mutating func recordFrameTimesDigest(_ digest: String) {
        guard file.frameTimesDigest == nil else { return }
        file.frameTimesDigest = digest
    }
    var reviewedUntil: Double { EventReview.union(file.coverage).last?.end ?? 0 }

    /// Where "reviewed through `t`" starts: the beginning of the unknown stretch `t` is in — the end of
    /// the last reviewed interval before it, or 0 — so a gap between two reviewed stretches can be filled.
    /// nil when `t` already lies inside reviewed coverage.
    func unknownStart(before t: Double) -> Double? {
        var start = 0.0
        for r in EventReview.union(file.coverage) {
            // Inside a reviewed stretch — except at its very start, where "reviewed through here" closes the gap before it.
            if r.start + frame * 0.5 < t && t <= r.end + frame * 0.5 { return nil }
            if r.end <= t + frame * 0.5 { start = max(start, r.end) }
        }
        return start
    }
    var unknownGaps: [(start: Double, end: Double)] { EventReview.gaps(in: file) }
    var selectedRally: EventReview.Rally? { selected.flatMap { id in file.rallies.first { $0.rallyId == id } } }

    /// The reviewed rallies in order of their start (serve contact, else ball dead).
    var reviewedRallies: [EventReview.Rally] {
        file.rallies.filter { $0.reviewState == .reviewed }.sorted { Self.start(of: $0) < Self.start(of: $1) }
    }

    static func start(of r: EventReview.Rally) -> Double { r.contact?.earliest ?? r.dead?.earliest ?? .infinity }

    /// The reviewed rally starting after `t` (forward) or before it (backward); with one selected, the next
    /// or previous one in order, so repeated presses walk the recording.
    func adjacentRally(to t: Double, forward: Bool) -> UUID? {
        let ordered = reviewedRallies
        if let id = selected, let i = ordered.firstIndex(where: { $0.rallyId == id }) {
            let j = forward ? i + 1 : i - 1
            return ordered.indices.contains(j) ? ordered[j].rallyId : nil
        }
        return forward ? ordered.first { Self.start(of: $0) > t + 1e-9 }?.rallyId : ordered.last { Self.start(of: $0) < t - 1e-9 }?.rallyId
    }

    /// One frame of video time: events marked on one press are this wide at most.
    private var frame: Double { file.frameDuration }

    mutating func apply(_ action: Action, at t: Double, now: Date) -> Outcome {
        switch action {
        case .mark(let event, let bound):
            let existing = event == .contact ? draft.contact : draft.dead
            var e: EventReview.EventTime
            switch (existing, bound) {
            case (nil, _): e = EventReview.EventTime(earliest: t, latest: t)                      // one press: the frame itself
            case (let old?, .earliest): e = EventReview.EventTime(earliest: min(t, old.latest), latest: old.latest, visibility: old.visibility)
            case (let old?, .latest): e = EventReview.EventTime(earliest: min(old.earliest, t), latest: max(t, old.earliest), visibility: old.visibility)
            }
            if bound == .earliest, existing != nil, t > existing!.latest { e = EventReview.EventTime(earliest: t, latest: t, visibility: existing!.visibility) }
            if event == .contact { draft.contact = e } else { draft.dead = e }
            lastMarked = event
            let name = event == .contact ? "serve contact" : "ball dead"
            return Outcome(message: e.earliest == e.latest ? "\(name) at \(Self.clock(t))" : "\(name) between \(Self.clock(e.earliest)) and \(Self.clock(e.latest))" + (e.isAmbiguous ? " (ambiguous: wider than 0.2 s)" : ""), changed: false)
        case .cycleKind:
            draft.kind = draft.kind == .rally ? .missedServe : draft.kind == .missedServe ? .other : .rally
            return Outcome(message: "kind: \(draft.kind.rawValue)", changed: false)
        case .toggleOccluded:
            guard let last = lastMarked else { return Outcome(message: "mark an event first (S or D)", changed: false, refused: true) }
            func flip(_ e: inout EventReview.EventTime?) { let v = e?.visibility; e?.visibility = v == .occluded ? .clear : .occluded }
            if last == .contact { flip(&draft.contact) } else { flip(&draft.dead) }
            let v = (last == .contact ? draft.contact : draft.dead)?.visibility.rawValue ?? "?"
            return Outcome(message: "\(last == .contact ? "serve contact" : "ball dead"): \(v)", changed: false)
        case .toggleFlag(let flag):
            if let i = draft.flags.firstIndex(of: flag) { draft.flags.remove(at: i); return Outcome(message: "flag \(flag) off", changed: false) }
            draft.flags.append(flag)
            return Outcome(message: "flag \(flag)", changed: false)
        case .cycleEdge:
            draft.edge = draft.edge == nil ? .start : draft.edge == .start ? .end : nil
            return Outcome(message: draft.edge.map { "edge: the recording is cut at its \($0.rawValue)" } ?? "edge: none", changed: false)
        case .span(let kind):
            if let open = openSpan, open.kind == kind {
                guard t > open.start else { return Outcome(message: "a span ends after it starts", changed: false, refused: true) }
                let (s, e) = (open.start, t)
                let within = EventReview.covered(s, e, by: EventReview.union(file.coverage), tolerance: frame)
                guard within else { return Outcome(message: "mark the stretch reviewed first (R): a span lies inside reviewed coverage", changed: false, refused: true) }
                push()
                file.spans.append(EventReview.Span(id: UUID(), kind: kind, start: s, end: e, note: nil))
                openSpan = nil
                return Outcome(message: "\(kind.rawValue) \(Self.clock(s))–\(Self.clock(e))", changed: true)
            }
            openSpan = (kind, t)
            return Outcome(message: "\(kind.rawValue) from \(Self.clock(t)) — press the same key at its end", changed: false)
        case .reviewedThrough:
            guard let from = unknownStart(before: t) else { return Outcome(message: "\(Self.clock(t)) is reviewed already — move into an unknown stretch", changed: false, refused: true) }
            guard t > from + frame * 0.5 else { return Outcome(message: "move past \(Self.clock(from)) first", changed: false, refused: true) }
            push()
            EventReview.Mutation.markReviewed(from: from, to: t, in: &file, at: now, annotator: annotator)
            return Outcome(message: "reviewed through \(Self.clock(t)) (\(Int((EventReview.union(file.coverage).reduce(0) { $0 + $1.end - $1.start }) / file.durationSec * 100)) %)", changed: true)
        case .commit:
            if draftConflict != nil { return Outcome(message: "this rally changed on the other side while you were editing it: Keep mine or Take theirs first", changed: false, refused: true) }
            guard !draft.isEmpty || draft.rallyId != nil else { return Outcome(message: "nothing to commit: mark the serve contact (S) and the ball dead (D)", changed: false, refused: true) }
            if draft.kind != .other, draft.contact == nil, draft.edge != .start { return Outcome(message: "no serve contact: mark it (S) or an edge (E) when the recording starts after it", changed: false, refused: true) }
            if draft.kind != .other, draft.dead == nil, draft.edge != .end { return Outcome(message: "no ball dead: mark it (D) or an edge (E) when the recording ends before it", changed: false, refused: true) }
            if let c = draft.contact, let d = draft.dead, d.latest < c.earliest { return Outcome(message: "the rally ends before it starts", changed: false, refused: true) }
            push()
            let stamp = EventReview.stamp(now)
            var rally: EventReview.Rally
            if let id = draft.rallyId, let existing = file.rallies.first(where: { $0.rallyId == id }) {
                // An edit keeps everything the draft does not carry: the legacy link, the source method,
                // and the second review. A second review that predates a change of the events stays as
                // evidence and is flagged, never dropped.
                rally = existing
                var flags = draft.flags
                let predates = existing.flags.contains("second_review_before_edit")
                    || (existing.secondReview != nil && (existing.contact != draft.contact || existing.dead != draft.dead))
                if predates, !flags.contains("second_review_before_edit") { flags.append("second_review_before_edit") }
                rally.kind = draft.kind; rally.contact = draft.contact; rally.dead = draft.dead; rally.edge = draft.edge; rally.flags = flags
                rally.reviewState = .reviewed; rally.annotator = annotator; rally.reviewedAt = stamp
            } else {
                rally = EventReview.Rally(rallyId: UUID(), legacyIndex: draft.legacyIndex, legacyStart: draft.legacyStart, legacyEnd: draft.legacyEnd,
                                          kind: draft.kind, contact: draft.contact, dead: draft.dead, flags: draft.flags, edge: draft.edge,
                                          annotator: annotator, reviewedAt: stamp)
            }
            let id = EventReview.Mutation.upsert(rally, in: &file)
            let wasEdit = draft.rallyId != nil
            draft = Draft(); lastMarked = nil; selected = id
            return Outcome(message: wasEdit ? "rally updated" : "rally \(file.rallies.filter { $0.reviewState == .reviewed }.count) committed", changed: true)
        case .complete:
            var copy = file
            do { try EventReview.Mutation.complete(&copy, at: now, annotator: annotator, tool: tool) } catch let EventReview.Failure.incomplete(why) {
                return Outcome(message: "not complete: " + why.prefix(3).joined(separator: "; ") + (why.count > 3 ? "; …" : ""), changed: false, refused: true)
            } catch { return Outcome(message: error.localizedDescription, changed: false, refused: true) }
            push()
            file = copy
            return Outcome(message: "recording fully reviewed", changed: true)
        case .withdraw:
            guard let id = selected, file.rallies.contains(where: { $0.rallyId == id && $0.reviewState == .reviewed }) else { return Outcome(message: "select a rally to withdraw", changed: false, refused: true) }
            push()
            _ = EventReview.Mutation.withdraw(id, in: &file, at: now, annotator: annotator)
            draft = Draft(); selected = nil
            return Outcome(message: "rally withdrawn (kept on record)", changed: true)
        case .undo:
            guard var previous = history.popLast() else { return Outcome(message: "nothing to undo", changed: false, refused: true) }
            // The revision is sync bookkeeping, not content: an undo restores the content at the revision the
            // record has now, so the next sync pushes it as a change, never as a stale copy.
            previous.revision = file.revision
            previous.frameTimesDigest = file.frameTimesDigest ?? previous.frameTimesDigest
            file = previous
            draft = Draft(); openSpan = nil; selected = nil
            return Outcome(message: "undone", changed: true)
        case .select(let id):
            selected = id
            if draft.rallyId != id { draftConflict = nil }
            if let r = selectedRally {
                // The draft already holds this rally's edits: keep them. Otherwise load the rally (also right
                // after a commit, which leaves the rally selected but the draft empty).
                if draft.rallyId != r.rallyId { draft = Draft.of(r); lastMarked = r.dead != nil ? .dead : (r.contact != nil ? .contact : nil) }
            } else { draft = Draft() }
            return Outcome(message: selectedRally.map { "editing rally \($0.rallyId.uuidString.prefix(8))" } ?? "", changed: false)
        case .cancel:
            draft = Draft(); openSpan = nil; selected = nil; lastMarked = nil; draftConflict = nil
            return Outcome(message: "cancelled", changed: false)
        }
    }

    private mutating func push() {
        history.append(file)
        if history.count > Self.undoDepth { history.removeFirst() }
    }

    static func clock(_ t: Double) -> String {
        let m = Int(t) / 60
        return String(format: "%d:%06.3f", m, t - Double(m * 60))
    }
}
