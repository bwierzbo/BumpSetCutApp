//
//  LiveTagView.swift
//  RallyLab
//
//  Mark every rally in a video in one pass, live: watch at 1–4× and press
//  one key per event as it happens. S at the serve starts a rally; P pass,
//  T set, A attack, B block, F free ball tag its touches; D at the dead
//  ball ends it. N ends it as not a rally (a missed serve when nothing
//  followed the serve). Each press is backed up for your reaction and
//  snapped to the nearest moment the tracked ball changed course, and its
//  side of the net read from the ball's size against the net (⇧ far, ⌥
//  near when it's wrong). Z takes back the last press.
//
//  Pre-tracked rallies inside a rally you mark are confirmed and trimmed to
//  it; "That's every rally" turns down the ones you never marked, drops
//  the found rallies you passed over, and marks the video finished, so it
//  counts in rally scoring and the decision model's training.
//

import AVFoundation
import SwiftUI

struct LiveTagView: View {
    let session: VideoSession
    @Bindable var marker: RallyMarkModel
    let review: ProjectReviewStore
    let isActive: Bool
    let onClose: () -> Void
    let onDone: () -> Void

    /// The rally being tagged: its touches so far, the serve first.
    @State private var open: [RallyContact]?
    /// Rallies closed this sitting, newest last, with the pre-tracked
    /// rallies as they were before the mark confirmed them — for Z.
    @State private var closed: [(mark: RallyMarkModel.Mark, before: [TrackedRally])] = []
    @State private var path = BallPath(tracks: [])
    @State private var net: CGRect?
    @State private var findingNet = false
    @State private var lastEvent = ""
    @State private var lastEventAt = Date.distantPast
    @State private var speed: Float = 2

    /// Seconds of real time between seeing an event and pressing its key.
    private static let reaction = 0.25
    private static let speeds: [Float] = [1, 2, 3, 4]

