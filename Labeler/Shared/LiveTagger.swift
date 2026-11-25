//
//  LiveTagger.swift
//  RallyLab (macOS and iPhone)
//
//  Live tagging's state and rules, the same on the Mac and the phone: a
//  serve opens a rally; a dead ball closes it as a rally, "missed serve"
//  closes it as one (a serve nothing followed: an excluded span for scoring
//  and training, like the "not a rally" kind the keys no longer offer —
//  owner, 2026-11-04). Each press is backed up for
//  the reaction it took and snapped to the nearest moment the pre-tracked
//  ball changed course, appeared or went dead. Undo takes back the last
//  press, reopening a closed rally.
//
//  A cut (X) marks a stretch that is not footage — an instant replay the
//  uploader put in — from one press to the next; ⇧X starts one at the
//  clip's start, for a clip that begins in the middle of a rally, and the
//  next serve ends it. Marks mostly inside a cut are removed with it (and
//  come back with undo); everything that reads the recording keeps away
//  from a cut (D-030).
//
//  The touches inside a rally (pass, set, attack, block, free ball) and
//  which side of the net each was on are advanced marking, left out of
//  this pass (D-028, D-024 Stage 2). The stored format keeps them
//  (RallyContact) for the rallies marked with them before.
//
//  Where the marks go is the platform's (LiveTagStore): the Mac's rally
//  marks and project sessions, the phone's rally times and tracks.
//

import Foundation

/// Where a live tagger's rallies and cuts are kept.
@MainActor
protocol LiveTagStore: AnyObject {
    /// Save a rally; the handle is what `delete` takes.
    func mark(start: Double, end: Double, kind: RallyKind) -> AnyHashable
    func delete(_ mark: AnyHashable)
    /// The pre-tracked rallies mostly inside the mark follow its kind: a rally
    /// confirms them, trimmed to it; a missed serve or a "not a rally" turns
    /// them down as they are (RallyTruth.pretrackedChanges). Returns them as
    /// they were.
    func confirmPretracked(start: Double, end: Double, kind: RallyKind) -> [TrackedRally]
    /// Pre-tracked rallies back as they were.
    func restore(_ rallies: [TrackedRally])
    /// The rallies marked so far that overlap `start ..< end`.
    func marks(overlapping start: Double, _ end: Double) -> [LiveTagger.ExistingMark]
    /// A deleted mark back as it was; the handle is what `delete` takes.
    func restoreMark(_ mark: LiveTagger.ExistingMark) -> AnyHashable
    /// Save a cut range (D-030); the handle is what `uncut` takes.
    func cut(start: Double, end: Double) -> AnyHashable
    func uncut(_ cut: AnyHashable)
}

@MainActor @Observable
final class LiveTagger {
    /// One press: where the player was, and whether it was running.
    struct Press {
        var now: Double
        var playing: Bool
        var rate: Float
    }

    /// A rally closed this sitting, with what confirming it changed.
    struct Closed {
        /// The store's handle — replaced when a cut took the mark and undo put it back under a new one.
        var mark: AnyHashable
        let start: Double
        let end: Double
        let kind: RallyKind
        let before: [TrackedRally]
    }

    /// A mark as the store has it, so a cut can take it and undo put it back.
    struct ExistingMark: Hashable {
        var handle: AnyHashable
        var start: Double
        var end: Double
        var kind: RallyKind?
        var contacts: [RallyContact]?
    }

    /// A cut made this sitting, with the marks it took.
    struct CutMade {
        let handle: AnyHashable
        let start: Double
        let end: Double
        let removed: [ExistingMark]
    }

    enum Undoable {
        case rally(Closed)
        case cut(CutMade)
    }

    /// The serve of the rally being tagged, while one is open.
    private(set) var open: Double?
    /// Where the cut being made starts, while one is open.
    private(set) var cutFrom: Double?
    /// Rallies closed and cuts made this sitting, newest last — for undo.
    private(set) var done: [Undoable] = []
    var path: BallPath
    private(set) var lastEvent = ""
    private(set) var lastEventAt = Date.distantPast

    private let store: any LiveTagStore

    /// Seconds of real time between seeing an event and pressing its key.
    static let reaction = 0.25
    /// A cut shorter than this is a slip, not a stretch of footage.
    static let minimumCut = 0.5
    /// How long before a serve a cut it ends is closed.
    static let cutBeforeServe = 0.3

    init(tracks: [TrackedRally], store: any LiveTagStore) {
        path = BallPath(tracks: tracks)
        self.store = store
    }

    /// The last press's note, while it's fresh.
    var recentNote: String? {
        !lastEvent.isEmpty && Date().timeIntervalSince(lastEventAt) < 2.5 ? lastEvent : nil
    }

    // MARK: - Presses

    /// The moment a press was about: backed up for the reaction while
    /// playing (paused, the frame it's on), then snapped to `moments`.
    func moment(_ p: Press, snapping moments: [Double]) -> Double {
        let t = p.playing ? p.now - Self.reaction * Double(p.rate) : p.now
        return BallPath.snap(max(0, t), to: moments)
    }

