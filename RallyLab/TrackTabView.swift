//
//  TrackTabView.swift
//  RallyLab
//
//  Label rallies frame by frame (see TrackLabelModel). Left: the videos
//  and their rallies. Middle: the frame, the ball's path around it, and a
//  strip with one cell per frame coloured by how sure it is.
//
//  Keys: Space play/pause (¼ speed by default, stopping on frames worth a
//  look) · ←/→ a frame · ⇧←/⇧→ the previous/next frame to check · click
//  the ball · ↩ the pick is right · H hidden · ⌫ back to the solver's pick
//  · [ ] move the start · { } move the end · D rally done.
//

import AppKit
import SwiftUI

struct TrackTabView: View {
    @Bindable var tracker: TrackLabelModel
    let isActive: Bool
    @State private var keyMonitor: Any?
    @AppStorage("RallyLab.trackSession") private var savedSession = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            stage
                .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if tracker.sessionName == nil, !savedSession.isEmpty { tracker.open(sessionName: savedSession) }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) ? nil : $0 }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            tracker.stop()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Track").font(.headline)
            Picker("Video", selection: Binding(
                get: { tracker.sessionName ?? "" },
                set: { name in
                    savedSession = name
                    tracker.open(sessionName: name)
                }
            )) {
                Text("Choose a video…").tag("")
                ForEach(tracker.trackableSessions) { s in
                    Text(s.name).tag(s.name)
                }
            }
            .labelsHidden()

            List {
                if !tracker.rallies.isEmpty {
                    Section("Tracked") {
                        ForEach(tracker.rallies) { rally in
                            rallyRow(rally)
                                .contentShape(Rectangle())
                                .onTapGesture { tracker.select(rally.id) }
                                .listRowBackground(rally.id == tracker.selectedId ? Color.accentColor.opacity(0.18) : Color.clear)
                                .contextMenu {
                                    Button("Remove", role: .destructive) { tracker.deleteRally(rally.id) }
                                }
                        }
                    }
                }
                if !tracker.suggestions.isEmpty {
                    Section("Found in this video") {
                        ForEach(tracker.suggestions) { s in
                            HStack {
                                Text("\(TrackLabelModel.clock(s.start)) – \(TrackLabelModel.clock(s.end))")
                                    .font(.callout.monospacedDigit())
                                Spacer()
                                Button("Track") { tracker.track(s) }
                                    .controlSize(.small)
                                    .disabled(tracker.trackingProgress != nil)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if tracker.sessionName != nil {
                NewRallyForm(tracker: tracker)
            }
        }
        .padding(12)
    }

    private func rallyRow(_ rally: TrackedRally) -> some View {
        let check = rally.points.filter(\.isUncertain).count
        return HStack(spacing: 8) {
            Image(systemName: rally.done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(rally.done ? ReviewStyle.yours : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(TrackLabelModel.clock(rally.start)) – \(TrackLabelModel.clock(rally.end))")
                    .font(.callout.monospacedDigit())
                Text(rally.candidates.isEmpty ? "\(rally.points.count) frames · not tracked yet"
                     : "\(rally.points.count) frames · \(check) to check")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 10) {
            header
            ZStack {
                ReviewStyle.stage
                if let image = tracker.image, let rally = tracker.rally {
                    TrackFrameView(image: image, rally: rally, index: tracker.index, snapping: tracker.snapping) {
                        tracker.place(at: $0)
                    }
                } else {
                    ContentUnavailableView(
                        tracker.sessionName == nil ? "Choose a video" : "Choose a rally",
                        systemImage: "scope",
                        description: Text("Track a rally to label the ball on every frame: the detector proposes, you fix what's wrong.")
                    )
                }
                if let progress = tracker.trackingProgress {
                    VStack(spacing: 8) {
                        ProgressView(value: progress).frame(width: 240)
                        Text("Finding the ball on every frame…").font(.callout)
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if let rally = tracker.rally {
                TrackStrip(points: rally.points, index: tracker.index) { tracker.go(to: $0) }
                    .frame(height: 26)
                controls
            }
            Text(tracker.status).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let rally = tracker.rally, let p = tracker.point {
                Text("Frame \(tracker.index + 1) of \(rally.points.count)").font(.headline.monospacedDigit())
                Text(TrackLabelModel.clock(p.time)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                TrackStateTag(point: p)
                Spacer()
                Button { tracker.toggleDone() } label: {
                    Label(rally.done ? "Done" : "Mark Done (D)",
                          systemImage: rally.done ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(rally.done ? ReviewStyle.yours : nil)
                .help(rally.done ? "Done — it goes into the multi-frame package. Click to reopen." : "Done: include it in the multi-frame package")
            } else {
                Spacer()
            }
        }
        .frame(height: 28)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { tracker.togglePlay() } label: {
                Image(systemName: tracker.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play / pause (Space)")
            Picker("Speed", selection: $tracker.speed) {
                Text("¼×").tag(0.25)
                Text("½×").tag(0.5)
                Text("1×").tag(1.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            Toggle("Stop on frames to check", isOn: $tracker.pauseOnUncertain)
                .toggleStyle(.checkbox)
            Spacer()
            Button("Hidden (H)") { tracker.markHidden() }
            Button("Re-track") { tracker.autoTrack() }
                .help("Run the detector over the rally again (keeps your points)")
                .disabled(tracker.trackingProgress != nil)
            Menu("Range") {
                Button("Start 0.5 s earlier  [") { tracker.extend(start: -0.5) }
                Button("Start 0.5 s later  ]") { tracker.extend(start: 0.5) }
                Button("End 0.5 s earlier  {") { tracker.extend(end: -0.5) }
                Button("End 0.5 s later  }") { tracker.extend(end: 0.5) }
            }
            .frame(width: 90)
        }
        .controlSize(.small)
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isActive, tracker.rally != nil,
              let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              !(window is NSPanel), !(window.firstResponder is NSText) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: shift ? tracker.jumpToUncertain(forward: false) : tracker.stepBy(-1); return true
        case 124: shift ? tracker.jumpToUncertain(forward: true) : tracker.stepBy(1); return true
        case 49: tracker.togglePlay(); return true
        case 36, 76: tracker.confirm(); tracker.stepBy(1); return true
        case 51, 117: tracker.revert(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h": tracker.markHidden(); tracker.stepBy(1)
        case "d": tracker.toggleDone()
        case "[": shift ? tracker.extend(end: -0.5) : tracker.extend(start: -0.5)
        case "]": shift ? tracker.extend(end: 0.5) : tracker.extend(start: 0.5)
        case "{": tracker.extend(end: -0.5)
        case "}": tracker.extend(end: 0.5)
        default: return false
        }
        return true
    }
}

/// Add a rally the Sampler didn't find: a start time and a length.
private struct NewRallyForm: View {
    let tracker: TrackLabelModel
    @State private var start = ""
    @State private var length = 10.0

    var body: some View {
        GroupBox("New rally") {
            HStack(spacing: 6) {
                TextField("m:ss", text: $start).frame(width: 60)
                Stepper("\(Int(length)) s", value: $length, in: 2...40, step: 1)
                Button("Track") {
                    if let s = Self.seconds(start) { tracker.startRally(start: s, end: s + length) }
                }
                .disabled(Self.seconds(start) == nil || tracker.trackingProgress != nil)
            }
            .controlSize(.small)
        }
    }

    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

private struct TrackStateTag: View {
    let point: TrackPoint

    var body: some View {
        let (text, color): (String, Color) = switch (point.origin, point.state) {
        case (.user, .visible): ("yours", ReviewStyle.yours)
        case (.user, _): ("hidden — yours", .gray)
        case (.filled, _): ("filled in — check", ReviewStyle.guess)
        case (_, .unknown): ("not found — click the ball or H", .red)
        case (.auto, .visible): (String(format: "detector %.2f", point.box?.confidence ?? 0),
                                 point.isUncertain ? ReviewStyle.guess : ReviewStyle.held)
        case (.auto, .hidden): ("hidden", .gray)
        }
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }
}

/// The frame with the ball's path: past positions fading behind, the next
/// few ahead, and the current one ringed in its state's colour.
private struct TrackFrameView: View {
    let image: CGImage
    let rally: TrackedRally
    let index: Int
    let snapping: CGPoint?
    let onClick: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let view = OverlayGeometry.fittedRect(content: CGSize(width: image.width, height: image.height), in: geo.size)
            Canvas { ctx, _ in
                ctx.draw(Image(decorative: image, scale: 1, orientation: .up), in: view)
                func centre(_ box: TrackCandidate) -> CGPoint {
                    CGPoint(x: view.minX + box.rect.midX * view.width, y: view.minY + (1 - box.rect.midY) * view.height)
                }
                // Trail: 20 frames back, 6 ahead.
                for k in max(0, index - 20)..<min(rally.points.count, index + 7) where k != index {
                    guard let box = rally.points[k].box, rally.points[k].state == .visible else { continue }
                    let c = centre(box)
                    let fade = k < index ? 0.25 + 0.6 * Double(k - index + 20) / 20 : 0.35
                    let r: CGFloat = k < index ? 2.5 : 2
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(Self.color(rally.points[k]).opacity(fade)))
                }
                // The detector's other candidates on this frame, faint.
                if index < rally.candidates.count {
                    for cand in rally.candidates[index] where cand != rally.points[index].box {
                        let c = centre(cand)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                                   with: .color(.white.opacity(0.35)), lineWidth: 1)
                    }
                }
                let p = rally.points[index]
                if let box = p.box, p.state == .visible {
                    let c = centre(box)
                    let r = max(9, max(box.rect.width * view.width, box.rect.height * view.height) / 2 + 5)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(Self.color(p)),
                               style: StrokeStyle(lineWidth: 2.5, dash: p.origin == .filled ? [4, 3] : []))
                }
                if let s = snapping {
                    let c = CGPoint(x: view.minX + s.x * view.width, y: view.minY + s.y * view.height)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)),
                               with: .color(ReviewStyle.yours), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let p = CGPoint(x: (tap.location.x - view.minX) / view.width, y: (tap.location.y - view.minY) / view.height)
                guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                onClick(p)
            })
        }
    }

    static func color(_ p: TrackPoint) -> Color {
        if p.origin == .user { return ReviewStyle.yours }
        return p.isUncertain ? ReviewStyle.guess : ReviewStyle.held
    }
}

/// One cell per frame: green yours, teal sure, amber to check, grey hidden,
/// red not found. Click to jump.
private struct TrackStrip: View {
    let points: [TrackPoint]
    let index: Int
    let onJump: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let w = size.width / CGFloat(max(points.count, 1))
                for (i, p) in points.enumerated() {
                    let color: Color = switch (p.origin, p.state) {
                    case (.user, .visible): ReviewStyle.yours
                    case (_, .hidden): .gray.opacity(0.6)
                    case (_, .unknown): .red.opacity(0.75)
                    default: p.isUncertain ? ReviewStyle.guess : ReviewStyle.held
                    }
                    ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: 4, width: max(w - 0.5, 0.5), height: size.height - 8)),
                             with: .color(color))
                }
                let x = (CGFloat(index) + 0.5) * w
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let i = Int(drag.location.x / geo.size.width * CGFloat(points.count))
                onJump(min(max(0, i), points.count - 1))
            })
        }
    }
}
