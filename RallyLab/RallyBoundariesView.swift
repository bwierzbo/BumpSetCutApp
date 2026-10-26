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
            if let problem = model.pilotProblem { Text(problem).font(.caption).foregroundStyle(.red) }
            if let problem = model.inventoryProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            let rows = model.eligible.sorted { Self.order(of: $0) < Self.order(of: $1) }
            List(rows, id: \.name, selection: Binding(get: { model.sessionName }, set: { name in if let name { Task { await model.open(name) } } })) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                        Spacer()
                        if model.pilotCount(for: r.name) > 0 { Text("pilot \(model.pilotCount(for: r.name))").font(.caption).foregroundStyle(.yellow) }
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
                    .disabled(model.legacyHidden)
                    .help(model.pilotWindows.isEmpty ? "" : "pilot rallies' marks stay hidden until each is committed (blind)")
                Toggle("second review (blind)", isOn: Binding(get: { model.secondReview }, set: { model.setSecondReview($0) })).toggleStyle(.checkbox).controlSize(.small)
                    .disabled(model.editor == nil)
                Button("Keys") { showHelp.toggle() }.controlSize(.small).popover(isPresented: $showHelp) { KeyHelp().padding() }
            }
            BoundaryTimelineView(file: model.file, duration: model.duration, playhead: model.playhead,
                                 legacyMarks: model.visibleLegacyMarks, showLegacy: model.showLegacy && !model.legacyHidden,
                                 draft: draftBar, openSpanStart: model.editor?.openSpan?.start, selected: model.editor?.selected,
                                 hideRallyTimes: model.secondReview, windows: model.pilotWindows.map { ($0.window[0], $0.window[1]) },
                                 seek: { t, exact in model.seek(to: t, exact: exact) }, select: { t in model.selectRally(at: t) })
                .frame(height: 54)
            if let c = model.editor?.draftConflict {
                HStack(spacing: 8) {
                    Text("This rally changed on the other side while you were editing it (contact \(describe(c.incoming.contact)), dead \(describe(c.incoming.dead)) there).").font(.caption)
                    Button("Keep mine") { model.resolveDraftConflict(keepMine: true) }
                    Button("Take theirs") { model.resolveDraftConflict(keepMine: false) }
                    Spacer()
                }
                .controlSize(.small).padding(6).background(Color.red.opacity(0.12))
            }
            if !model.pilotWindows.isEmpty { pilotList }
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
                    let reviewed = e.reviewedRallies
                    Text("\(reviewed.count) rallies · \(e.file.rallies.count - reviewed.count) withdrawn · \(e.file.spans.count) spans · [ ] previous / next · click the timeline to select").font(.caption.bold())
                    // Every reviewed rally, in order, each selectable for correction or withdrawal.
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(reviewed, id: \.rallyId) { r in
                                Button { model.select(r.rallyId) } label: { Text(e.mode == .secondReview ? Self.blindLine(for: r) : Self.line(for: r)).font(.system(.caption, design: .monospaced)).foregroundStyle(r.rallyId == e.selected ? Color.accentColor : Color.primary) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The pilot's windows in this recording: stratum, window, state; a click opens the window paused.
    private var pilotList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pilot \(model.pilot?.id ?? ""): \(model.pilotWindows.count) rallies here · blind until committed · the repeat set is marked ↻").font(.caption.bold())
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(model.pilotWindows.enumerated()), id: \.offset) { _, s in
                        let state = model.pilotState(of: s)
                        Button { model.jump(to: s) } label: {
                            Text("\(s.stratum) \(BoundaryEditor.clock(s.window[0]))–\(BoundaryEditor.clock(s.window[1]))\(s.repeatReview ? " ↻" : "")\(state.second ? " ✓✓" : state.reviewed ? " ✓" : "")")
                                .font(.system(.caption, design: .monospaced))
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(state.second ? .green : state.reviewed ? .blue : .yellow)
                    }
                }
            }
        }
    }

    private static func line(for r: EventReview.Rally) -> String {
        let a = r.contact.map { BoundaryEditor.clock($0.earliest) } ?? "?"
        let b = r.dead.map { BoundaryEditor.clock($0.earliest) } ?? "?"
        return "\(r.kind.rawValue) \(a) → \(b)" + (r.flags.isEmpty ? "" : " ⚑")
    }

    /// In a second review the first result stays hidden: the rally is named by id and legacy mark only.
    private static func blindLine(for r: EventReview.Rally) -> String {
        "rally \(r.rallyId.uuidString.prefix(8))" + (r.legacyIndex.map { " (legacy #\($0))" } ?? "") + (r.secondReview == nil ? "" : " ✓✓")
    }

    /// The draft rally's extent for the timeline, when it has an event.
    private var draftBar: (start: Double, end: Double)? {
        guard let d = model.editor?.draft, let a = d.contact?.earliest ?? d.dead?.earliest, let b = d.dead?.latest ?? d.contact?.latest else { return nil }
        return (a, b)
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
        case "[": model.selectAdjacent(forward: false)
        case "]": model.selectAdjacent(forward: true)
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
                Text("[ ] previous / next rally (click the timeline selects the rally there) · ⌫ withdraw selected · Z undo · ⎋ cancel")
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
