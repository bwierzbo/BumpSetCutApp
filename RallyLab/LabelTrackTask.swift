//
//  LabelTrackTask.swift
//  RallyLab
//
//  A track task: trim the rally to the serve and the dead ball, then track
//  the game ball (on the main court; Hidden when it can't be seen) through
//  its frames, a hair past it each side. The detector proposes and the
//  solver links it up; you're stopped only on the frames worth a look.
//  Done marks the rally in the video's rally times too, and opens the next
//  task. A rally you started tracking and left reopens where it was.
//
//  Keys: ↩ the ball's right · H hidden · click the ball · ⌫ back to the
//  solver's pick · ⇥ / ⇧⇥ next / previous to check · ←/→ a frame · Space
//  play · = − 0 zoom · D done.
//

import SwiftUI

struct LabelTrackTask: View {
    let session: VideoSession
    let rally: LabelRally
    let tracker: TrackLabelModel
    let marker: RallyMarkModel
    let isActive: Bool
    let onClose: () -> Void
    let onDone: () -> Void
    /// The rally as trimmed, once it is.
    @State private var trimmed: LabelRally?

    /// A track of this rally you didn't finish.
    private var unfinished: TrackedRally? {
        session.tracks?.first { !$0.done && $0.bounds == rally }
    }

    /// The Sampler found this rally (rather than you marking it).
    private var isFound: Bool {
        !RallyMarkModel.marks(in: session).contains { abs($0.start - rally.start) < 0.05 && abs($0.end - rally.end) < 0.05 }
    }

    var body: some View {
        let trimmed = self.trimmed ?? (unfinished != nil ? rally : nil)
        VStack(spacing: 0) {
            LabelTaskHeader(title: trimmed == nil ? "Trim the rally" : "Track the game ball",
                            subtitle: "\(session.name) · \(TrackLabelModel.clock((trimmed ?? rally).start))", onClose: onClose) {
                StepDots(step: trimmed == nil ? 0 : 1)
            }
            Divider()
            if let trimmed {
                LabelTrackView(session: session, bounds: trimmed, resume: unfinished?.id, tracker: tracker, marker: marker,
                               isActive: isActive, onClose: onClose, onDone: onDone)
            } else {
                LabelTrimView(session: session, rally: rally, isActive: isActive, confirmTitle: "Track this rally",
                              onConfirm: { self.trimmed = $0 }, onCancel: onClose,
                              onNotARally: isFound ? {
                                  tracker.sampler.addNotRally(start: rally.start, session: session.name)
                                  onDone()
                              } : nil)
            }
        }
    }
}

/// Trim → track, as two dots.
private struct StepDots: View {
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Trim", "Track"].enumerated()), id: \.offset) { i, name in
                HStack(spacing: 4) {
                    Circle().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    Text(name).font(.caption).foregroundStyle(i == step ? .primary : .secondary)
                }
            }
        }
    }
}

/// The ball on every frame of a rally, checking only what needs it.
private struct LabelTrackView: View {
    let session: VideoSession
    let bounds: LabelRally
    /// The unfinished track to reopen instead of starting one.
    let resume: UUID?
    @Bindable var tracker: TrackLabelModel
    let marker: RallyMarkModel
    let isActive: Bool
    let onClose: () -> Void
    let onDone: () -> Void
    @State private var rallyId: UUID?

    private var rally: TrackedRally? { tracker.rally.flatMap { $0.id == rallyId ? $0 : nil } }

    var body: some View {
        VStack(spacing: 12) {
            stage
            if let rally {
                strip(rally)
                controls(rally)
            }
        }
        .padding(16)
        .task { await start() }
        .onDisappear { tracker.stop() }
        .labelKeys(isActive: isActive, handleKey)
    }

