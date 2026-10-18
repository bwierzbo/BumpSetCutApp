//
//  LiveTagger.swift
//  RallyLab (macOS and iPhone)
//
//  Live tagging's state and rules, the same on the Mac and the phone: a
//  serve opens a rally, touches go into it, a dead ball closes it as a
//  rally, "not a rally" closes it as a missed serve (nothing after the
//  serve) or other. Each press is backed up for the reaction it took and
//  snapped to the nearest moment the pre-tracked ball changed course; its
//  side of the net read from the ball's size against the net unless the
//  press says. Undo takes back the last press, reopening a closed rally.
//
//  Where the marks go is the platform's (LiveTagStore): the Mac's rally
//  marks and project sessions, the phone's rally times and tracks.
//

import AVFoundation
import CoreGraphics
import Foundation

/// Where a live tagger's rallies are kept.
@MainActor
protocol LiveTagStore: AnyObject {
    /// Save a rally; the handle is what `delete` takes.
    func mark(start: Double, end: Double, kind: RallyKind, contacts: [RallyContact]) -> AnyHashable
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
        /// The side the presser said, when they did.
        var side: NetSide? = nil
    }

    /// A rally closed this sitting, with what confirming it changed.
    struct Closed {
        let mark: AnyHashable
        let start: Double
        let end: Double
        let kind: RallyKind
        let contacts: [RallyContact]
        let before: [TrackedRally]
    }

    /// The rally being tagged: its touches so far, the serve first.
    private(set) var open: [RallyContact]?
    /// Rallies closed this sitting, newest last — for undo.
    private(set) var closed: [Closed] = []
    var path: BallPath
    var net: CGRect?
    private(set) var lastEvent = ""
    private(set) var lastEventAt = Date.distantPast

    private let store: any LiveTagStore

    /// Seconds of real time between seeing an event and pressing its key.
    static let reaction = 0.25

    init(tracks: [TrackedRally], net: CGRect?, store: any LiveTagStore) {
        path = BallPath(tracks: tracks)
        self.net = net
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
    /// it closes first, a little before this serve.
    func serve(_ p: Press) {
        if let open {
            let serveAt = moment(p, snapping: path.changes + path.starts)
            let end = max(open[0].time + 0.5, min(serveAt - 0.3, (open.last?.time ?? serveAt) + 1.5))
            close(as: .rally, at: end)
            note("Closed the last rally at \(clockText(end))")
        }
        let t = moment(p, snapping: path.changes + path.starts)
        let c = RallyContact(time: t, kind: .serve, side: side(at: t, .serve, said: p.side))
        open = [c]
        note("Serve at \(clockText(t))", c.side)
    }

    /// P T A B F: a touch in the open rally.
    func touch(_ kind: ContactKind, _ p: Press) {
        guard kind != .serve else { serve(p); return }
        guard var contacts = open else { note("Press S at the serve first"); return }
        let t = moment(p, snapping: path.changes)
        guard t > contacts[0].time else { note("That's before the serve"); return }
        let c = RallyContact(time: t, kind: kind, side: side(at: t, kind, said: p.side))
        contacts.append(c)
        contacts.sort { $0.time < $1.time }
        open = contacts
        note("\(kind.name) at \(clockText(t))", c.side)
    }

    /// D (`.rally`) or N (nil): the open rally ends here — as a rally, or
    /// as not one: a missed serve when nothing followed the serve, else other.
    func close(as kind: RallyKind?, _ p: Press) {
        guard let contacts = open else { note("No rally open — S starts one"); return }
        let end = moment(p, snapping: path.changes + path.ends)
        guard end > contacts[0].time + 0.2 else { note("The dead ball has to come after the serve"); return }
        let k = kind ?? (contacts.count == 1 ? RallyKind.missedServe : .other)
        close(as: k, at: end)
        note("\(k.name) · \(clockText(contacts[0].time)) – \(clockText(end))")
    }

    private func close(as kind: RallyKind, at end: Double) {
        guard let contacts = open else { return }
        let before = store.confirmPretracked(start: contacts[0].time, end: end)
        let mark = store.mark(start: contacts[0].time, end: end, kind: kind, contacts: contacts)
        closed.append(Closed(mark: mark, start: contacts[0].time, end: end, kind: kind, contacts: contacts, before: before))
        open = nil
    }

    /// Z: the last press — a touch, the serve (the rally is dropped), or
    /// the dead ball (the rally reopens as it was).
    func undo() {
        if var contacts = open {
            if contacts.count > 1 {
                let gone = contacts.removeLast()
                open = contacts
                note("Took back the \(gone.kind.name.lowercased())")
            } else {
                open = nil
                note("Serve taken back")
            }
            return
        }
        guard let last = closed.popLast() else { note("Nothing to take back"); return }
        store.delete(last.mark)
        store.restore(last.before)
        open = last.contacts.isEmpty ? [RallyContact(time: last.start, kind: .serve, side: nil)] : last.contacts
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

    private func side(at t: Double, _ kind: ContactKind, said: NetSide?) -> NetSide? {
        if let said { return said }
        // A block is at the net, on the other side from the attack it met.
        if kind == .block, let attack = open?.last(where: { $0.kind == .attack }), let s = attack.side { return s.flipped }
        return path.side(at: t, net: net)
    }

    private func note(_ text: String, _ side: NetSide? = nil) {
        lastEvent = text + (side.map { " · \($0 == .near ? "near" : "far") side" } ?? "")
        lastEventAt = Date()
    }

    // MARK: - The net

    /// The net, once per video: the median box over frames spread through
    /// it. A review copy or the phone's clip does — the net is big.
    nonisolated static func findNet(in url: URL) async -> TrackCandidate? {
        await Task.detached(priority: .userInitiated) { () -> TrackCandidate? in
            let detector = NetDetector()
            guard detector.isLoaded else { return nil }
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            var boxes: [(rect: CGRect, confidence: Float)] = []
            for i in 0..<7 {
                let t = CMTime(seconds: (0.1 + 0.8 * Double(i) / 6) * duration, preferredTimescale: 600)
                guard let image = try? await generator.image(at: t).image, let best = detector.detect(in: image).first else { continue }
                boxes.append(best)
            }
            guard boxes.count >= 2 else { return nil }
            func median(_ v: [CGFloat]) -> CGFloat { let s = v.sorted(); return s[s.count / 2] }
            let rect = CGRect(x: median(boxes.map(\.rect.minX)), y: median(boxes.map(\.rect.minY)),
                              width: median(boxes.map(\.rect.width)), height: median(boxes.map(\.rect.height)))
            return TrackCandidate(rect: rect, confidence: Double(median(boxes.map { CGFloat($0.confidence) })))
        }.value
    }
}
