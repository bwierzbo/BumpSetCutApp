//
//  LiveTagger.swift
//  RallyLab (macOS and iPhone)
//
//  Live tagging's state and rules, the same on the Mac and the phone: a
//  serve opens a rally; a dead ball closes it as a rally, "missed serve"
//  or "not a rally" close it as one of those. Each press is backed up for
//  the reaction it took and snapped to the nearest moment the pre-tracked
//  ball changed course, appeared or went dead. Undo takes back the last
//  press, reopening a closed rally.
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

/// Where a live tagger's rallies are kept.
@MainActor
protocol LiveTagStore: AnyObject {
    /// Save a rally; the handle is what `delete` takes.
    func mark(start: Double, end: Double, kind: RallyKind) -> AnyHashable
    func delete(_ mark: AnyHashable)
    /// Pre-tracked rallies mostly inside the marked one are rallies, trimmed
    /// to it. Returns them as they were.
    func confirmPretracked(start: Double, end: Double) -> [TrackedRally]
    /// Pre-tracked rallies back as they were.
    func restore(_ rallies: [TrackedRally])
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
        let mark: AnyHashable
        let start: Double
        let end: Double
        let kind: RallyKind
        let before: [TrackedRally]
    }

    /// The serve of the rally being tagged, while one is open.
    private(set) var open: Double?
    /// Rallies closed this sitting, newest last — for undo.
    private(set) var closed: [Closed] = []
    var path: BallPath
    private(set) var lastEvent = ""
    private(set) var lastEventAt = Date.distantPast

    private let store: any LiveTagStore

    /// Seconds of real time between seeing an event and pressing its key.
    static let reaction = 0.25

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
    /// and this one, else a little before this serve.
    func serve(_ p: Press) {
        let t = moment(p, snapping: path.changes + path.starts)
        var closedAt: Double?
        if let open {
            let end = path.ends.last { $0 > open + 0.5 && $0 <= t - 0.3 } ?? max(open + 0.5, t - 0.3)
            close(as: .rally, at: end)
            closedAt = end
        }
        open = t
        note("Serve at \(clockText(t))" + (closedAt.map { " · the last rally closed at \(clockText($0))" } ?? ""))
    }

    /// D, M or N: the open rally ends here — as a rally, a missed serve, or
    /// something that wasn't a rally.
    func close(as kind: RallyKind, _ p: Press) {
        guard let open else { note("No rally open — S starts one"); return }
        let end = moment(p, snapping: path.changes + path.ends)
        guard end > open + 0.2 else { note("The dead ball has to come after the serve"); return }
        close(as: kind, at: end)
        note("\(kind.name) · \(clockText(open)) – \(clockText(end))")
    }

    private func close(as kind: RallyKind, at end: Double) {
        guard let open else { return }
        let before = store.confirmPretracked(start: open, end: end)
        let mark = store.mark(start: open, end: end, kind: kind)
        closed.append(Closed(mark: mark, start: open, end: end, kind: kind, before: before))
        self.open = nil
    }

    /// Z: the last press — the serve (the rally is dropped), or the close
    /// (the rally reopens as it was).
    func undo() {
        if open != nil {
            open = nil
            note("Serve taken back")
            return
        }
        guard let last = closed.popLast() else { note("Nothing to take back"); return }
        store.delete(last.mark)
        store.restore(last.before)
        open = last.start
        note("Reopened the rally at \(clockText(last.start))")
    }

    /// Esc: drop the open rally. False when none was.
    @discardableResult
    func cancel() -> Bool {
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