    private var stage: some View {
        ZStack {
            ReviewStyle.stage
            if let image = tracker.image, let rally {
                TrackFrameView(image: image, rally: rally, index: tracker.shownIndex ?? tracker.index, snapping: tracker.snapping,
                               tracker: tracker)
            }
            if let progress = tracker.trackingProgress {
                VStack(spacing: 10) {
                    ProgressView(value: progress).frame(width: 260)
                    Text(tracker.progressLabel).font(.callout)
                    Text("Track only the game ball on the main court — Hidden when it can't be seen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else if rally == nil {
                ProgressView("Reading the rally…")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    /// The frame strip, the margin past the rally each side dimmed.
    private func strip(_ rally: TrackedRally) -> some View {
        let n = max(rally.points.count, 1)
        let before = rally.points.filter { $0.time < bounds.start }.count
        let after = rally.points.filter { $0.time > bounds.end }.count
        return TrackStrip(points: rally.points, index: tracker.index) { tracker.go(to: $0) }
            .frame(height: 30)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width / CGFloat(n)
                    Color.black.opacity(0.45).frame(width: CGFloat(before) * w).allowsHitTesting(false)
                    Color.black.opacity(0.45).frame(width: CGFloat(after) * w).offset(x: geo.size.width - CGFloat(after) * w)
                        .allowsHitTesting(false)
                }
            }
    }

    private func controls(_ rally: TrackedRally) -> some View {
        let check = rally.points.filter(\.isUncertain).count
        return HStack(spacing: 12) {
            if let p = tracker.point {
                TrackStateTag(point: p)
                Text("Frame \(tracker.index + 1) of \(rally.points.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { tracker.markHidden(); tracker.stepBy(1) } label: { Label("Hidden", systemImage: "eye.slash") }
                .help("The ball can't be seen (H)")
            Button { tracker.confirm(); tracker.stepBy(1) } label: { Label("Right", systemImage: "checkmark") }
                .help("The ringed ball is right (↩)")
            Button { tracker.jumpToUncertain(forward: true) } label: {
                Label(check > 0 ? "Next to check · \(check)" : "Nothing to check", systemImage: "forward.end")
            }
            .disabled(check == 0)
            .help("The next frame worth a look (⇥)")
            Divider().frame(height: 20)
            Menu {
                Button("Re-track") { tracker.autoTrack() }.disabled(tracker.trackingProgress != nil)
                Button("Discard this rally", role: .destructive) {
                    tracker.deleteRally(rally.id)
                    onClose()
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            Button { finish() } label: { Label("Done", systemImage: "checkmark.circle.fill") }
                .buttonStyle(.borderedProminent)
                .tint(check == 0 ? .green : .accentColor)
                .disabled(tracker.trackingProgress != nil)
                .help(check == 0 ? "Done — on to the next task (D)" : "Done with \(check) frames unchecked (D)")
        }
        .controlSize(.large)
    }

    private func start() async {
        await tracker.openAndWait(sessionName: session.name)
        if let resume, tracker.rallies.contains(where: { $0.id == resume }) {
            tracker.select(resume)
        } else {
            tracker.startRally(start: max(0, bounds.start - TrackedRally.margin), end: bounds.end + TrackedRally.margin)
        }
        rallyId = tracker.selectedId
        tracker.resetZoom()
    }

    private func finish() {
        guard let rally else { return }
        if !rally.done { tracker.toggleDone() }
        marker.mark(start: bounds.start, end: bounds.end, session: session)
        onDone()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard rally != nil, tracker.trackingProgress == nil else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: tracker.stepBy(-1); return true
        case 124: tracker.stepBy(1); return true
        case 48: tracker.jumpToUncertain(forward: !shift); return true
        case 49: tracker.togglePlay(); return true
        case 36, 76: tracker.confirm(); tracker.stepBy(1); return true
        case 51, 117: tracker.revert(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h": tracker.markHidden(); tracker.stepBy(1)
        case "d": finish()
        case "=", "+": tracker.zoom(by: 1.5)
        case "-": tracker.zoom(by: 1 / 1.5)
        case "0": tracker.resetZoom()
        case "f": tracker.followBall.toggle()
        default: return false
        }
        return true
    }
}