    /// S: a rally starts. With one open, its dead ball went by unpressed:
    /// it closes first, where the ball's path last ended between its serve
    /// and this one, else a little before this serve. With a cut open, the
    /// cut ends a little before this serve.
    func serve(_ p: Press) {
        let t = moment(p, snapping: path.changes + path.starts)
        var closedAt: Double?
        var cutEnd: Double?
        if let from = cutFrom {
            let end = t - Self.cutBeforeServe
            guard end >= from + Self.minimumCut else { note("The serve has to come at least a second after the cut started"); return }
            closeCut(at: end)
            cutEnd = end
        }
        if let open {
            let end = path.ends.last { $0 > open + 0.5 && $0 <= t - 0.3 } ?? max(open + 0.5, t - 0.3)
            close(as: .rally, at: end)
            closedAt = end
        }
        open = t
        note("Serve at \(clockText(t))" + (closedAt.map { " · the last rally closed at \(clockText($0))" } ?? "")
             + (cutEnd.map { " · the cut ended at \(clockText($0))" } ?? ""))
    }

    /// D or M: the open rally ends here — as a rally, or a missed serve. (`.other`
    /// is kept for the marks that have it; no key makes one any more.)
    func close(as kind: RallyKind, _ p: Press) {
        guard cutFrom == nil else { note("Cut open — X ends it, or S at the next serve"); return }
        guard let open else { note("No rally open — S starts one"); return }
        let end = moment(p, snapping: path.changes + path.ends)
        guard end > open + 0.2 else { note("The dead ball has to come after the serve"); return }
        close(as: kind, at: end)
        note("\(kind.name) · \(clockText(open)) – \(clockText(end))")
    }

    private func close(as kind: RallyKind, at end: Double) {
        guard let open else { return }
        let before = store.confirmPretracked(start: open, end: end, kind: kind)
        let mark = store.mark(start: open, end: end, kind: kind)
        done.append(.rally(Closed(mark: mark, start: open, end: end, kind: kind, before: before)))
        self.open = nil
    }

    // MARK: - Cuts (D-030)

    /// X: a cut starts here — or the open one ends here.
    func cut(_ p: Press) {
        let t = moment(p, snapping: [])
        if let from = cutFrom {
            guard t >= from + Self.minimumCut else { note("A cut has to be at least half a second"); return }
            closeCut(at: t)
            note("Cut \(clockText(from)) – \(clockText(t)) · not footage")
            return
        }
        guard open == nil else { note("Close the rally first (D or M) — a cut can't start inside one"); return }
        cutFrom = t
        note("Cut from \(clockText(t)) · X to end it, or S at the next serve")
    }

    /// ⇧X: the clip starts in the middle of a rally — a cut from its start,
    /// which the next serve ends.
    func cutFromStart() {
        guard open == nil else { note("Close the rally first (D or M)"); return }
        guard cutFrom == nil else { note("A cut is open already — X ends it"); return }
        cutFrom = 0
        note("Cut from the start · S at the next serve ends it")
    }

    /// "That's every rally" with a cut open: the rest of the recording is not
    /// footage — the cut ends where the recording does (`duration`). One
    /// opened within half a second of the end is a slip and is dropped.
    func finishCut(atEnd duration: Double) {
        guard let from = cutFrom else { return }
        guard duration >= from + Self.minimumCut else { cutFrom = nil; note("Cut dropped — it started at the very end"); return }
        closeCut(at: duration)
        note("Cut \(clockText(from)) – the end · not footage")
    }

    /// Marks mostly inside the cut go with it (undo brings them back); one
    /// that only brushes it stays, and is read outside the cut.
    private func closeCut(at end: Double) {
        guard let from = cutFrom else { return }
        let removed = store.marks(overlapping: from, end).filter { Swift.min($0.end, end) - Swift.max($0.start, from) > 0.5 * ($0.end - $0.start) }
        for m in removed { store.delete(m.handle) }
        let handle = store.cut(start: from, end: end)
        done.append(.cut(CutMade(handle: handle, start: from, end: end, removed: removed)))
        cutFrom = nil
    }

    // MARK: - Undo

    /// Z: the last press — the start of a cut or the serve (dropped), or the
    /// end of a cut or the close of a rally (it reopens as it was).
    func undo() {
        if cutFrom != nil {
            cutFrom = nil
            note("Cut taken back")
            return
        }
        if open != nil {
            open = nil
            note("Serve taken back")
            return
        }
        guard let last = done.popLast() else { note("Nothing to take back"); return }
        switch last {
        case .rally(let r):
            store.delete(r.mark)
            store.restore(r.before)
            open = r.start
            note("Reopened the rally at \(clockText(r.start))")
        case .cut(let c):
            store.uncut(c.handle)
            // A restored mark may come back under a new handle (the Mac mints a fresh id): the
            // rally entries still in the history must point at it, or a later undo misses the mark.
            for m in c.removed {
                let handle = store.restoreMark(m)
                guard handle != m.handle else { continue }
                for i in done.indices {
                    if case .rally(var r) = done[i], r.mark == m.handle { r.mark = handle; done[i] = .rally(r) }
                }
            }
            cutFrom = c.start
            note("Reopened the cut from \(clockText(c.start))" + (c.removed.isEmpty ? "" : " · \(c.removed.count) rall\(c.removed.count == 1 ? "y" : "ies") back"))
        }
    }

    /// Esc: drop the open cut, else the open rally. False when neither was.
    @discardableResult
    func cancel() -> Bool {
        if cutFrom != nil {
            cutFrom = nil
            note("Cut cancelled")
            return true
        }
        guard open != nil else { return false }
        open = nil
        note("Rally cancelled")
        return true
    }

    private func note(_ text: String) {
        lastEvent = text
        lastEventAt = Date()
    }
}
