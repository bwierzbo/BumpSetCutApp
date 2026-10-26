//
//  RallyBoundariesView.swift
//  RallyLab
//
//  The Rally Boundaries tab (Stage 1, D-024; S1-b): eligible recordings with their
//  coverage on the left; the original footage, a frame-exact readout, the full-video
//  timeline (coverage, spans, rallies, legacy marks, playhead) and the inspector on
//  the right. Keys do the work; every commit goes through RallyBoundariesModel →
//  BoundaryEditor → EventReview.write.
//

import AppKit
import SwiftUI

struct RallyBoundariesView: View {
    let model: RallyBoundariesModel
    let isActive: Bool
    @State private var keyMonitor: Any?
    @State private var showHelp = false

    var body: some View {
        HSplitView {
            recordings.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            review.frame(minWidth: 640)
        }
        .onAppear {
            model.refreshRecordings()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) ? nil : $0 }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if model.isPlaying { model.togglePlay() }
        }
    }

    // MARK: - Recordings

    private var recordings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                Button { model.refreshRecordings() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            if let problem = model.inventoryProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            let rows = model.eligible.sorted { Self.order(of: $0) < Self.order(of: $1) }
            List(rows, id: \.name, selection: Binding(get: { model.sessionName }, set: { name in if let name { Task { await model.open(name) } } })) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(r.split).font(.caption).foregroundStyle(.secondary)
                    }
                    CoverageBar(fraction: r.coverageFraction ?? 0, complete: r.stage1Complete, problem: r.recordProblem != nil)
                    Text(Self.summary(of: r))
                        .font(.caption).foregroundStyle(r.recordProblem == nil ? Color.secondary : Color.red).lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            Text("\(model.recordings.filter(\.withheld).count) withheld recording(s) are not listed.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    /// Least reviewed first; complete recordings last.
    private static func order(of r: EventInventory.Recording) -> Double {
        (r.stage1Complete ? 2.0 : 0.0) + (r.coverageFraction ?? 0)
    }

    private static func summary(of r: EventInventory.Recording) -> String {
        var text: String
        if let problem = r.recordProblem { text = "record not accepted: \(problem)" }
        else if r.stage1Complete { text = "fully reviewed" }
        else if r.eventsFile { text = "\(Int((r.coverageFraction ?? 0) * 100)) % reviewed · \(r.reviewedRallies) rallies · \(r.unknownGaps) gap(s)" }
        else { text = "not started" }
        if let n = r.legacyMarks { text += " · \(n) legacy" }
        return text
    }

    // MARK: - Review

    private var review: some View {
        VStack(spacing: 6) {
            if let player = model.player {
                ZoomablePlayerView(player: player, zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
                    .frame(minHeight: 300)
                    .background(Color.black)
            } else {
                ZStack { Color.black.opacity(0.85); Text(model.status).foregroundStyle(.white).padding() }.frame(minHeight: 300)
            }
            HStack {
                Text(model.readout).font(.system(.body, design: .monospaced))
                if model.frames.isEmpty, model.player != nil { ProgressView().controlSize(.small); Text("reading frame times…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let f = model.file {
                    let reviewed = EventReview.union(f.coverage).reduce(0) { $0 + $1.end - $1.start }
                    Text(f.stage1Complete != nil ? "fully reviewed" : String(format: "%.0f %% reviewed · %d unknown gap(s)", reviewed / f.durationSec * 100, EventReview.gaps(in: f).count))
                        .font(.caption).foregroundStyle(f.stage1Complete != nil ? .green : .secondary)
                }
                Toggle("legacy marks", isOn: Binding(get: { model.showLegacy }, set: { model.showLegacy = $0 })).toggleStyle(.checkbox).controlSize(.small)
                Button("Keys") { showHelp.toggle() }.controlSize(.small).popover(isPresented: $showHelp) { KeyHelp().padding() }
            }
            BoundaryTimeline(model: model).frame(height: 54)
            inspector
            Text(model.status).font(.caption).foregroundStyle(model.lastRefused ? .red : .secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
    }

    private var inspector: some View {
        HStack(alignment: .top, spacing: 16) {
            if let e = model.editor {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.draft.rallyId == nil ? "New rally" : "Editing rally \(e.draft.rallyId!.uuidString.prefix(8))").font(.caption.bold())
                    Text("kind \(e.draft.kind.rawValue)" + (e.draft.edge.map { " · edge \($0.rawValue)" } ?? "") + (e.draft.flags.isEmpty ? "" : " · " + e.draft.flags.joined(separator: ", "))).font(.caption)
                    Text("contact " + describe(e.draft.contact)).font(.caption)
                    Text("dead " + describe(e.draft.dead)).font(.caption)
                    if let s = e.openSpan { Text("\(s.kind.rawValue) open from \(BoundaryEditor.clock(s.start))").font(.caption).foregroundStyle(.orange) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    let reviewed = e.file.rallies.filter { $0.reviewState == .reviewed }
                    Text("\(reviewed.count) rallies · \(e.file.rallies.count - reviewed.count) withdrawn · \(e.file.spans.count) spans").font(.caption.bold())
                    ForEach(reviewed.sorted { ($0.contact?.earliest ?? $0.dead?.earliest ?? 0) < ($1.contact?.earliest ?? $1.dead?.earliest ?? 0) }.suffix(6), id: \.rallyId) { r in
                        Button {
                            model.select(r.rallyId)
                        } label: {
                            Text("\(r.kind.rawValue) \(r.contact.map { BoundaryEditor.clock($0.earliest) } ?? "?") → \(r.dead.map { BoundaryEditor.clock($0.earliest) } ?? "?")" + (r.flags.isEmpty ? "" : " ⚑"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(r.rallyId == e.selected ? Color.accentColor : .primary)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func describe(_ e: EventReview.EventTime?) -> String {
        guard let e else { return "—" }
        let t = e.earliest == e.latest ? BoundaryEditor.clock(e.earliest) : "\(BoundaryEditor.clock(e.earliest))–\(BoundaryEditor.clock(e.latest))"
        return t + (e.visibility == .occluded ? " (occluded)" : "") + (e.isAmbiguous ? " ambiguous" : "")
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isActive, let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              !(window is NSPanel), !(window.firstResponder is NSText), model.editor != nil else { return false }
        let shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option), command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 123: option ? model.skip(seconds: -1) : model.step(frames: shift ? -5 : -1); return true
        case 124: option ? model.skip(seconds: 1) : model.step(frames: shift ? 5 : 1); return true
        case 49: model.togglePlay(); return true
        case 36, 76: model.perform(command ? .complete : .commit); return true
        case 53: model.perform(.cancel); return true
        case 51, 117: model.perform(.withdraw); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": model.perform(.mark(.contact, shift ? .latest : .earliest))
        case "d": model.perform(.mark(.dead, shift ? .latest : .earliest))
        case "k": model.perform(.cycleKind)
        case "o": model.perform(.toggleOccluded)
        case "a": model.perform(.toggleFlag("ambiguous"))
        case "e": model.perform(.cycleEdge)
        case "n": model.perform(.span(.nonRallyActivity))
        case "t": model.perform(.span(.transition))
        case "u": model.perform(.span(.uncertain))
        case "r": model.perform(.reviewedThrough)
        case "z": model.perform(.undo)
        default: return false
        }
        return true
    }
}

private struct KeyHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                Text("← → frame · ⇧ 5 frames · ⌥ 1 s · space play")
                Text("S serve contact · ⇧S its latest frame · D ball dead · ⇧D its latest frame")
                Text("O occluded (last event) · A flag ambiguous · K kind · E edge")
                Text("N / T / U non-rally activity / transition / uncertain span (press at start and end)")
                Text("R reviewed through the playhead · ⏎ commit rally · ⌘⏎ recording complete")
                Text("⌫ withdraw selected · Z undo · ⎋ cancel")
            }.font(.caption)
        }
    }
}

private struct CoverageBar: View {
    let fraction: Double
    let complete: Bool
    let problem: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.25))
                RoundedRectangle(cornerRadius: 2).fill(problem ? Color.red.opacity(0.6) : complete ? Color.green : Color.accentColor.opacity(0.8))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, problem ? 1 : fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// The whole recording: reviewed coverage (green floor), unknown (dark), spans (amber / grey / purple),
/// rallies (blue; withdrawn dimmed; ambiguous ends hatched), legacy marks (thin orange, optional),
/// the draft (white outline), the playhead. Click or drag to seek.
private struct BoundaryTimeline: View {
    let model: RallyBoundariesModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let d = max(model.duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / d) * w }
            Canvas { ctx, _ in
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 4), with: .color(.black.opacity(0.35)))
                if let f = model.file {
                    for c in EventReview.union(f.coverage) {
                        ctx.fill(Path(CGRect(x: x(c.start), y: h - 8, width: max(1, x(c.end) - x(c.start)), height: 8)), with: .color(.green.opacity(0.8)))
                    }
                    for s in f.spans {
                        let color: Color = s.kind == .nonRallyActivity ? .orange : s.kind == .transition ? .gray : .purple
                        ctx.fill(Path(CGRect(x: x(s.start), y: h * 0.55, width: max(2, x(s.end) - x(s.start)), height: h * 0.25)), with: .color(color.opacity(0.7)))
                    }
                    for r in f.rallies {
                        guard let a = r.contact?.earliest ?? r.dead?.earliest, let b = r.dead?.latest ?? r.contact?.latest else { continue }
                        let selected = r.rallyId == model.editor?.selected
                        let rect = CGRect(x: x(a), y: h * 0.12, width: max(2, x(b) - x(a)), height: h * 0.38)
                        ctx.fill(Path(rect), with: .color((r.reviewState == .withdrawn ? Color.gray : Color.blue).opacity(selected ? 1 : 0.7)))
                        for e in [r.contact, r.dead].compactMap({ $0 }) where e.earliest < e.latest {
                            ctx.fill(Path(CGRect(x: x(e.earliest), y: h * 0.12, width: max(1, x(e.latest) - x(e.earliest)), height: h * 0.38)), with: .color(.white.opacity(0.35)))
                        }
                    }
                    if model.showLegacy {
                        for m in model.legacyMarks {
                            ctx.fill(Path(CGRect(x: x(m.startTime), y: h * 0.02, width: max(1, x(m.endTime) - x(m.startTime)), height: 3)), with: .color(.orange.opacity(0.9)))
                        }
                    }
                    if let e = model.editor {
                        if let a = e.draft.contact?.earliest ?? e.draft.dead?.earliest, let b = e.draft.dead?.latest ?? e.draft.contact?.latest {
                            ctx.stroke(Path(CGRect(x: x(a), y: h * 0.10, width: max(2, x(b) - x(a)), height: h * 0.42)), with: .color(.white), lineWidth: 1.5)
                        }
                        if let s = e.openSpan { ctx.fill(Path(CGRect(x: x(s.start) - 1, y: h * 0.5, width: 2, height: h * 0.35)), with: .color(.orange)) }
                    }
                }
                ctx.fill(Path(CGRect(x: x(model.playhead) - 1, y: 0, width: 2, height: h)), with: .color(.white))
                var m = 60.0
                while m < d {
                    ctx.fill(Path(CGRect(x: x(m), y: h - 12, width: 1, height: 4)), with: .color(.white.opacity(0.5)))
                    m += 60
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in model.seek(to: Double(min(max(0, drag.location.x), w) / w) * d, exact: false) }
                .onEnded { drag in model.seek(to: Double(min(max(0, drag.location.x), w) / w) * d) })
        }
    }
}
