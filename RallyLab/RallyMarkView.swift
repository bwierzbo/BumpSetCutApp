//
//  RallyMarkView.swift
//  RallyLab
//
//  Track tab → Rally Times (see RallyMarkModel). The video, and under it a
//  timeline of the whole video: your rallies as green bars (drag an end to
//  move it), the guesses to accept as grey ones, the playhead in white.
//
//  Scroll (trackpad or wheel) over the video or timeline to scrub; pinch
//  or = / − to zoom the picture (0 back to the whole frame), drag to pan.
//  Keys: Enter start / end a rally · Esc cancel a start · Space play/pause ·
//  1 / 2 / 4 speed · ←/→ 1 s · ⇧←/⇧→ 5 s · N / P next / previous rally ·
//  A accept the guess · ⌫ delete.
//

import AVKit
import SwiftUI

struct RallyMarkView: View {
    @Bindable var marker: RallyMarkModel
    @State private var hovering = false
    @State private var scrollMonitor: Any?
    @State private var pinchBase: CGFloat?
    @State private var panBase: CGPoint?

    var body: some View {
        VStack(spacing: 10) {
            header
            ZStack {
                ReviewStyle.stage
                if let player = marker.player {
                    GeometryReader { geo in
                        ZoomablePlayerView(player: player, zoom: marker.zoom, center: marker.zoomCenter)
                            .contentShape(Rectangle())
                            .gesture(MagnifyGesture()
                                .onChanged { value in
                                    let base = pinchBase ?? marker.zoom
                                    if pinchBase == nil {
                                        pinchBase = base
                                        // Zoom toward where the pinch started.
                                        if marker.zoom <= 1.01 {
                                            marker.zoomCenter = CGPoint(x: value.startLocation.x / geo.size.width,
                                                                        y: value.startLocation.y / geo.size.height)
                                        }
                                    }
                                    marker.setZoom(base * value.magnification)
                                }
                                .onEnded { _ in pinchBase = nil })
                            .simultaneousGesture(DragGesture(minimumDistance: 4)
                                .onChanged { drag in
                                    guard marker.zoom > 1.01 else { return }
                                    let base = panBase ?? marker.zoomCenter
                                    if panBase == nil { panBase = base }
                                    marker.pan(to: CGPoint(x: base.x - drag.translation.width / (geo.size.width * marker.zoom),
                                                           y: base.y - drag.translation.height / (geo.size.height * marker.zoom)))
                                }
                                .onEnded { _ in panBase = nil })
                    }
                    if marker.zoom > 1.01 {
                        Button { marker.resetZoom() } label: {
                            Text(String(format: "%.1f×", marker.zoom)).monospacedDigit()
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Back to the whole frame (0)")
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                } else {
                    ContentUnavailableView("Choose a video", systemImage: "timeline.selection",
                                           description: Text("Mark when every rally starts and ends. The Sampler's rally guesses are there to accept or fix."))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            if marker.duration > 0 {
                RallyTimeline(marker: marker)
                    .frame(height: 54)
                    .onHover { hovering = $0 }
                controls
            }
            Text(marker.status).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .onAppear {
            // Scroll over the video or timeline scrubs: a trackpad by its own
            // distance (fine, a little faster on a flick), a mouse wheel half a second a notch.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard hovering, marker.player != nil else { return event }
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : -event.scrollingDeltaY
                if event.hasPreciseScrollingDeltas {
                    // Trackpad: ~1/60 s per point, a little faster on a hard flick.
                    marker.scrub(by: Double(delta) * (abs(delta) > 25 ? 0.035 : 0.016))
                } else {
                    // Mouse wheel: half a second a notch.
                    marker.scrub(by: Double(delta).sign == .minus ? -0.5 : 0.5)
                }
                return nil
            }
        }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if marker.player != nil {
                Text("\(marker.rallies.count) rallies").font(.headline)
                Text(TrackLabelModel.clock(marker.playhead) + " / " + TrackLabelModel.clock(marker.duration))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if let start = marker.pendingStart {
                    Text("started at \(TrackLabelModel.clock(start)) — Enter at its end")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(ReviewStyle.guess.opacity(0.22), in: Capsule())
                        .foregroundStyle(ReviewStyle.guess)
                }
                Spacer()
                Toggle("Whole video marked", isOn: Binding(get: { marker.wholeVideoMarked },
                                                         set: { marker.wholeVideoMarked = $0 }))
                    .toggleStyle(.checkbox)
                    .help("Every rally in the video is marked — it then counts when scoring missed and false rallies")
            } else {
                Spacer()
            }
        }
        .frame(height: 28)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { marker.togglePlay() } label: {
                Image(systemName: marker.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play / pause (Space)")
            Picker("Speed", selection: $marker.rate) {
                Text("1×").tag(Float(1))
                Text("2×").tag(Float(2))
                Text("4×").tag(Float(4))
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            Button("◀ Prev (P)") { marker.jump(forward: false) }
            Button("Next (N) ▶") { marker.jump(forward: true) }
            Spacer()
            Button(marker.pendingStart == nil ? "Start Rally (↩)" : "End Rally (↩)") { marker.toggleMark() }
                .buttonStyle(.borderedProminent)
                .tint(marker.pendingStart == nil ? .accentColor : ReviewStyle.guess)
            Button("Accept guess (A)") { marker.acceptGuess() }
                .disabled(marker.openGuesses.isEmpty)
            Button("Delete (⌫)") { marker.delete() }
        }
        .controlSize(.small)
    }

    /// Rally Times keys; true when handled.
    static func handleKey(_ event: NSEvent, marker: RallyMarkModel) -> Bool {
        guard marker.player != nil else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: marker.skip(by: shift ? -5 : -1); return true
        case 124: marker.skip(by: shift ? 5 : 1); return true
        case 49: marker.togglePlay(); return true
        case 36, 76: marker.toggleMark(); return true
        case 53: marker.cancelPending(); return true
        case 51, 117: marker.delete(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": marker.acceptGuess()
        case "=", "+": marker.setZoom(marker.zoom * 1.5)
        case "-": marker.setZoom(marker.zoom / 1.5)
        case "0": marker.resetZoom()
        case "n": marker.jump(forward: true)
        case "p": marker.jump(forward: false)
        case "1": marker.rate = 1
        case "2": marker.rate = 2
        case "4": marker.rate = 4
        default: return false
        }
        return true
    }
}

/// The whole video: guesses grey, your rallies green (selected brighter,
/// ends draggable), the I-start in amber, the playhead white. Click to seek.
private struct RallyTimeline: View {
    let marker: RallyMarkModel
    @State private var dragging: (id: UUID, edge: Edge)?
    private enum Edge { case start, end }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x: (Double) -> CGFloat = { CGFloat($0 / max(marker.duration, 0.001)) * w }
            Canvas { ctx, _ in
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 4), with: .color(.black.opacity(0.25)))
                for g in marker.openGuesses {
                    ctx.fill(Path(CGRect(x: x(g.start), y: h * 0.55, width: max(2, x(g.end) - x(g.start)), height: h * 0.3)),
                             with: .color(.gray.opacity(0.55)))
                }
                for r in marker.rallies {
                    let selected = r.id == marker.selectedId
                    let rect = CGRect(x: x(r.start), y: h * 0.12, width: max(2, x(r.end) - x(r.start)), height: h * 0.4)
                    ctx.fill(Path(rect), with: .color(ReviewStyle.yours.opacity(selected ? 1 : 0.7)))
                    if selected {
                        for edge in [rect.minX, rect.maxX] {
                            ctx.fill(Path(CGRect(x: edge - 1.5, y: 0, width: 3, height: h * 0.64)), with: .color(.white))
                        }
                    }
                }
                if let s = marker.pendingStart {
                    ctx.fill(Path(CGRect(x: x(s) - 1.5, y: 0, width: 3, height: h)), with: .color(ReviewStyle.guess))
                }
                ctx.fill(Path(CGRect(x: x(marker.playhead) - 1, y: 0, width: 2, height: h)), with: .color(.white))
                // Minute ticks.
                var m = 60.0
                while m < marker.duration {
                    ctx.fill(Path(CGRect(x: x(m), y: h - 6, width: 1, height: 6)), with: .color(.white.opacity(0.4)))
                    m += 60
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let t = Double(min(max(0, drag.location.x), w) / w) * marker.duration
                    if dragging == nil {
                        // Grab a rally end within 6 pt of where the drag began, else seek.
                        let x0 = drag.startLocation.x
                        if let r = marker.rallies.first(where: { abs(x($0.start) - x0) < 6 }) {
                            dragging = (r.id, .start)
                        } else if let r = marker.rallies.first(where: { abs(x($0.end) - x0) < 6 }) {
                            dragging = (r.id, .end)
                        }
                        if let d = dragging { marker.selectedId = d.id }
                    }
                    if let d = dragging {
                        d.edge == .start ? marker.setStart(d.id, to: t) : marker.setEnd(d.id, to: t)
                    }
                    marker.seek(to: t)
                }
                .onEnded { drag in
                    if dragging == nil {
                        let t = Double(min(max(0, drag.location.x), w) / w) * marker.duration
                        marker.selectedId = marker.rallies.first { $0.contains(t) }?.id
                    }
                    dragging = nil
                })
        }
    }
}