    var body: some View {
        VStack(spacing: 0) {
            LabelTaskHeader(title: "Mark the rallies", subtitle: session.name, onClose: onClose) {
                Picker("Speed", selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Playback speed (1–4)")
                Text("\(marker.rallies.count) marked").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            if marker.footageMissing {
                FootageMissingView(session: session, datasetRoot: marker.sampler.datasetRoot,
                                   reason: "It has no review copy here either.") { marker.reopen() }
            } else {
                HStack(spacing: 0) {
                    stage
                    Divider()
                    rallies
                }
            }
        }
        .onAppear {
            marker.open(sessionName: session.name)
            marker.rate = speed
            path = BallPath(tracks: session.tracks ?? [])
            net = session.netBox?.rect
        }
        .task { await findNet() }
        .onDisappear { if marker.isPlaying { marker.togglePlay() } }
        .onChange(of: speed) { _, s in marker.rate = s }
        .onChange(of: marker.playhead) { _, t in
            if marker.isPlaying, marker.duration > 0, t >= marker.duration - 0.05 { marker.togglePlay() }
        }
        .labelKeys(isActive: isActive, handleKey)
    }

    // MARK: - The picture and the live state

    private var stage: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                ReviewStyle.stage
                if let player = marker.player { LabPlayerView(player: player, showsControls: false) }
                state.padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            RallyTimesBar(time: marker.playhead, duration: marker.duration, found: marker.guesses.map { [$0.start, $0.end] },
                          marked: marker.rallies.map { LabelRally(start: $0.start, end: $0.end) },
                          current: nil, pending: open?.first?.time,
                          ticks: (open ?? marker.rallies.first { $0.contains(marker.playhead) }?.contacts ?? []).map(\.time))
                .frame(height: 22)
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                marker.seek(to: tap.location.x / max(geo.size.width, 1) * marker.duration)
                            })
                    }
                }
            controls
        }
        .padding(16)
    }

    /// Dead or in a rally, the touches so far, and the last press.
    private var state: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let open {
                    Circle().fill(.orange).frame(width: 9, height: 9)
                    Text("Rally · \(TrackLabelModel.clock(open[0].time)) · \(open.count) \(open.count == 1 ? "touch" : "touches")")
                } else {
                    Circle().fill(.secondary).frame(width: 9, height: 9)
                    Text("Dead ball · S at the serve")
                }
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            if let open {
                HStack(spacing: 6) {
                    ForEach(Array(open.enumerated()), id: \.offset) { _, c in chip(c) }
                }
            }
            if !lastEvent.isEmpty, Date().timeIntervalSince(lastEventAt) < 2.5 {
                Text(lastEvent).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }

    private func chip(_ c: RallyContact) -> some View {
        Text(c.kind.name + (c.side.map { " · \($0 == .near ? "near" : "far")" } ?? ""))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.kind == .serve ? Color.orange.opacity(0.35) : Color.white.opacity(0.15), in: Capsule())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                key("S", "Serve", .orange) { event(.serve) }
                key("P", "Pass") { event(.pass) }
                key("T", "Set") { event(.set) }
                key("A", "Attack") { event(.attack) }
                key("B", "Block") { event(.block) }
                key("F", "Free ball") { event(.freeBall) }
                Divider().frame(height: 24)
                key("D", "Dead ball", .green) { close(as: .rally) }
                key("N", "Not a rally", .red) { close(as: nil) }
            }
            .controlSize(.large)
            HStack(spacing: 14) {
                Button { marker.togglePlay() } label: { Image(systemName: marker.isPlaying ? "pause.fill" : "play.fill") }
                    .help("Play / pause (Space)")
                Text(TrackLabelModel.clock(marker.playhead)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if findingNet { ProgressView().controlSize(.mini); Text("Finding the net…").font(.caption).foregroundStyle(.secondary) }
                else if net == nil { Text("No net found · sides are up to ⇧ far and ⌥ near").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("⇧ far · ⌥ near · Z takes back a press · ←/→ 2 s · ⌫ removes the rally here")
                    .font(.caption).foregroundStyle(.secondary)
                Button { finish() } label: { Label("That's every rally", systemImage: "flag.checkered") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(open != nil)
                    .help("Every rally is marked — the video then counts in rally scoring (⌘↩)")
            }
            .buttonStyle(.borderless)
        }
    }

    private func key(_ k: String, _ name: String, _ tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(k).font(.headline)
                Text(name).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .buttonStyle(.bordered)
    }

    // MARK: - The marked rallies

    private var rallies: some View {
        List(selection: $marker.selectedId) {
            ForEach(marker.rallies) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.kind == .rally ? "figure.volleyball" : r.kind == .missedServe ? "xmark.circle" : "minus.circle")
                        .foregroundStyle(r.kind == .rally ? Color.orange : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(TrackLabelModel.clock(r.start)) – \(TrackLabelModel.clock(r.end))").font(.callout.monospacedDigit())
                        Text(r.kind == .rally ? (r.contacts.isEmpty ? String(format: "%.1f s", r.end - r.start)
                                                    : "\(r.contacts.count) touches") : r.kind.name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(r.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { play(from: r.start - 1) }
                .contextMenu {
                    Button("Play from here") { play(from: r.start - 1) }
                    Button("Remove", role: .destructive) { marker.delete(r.id) }
                }
            }
        }
        .listStyle(.inset)
        .frame(width: 230)
        .overlay {
            if marker.rallies.isEmpty {
                Text("Rallies you mark show here.\nDouble-click one to watch it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }

    // MARK: - Events

    /// The moment a press was about: backed up for your reaction while
    /// playing (paused, the frame you're on), then snapped to `moments`.
    private func moment(snapping moments: [Double]) -> Double {
        let t = marker.isPlaying ? marker.now - Self.reaction * Double(marker.rate) : marker.now
        return BallPath.snap(max(0, t), to: moments)
    }

    private func side(at t: Double, _ kind: ContactKind, flags: NSEvent.ModifierFlags) -> NetSide? {
        if flags.contains(.shift) { return .far }
        if flags.contains(.option) { return .near }
        // A block is at the net, on the other side from the attack it met.
        if kind == .block, let attack = open?.last(where: { $0.kind == .attack }), let s = attack.side { return s.flipped }
        return path.side(at: t, net: net)
    }

    private func event(_ kind: ContactKind, flags: NSEvent.ModifierFlags = []) {
        if kind == .serve {
            if let open {
                // A serve while a rally is open: its dead ball went by unpressed.
                let serveAt = moment(snapping: path.changes + path.starts)
                let end = max(open[0].time + 0.5, min(serveAt - 0.3, (open.last?.time ?? serveAt) + 1.5))
                close(as: .rally, at: end)
                note("Closed the last rally at \(TrackLabelModel.clock(end))")
            }
            let t = moment(snapping: path.changes + path.starts)
            open = [RallyContact(time: t, kind: .serve, side: side(at: t, .serve, flags: flags))]
            note("Serve at \(TrackLabelModel.clock(t))", open?[0].side)
            return
        }
        guard open != nil else { note("Press S at the serve first"); return }
        let t = moment(snapping: path.changes)
        guard t > open![0].time else { note("That's before the serve"); return }
        let c = RallyContact(time: t, kind: kind, side: side(at: t, kind, flags: flags))
        open!.append(c)
        open!.sort { $0.time < $1.time }
        note("\(kind.name) at \(TrackLabelModel.clock(t))", c.side)
    }

    /// D or N: the open rally ends here — as a rally, or (nil) as not one:
    /// a missed serve when nothing followed the serve, else "other".
    private func close(as kind: RallyKind?, at time: Double? = nil) {
        guard let contacts = open else { note("No rally open — S starts one"); return }
        let end = time ?? moment(snapping: path.changes + path.ends)
        guard end > contacts[0].time + 0.2 else { note("The dead ball has to come after the serve"); return }
        let kind = kind ?? (contacts.count == 1 ? RallyKind.missedServe : .other)
        let before = confirmPretracked(start: contacts[0].time, end: end)
        let mark = marker.mark(start: contacts[0].time, end: end, kind: kind, contacts: contacts)
        closed.append((mark, before))
        open = nil
        if time == nil { note("\(kind.name) · \(TrackLabelModel.clock(contacts[0].time)) – \(TrackLabelModel.clock(end))") }
    }

    /// Pre-tracked rallies mostly inside the marked one are rallies, trimmed
    /// to it. Returns them as they were.
    private func confirmPretracked(start: Double, end: Double) -> [TrackedRally] {
        var before: [TrackedRally] = []
        for t in session.tracks ?? [] where t.isMachine && min(t.end, end) - max(t.start, start) > 0.5 * (t.end - t.start) {
            before.append(t)
            let check = AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end)
            review.replace(check, with: t.trimmed(start: start, end: end))
            review.setIsRally(true, check)
        }
        return before
    }

    /// Z: the last press — a touch, the serve (the rally is dropped), or the
    /// dead ball (the rally reopens as it was).
    private func undo() {
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
        marker.delete(last.mark.id)
        for t in last.before {
            let check = AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end)
            review.replace(check, with: t)
            review.setIsRally(t.isRally, check)
        }
        open = last.mark.contacts.isEmpty ? [RallyContact(time: last.mark.start, kind: .serve, side: nil)] : last.mark.contacts
        note("Reopened the rally at \(TrackLabelModel.clock(last.mark.start))")
    }

    /// Everything you didn't mark isn't a rally: pre-tracked rallies are
    /// turned down, found rallies dropped; the video is finished.
    private func finish() {
        guard open == nil else { return }
        if marker.isPlaying { marker.togglePlay() }
        let marks = marker.rallies
        func covered(_ a: Double, _ b: Double) -> Bool { marks.contains { min($0.end, b) - max($0.start, a) > 0.5 * (b - a) } }
        for t in session.tracks ?? [] where t.awaitsRallyCheck && !covered(t.start, t.end) {
            review.setIsRally(false, AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end))
        }
        for g in marker.openGuesses where !(session.notRallies ?? []).contains(where: { abs($0 - g.start) < 0.05 }) {
            marker.sampler.addNotRally(start: g.start, session: session.name)
        }
        marker.wholeVideoMarked = true
        onDone()
    }

    private func note(_ text: String, _ side: NetSide? = nil) {
        lastEvent = text + (side.map { " · \($0 == .near ? "near" : "far") side" } ?? "")
        lastEventAt = Date()
    }

    private func play(from t: Double) {
        marker.seek(to: max(0, t))
        if !marker.isPlaying { marker.togglePlay() }
    }

    /// The net, once per video: the median box over frames spread through
    /// it (the review copy does — the net is big).
    private func findNet() async {
        guard session.netBox == nil, net == nil, !findingNet,
              let url = session.playbackURL(in: marker.sampler.datasetRoot) else { return }
        findingNet = true
        defer { findingNet = false }
        let found = await Task.detached(priority: .userInitiated) { () -> TrackCandidate? in
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
        guard let found else { return }
        net = found.rect
        marker.sampler.setNetBox(found, session: session.name)
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !marker.footageMissing else { return false }
        let flags = event.modifierFlags.intersection([.shift, .option, .command])
        switch event.keyCode {
        case 49: marker.togglePlay(); return true
        case 123: marker.skip(by: flags.contains(.shift) ? -10 : -2); return true
        case 124: marker.skip(by: flags.contains(.shift) ? 10 : 2); return true
        case 51, 117:
            if let r = marker.rallies.first(where: { $0.contains(marker.playhead) }) { marker.delete(r.id); note("Removed the rally here") }
            return true
        case 53:
            guard open != nil else { return false }
            open = nil
            note("Rally cancelled")
            return true
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if let n = Int(ch), let s = Self.speeds.first(where: { Int($0) == n }) { speed = s; return true }
        switch ch {
        case "s": self.event(.serve, flags: flags)
        case "p": self.event(.pass, flags: flags)
        case "t": self.event(.set, flags: flags)
        case "a": self.event(.attack, flags: flags)
        case "b": self.event(.block, flags: flags)
        case "f": self.event(.freeBall, flags: flags)
        case "d": close(as: .rally)
        case "n": close(as: nil)
        case "z": undo()
        default: return false
        }
        return true
    }
}
