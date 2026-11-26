//
//  CoverageAuditView.swift
//  RallyLab
//
//  The Audit tab: the negative-coverage audit's review queue. On the left the frozen
//  draw, the pass (review, blind repeat, resolution) and the draw's recordings with
//  their progress; on the right the original footage, the interval under review with a
//  second of context either side, what of it has been played, and the verdict keys.
//  The picture is a bare player layer (ZoomablePlayerView): nothing is drawn over it,
//  and nothing here reads a ball path, a detector, a pipeline clip or a snap — the
//  existing marks appear only as the bounds of the interval. In the repeat pass the
//  first verdicts are not shown anywhere on the tab.
//

import AppKit
import SwiftUI

struct CoverageAuditView: View {
    @Bindable var model: CoverageAuditModel
    let isActive: Bool
    /// A correction moved a mark of this recording: the marking pass takes the file as it is now.
    let marksChanged: (String) -> Void
    @State private var keyMonitor: Any?
    @State private var showHelp = false
    @State private var showCorrections = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        HSplitView {
            queue.frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
            review.frame(minWidth: 560)
        }
        .onAppear {
            model.activate()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) ? nil : $0 }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            model.deactivate()
        }
        .onChange(of: model.awaitingNote) { _, kind in
            if kind != nil { noteFocused = true }
        }
    }

    // MARK: - The queue

    private var queue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Coverage audit").font(.headline)
                Spacer()
                Button { model.activate() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            Picker("Draw", selection: Binding(get: { model.draw?.url }, set: { url in if let url { model.openDraw(url) } })) {
                Text("Pick a draw…").tag(URL?.none)
                ForEach(model.drawFiles, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
            }
            .labelsHidden()
            if model.drawFiles.isEmpty {
                Text("No draw in manifests/coverage-audit/ — the draw tool (scripts/rally_classifier/coverage_audit_draw.py) writes one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(model.statuses, selection: Binding(get: { model.recordingId }, set: { name in if let name { Task { await model.open(name) } } })) { s in
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.recordingId).font(.system(.body, design: .monospaced)).lineLimit(1)
                    if let why = s.setAside {
                        Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    } else {
                        ProgressView(value: Self.progress(of: s, in: model.pass)).controlSize(.small)
                        Text(Self.summary(of: s, in: model.pass)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let problem = s.problem { Text(problem).font(.caption).foregroundStyle(.red).lineLimit(3) }
                    if s.movedIntervals > 0 {
                        Text("marks changed since the draw: \(s.movedIntervals) interval(s) need a new draw").font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            switch model.signedIn {
            case .labeler(let id): Text("Reviewer: labeler \(id.prefix(8))…").font(.caption).foregroundStyle(.secondary)
            case .nobody: TextField("Your name (the reviewer)", text: $model.typedName).textFieldStyle(.roundedBorder).controlSize(.small)
            case .unknown: Text("Reviewer: confirming the signed-in labeler…").font(.caption).foregroundStyle(.orange)
            }
            Button("Export findings for the marking pass") { model.exportFindings() }.controlSize(.small).disabled(model.draw == nil)
            Button("Boundary corrections…") { model.loadCorrections(); showCorrections = true }.controlSize(.small).disabled(model.draw == nil)
                .sheet(isPresented: $showCorrections) { corrections }
        }
        .padding(8)
    }

    /// The recorded boundary errors as proposed mark edits (amendment 1, A1.3): applied or declined one by one.
    private var corrections: some View {
        let list = model.corrections ?? .init()
        return VStack(alignment: .leading, spacing: 10) {
            Text("Boundary corrections").font(.headline)
            Text("Each boundary error the audit recorded, as an edit of the mark beside its interval. Applying one moves that mark; the interval is then audited again under a new draw.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let why = list.blocked { Label(why, systemImage: "lock").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if list.proposals.isEmpty { Text("Nothing to correct.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(list.proposals) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.recordingId) · interval \(c.intervalIndex)").font(.system(.body, design: .monospaced))
                                Text("mark \(clockText(c.markStartSec))–\(clockText(c.markEndSec)) → "
                                     + (c.edge == .leading ? "ends \(clockText(c.toSec))" : "starts \(clockText(c.toSec))\(c.movesServeContact ? ", its serve contact with it" : "")") + String(format: " (+%.1f s)", c.addedSec))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Decline") { model.decide(c, .declined, marksChanged: marksChanged) }
                            Button("Apply") { model.decide(c, .applied, marksChanged: marksChanged) }.buttonStyle(.borderedProminent)
                        }
                        .disabled(list.blocked != nil)
                    }
                    ForEach(list.notProposed, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack { Spacer(); Button("Done") { showCorrections = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 620, height: 460)
    }

    private static func progress(of s: CoverageAudit.RecordingStatus, in pass: CoverageAudit.Pass) -> Double {
        switch pass {
        case .first: return s.total == 0 ? 1 : Double(s.reviewed) / Double(s.total)
        case .repeatLook: return 1
        case .resolution: return s.unresolved == 0 ? 1 : 0
        }
    }

    /// A recording's line. In the repeat pass only the repeat's own progress: nothing of the first verdicts.
    private static func summary(of s: CoverageAudit.RecordingStatus, in pass: CoverageAudit.Pass) -> String {
        switch pass {
        case .first: return "\(s.reviewed)/\(s.total) reviewed · \(s.state.text)" + (s.findings.isEmpty ? "" : " · \(CoverageAudit.countsText(s.findings))")
        case .repeatLook: return "no second look is owed"
        case .resolution: return s.unresolved == 0 ? "nothing to resolve" : "\(s.unresolved) disagreement(s) to resolve"
        }
    }

    // MARK: - The review

    private var review: some View {
        VStack(spacing: 6) {
            if let player = model.player {
                ZoomablePlayerView(player: player, zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
                    .frame(minHeight: 280)
                    .background(Color.black)
            } else {
                ZStack { Color.black.opacity(0.85); Text(model.busy ? "Opening…" : model.status).foregroundStyle(.white).padding() }.frame(minHeight: 280)
            }
            if let interval = model.interval {
                header(interval)
                PlayingBar(model: model, interval: interval).frame(height: 34)
            }
            chips
            inspector
            TextField("Note — needed for uncertain, useful for edited footage (T to type, Return when done)", text: $model.note)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .focused($noteFocused)
                .onSubmit {
                    noteFocused = false
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    model.noteSubmitted()
                }
            Text(model.status).font(.caption).foregroundStyle(model.lastRefused ? .red : .secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
    }

    private func header(_ interval: CoverageAudit.Interval) -> some View {
        let start = CoverageAudit.seconds(interval.startTick), end = CoverageAudit.seconds(interval.endTick)
        return HStack(spacing: 10) {
            Text("\(model.recordingId ?? "") · interval \(interval.index) · \(clockText(start))–\(clockText(end)) (\(String(format: "%.1f", end - start)) s)")
                .font(.system(.body, design: .monospaced)).lineLimit(1)
            LeftToPlay(model: model, interval: interval)
            if !model.copyNote.isEmpty { Text(model.copyNote).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Picker("Speed", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach(CoverageAuditModel.rates, id: \.self) { Text($0 == 0.5 ? "0.5×" : "\(Int($0))×").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170).controlSize(.small)
            Button("Keys") { showHelp.toggle() }.controlSize(.small).popover(isPresented: $showHelp) { KeyHelp().padding() }
        }
    }

    /// The open recording's intervals in this pass, to jump between. In the review pass a chip tells its verdict;
    /// in the repeat and the resolution only whether this pass has looked.
    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.visibleIntervals, id: \.index) { interval in
                    let look = model.look(at: interval.index), moved = model.movedIndices.contains(interval.index)
                    Button { model.select(interval.index) } label: {
                        // ⚠︎ the marks moved it since the draw; … findings from a look that has not covered it yet.
                        Text("\(interval.index)" + (moved ? " ⚠︎" : look?.playedWhole == false ? " …" : ""))
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(chipColor(look?.verdict, moved: moved).opacity(interval.index == model.intervalIndex ? 0.9 : 0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(interval.index == model.intervalIndex ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 24)
    }

    private func chipColor(_ verdict: CoverageAudit.Verdict?, moved: Bool) -> Color {
        if moved { return .orange }
        guard let verdict else { return .gray }
        return model.pass == .first && verdict == .notClean ? .red : .green
    }

    private var inspector: some View {
        HStack(alignment: .top, spacing: 16) {
            if model.pass == .resolution, let index = model.intervalIndex, let file = model.file {
                // The third look has both verdicts in view.
                if let first = file.review(index) { look("First — \(first.reviewer)", first.verdict, first.findings, playedWhole: first.playedAllAtMaxRate != nil) }
                if let second = file.repeatReview(index) { look("Repeat — \(second.reviewer)", second.verdict, second.findings, playedWhole: second.playedAllAtMaxRate != nil) }
            }
            if model.interval != nil {
                let mine = model.currentLook
                look(model.pass == .first ? "Verdict" : model.pass == .repeatLook ? "Second look" : "Resolution", mine?.verdict, mine?.findings ?? [], playedWhole: mine?.playedWhole ?? true)
            }
            if let markIn = model.markIn {
                Text("finding from \(clockText(markIn))" + (model.markOut.map { " to \(clockText($0))" } ?? " …")).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
    }

    private func look(_ title: String, _ verdict: CoverageAudit.Verdict?, _ findings: [CoverageAudit.Finding], playedWhole: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold())
            Text((verdict.map { $0 == .clean ? "clean" : "not clean" } ?? "no verdict yet") + (playedWhole ? "" : " — not played whole yet")).font(.caption)
                .foregroundStyle(verdict == .clean ? Color.green : verdict == .notClean ? Color.red : Color.secondary)
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                Text(Self.line(for: f)).font(.system(.caption, design: .monospaced))
            }
        }
    }

    private static func line(for f: CoverageAudit.Finding) -> String {
        var text = f.kind.rawValue
        if let a = f.approxStartSec { text += " ~\(clockText(a))" + (f.approxEndSec.map { "–\(clockText($0))" } ?? "") }
        if let edge = f.edge { text += " (\(edge.rawValue))" }
        if let note = f.note { text += " — \(note)" }
        return text
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isActive, let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              !(window is NSPanel), !(window.firstResponder is NSText), model.draw != nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: model.togglePlay(); return true
        case 123: model.skip(shift ? -5 : -1); return true
        case 124: model.skip(shift ? 5 : 1); return true
        case 125: model.step(forward: true); return true
        case 126: model.step(forward: false); return true
        case 36, 76: Task { await model.nextToReview() }; return true
        case 51, 117: model.withdraw(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": model.setRate(0.5)
        case "2": model.setRate(1)
        case "3": model.setRate(2)
        case "4": model.setRate(3)
        case "c": model.markClean()
        case "r": model.addFinding(.missedRally, alternate: shift)
        case "s": model.addFinding(.missedServe)
        case "b": model.addFinding(.boundaryError, alternate: shift)
        case "a": model.addFinding(.nonRallyActivity)
        case "e": model.addFinding(.editedFootage)
        case "u": model.addFinding(.uncertain)
        case "i": model.setMarkIn()
        case "o": model.setMarkOut()
        case "t": noteFocused = true
        case "z": Task { await model.undo() }
        default: return false
        }
        return true
    }
}

private struct KeyHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                Text("space play / pause (again from the lead-in once it has played through) · 1 2 3 4 speed 0.5× 1× 2× 3×")
                Text("← → 1 s · ⇧ 5 s — looking again is free, but only what plays earns coverage")
                Text("C clean — only once the whole interval has played")
                Text("R missed rally (⇧R clipped by the recording's start or end) · S missed serve · B boundary error (⇧B the other mark)")
                Text("A non-rally activity · E edited footage · U uncertain (asks for a note)")
                Text("I where a finding starts · O where it ends — then its key; without them the key takes the playhead")
                Text("T type a note · Z undo the last verdict · ⌫ take back this interval's verdict")
                Text("⏎ next interval to review · ↑ ↓ previous / next interval")
            }.font(.caption)
        }
    }
}

// The player's clock moves the playhead and what has been played many times a second (thirty per second of
// recording, so ninety at 3×). Only these two views read them, each in a body of its own: read in the tab's body
// they made it lay out the whole tab — the queue's list, every interval's chip — on every tick.

/// How much of the interval is still to play in this look.
private struct LeftToPlay: View {
    let model: CoverageAuditModel
    let interval: CoverageAudit.Interval

    var body: some View {
        let left = CoverageAudit.seconds(interval.span.ticks - model.played.playedTicks(in: interval.span))
        Text(left <= 0 ? "played whole" : String(format: "%.1f s to play", left)).font(.caption).foregroundStyle(left <= 0 ? .green : .secondary)
    }
}

/// The interval's bar as it stands now.
private struct PlayingBar: View {
    let model: CoverageAuditModel
    let interval: CoverageAudit.Interval

    var body: some View {
        IntervalBar(shown: model.shown(interval), interval: interval, played: model.played.spans, playhead: model.playhead,
                    markIn: model.markIn, markOut: model.markOut, findings: model.currentLook?.findings ?? [], seek: { model.seek(to: $0) })
    }
}

/// The interval under review with its context: the interval lighter than the context, what has been played along
/// the bottom, the findings of the look on screen, the finding in the making, the playhead. Click or drag to seek.
private struct IntervalBar: View {
    let shown: ClosedRange<Double>
    let interval: CoverageAudit.Interval
    let played: [CoverageAudit.Span]
    let playhead: Double
    let markIn: Double?
    let markOut: Double?
    let findings: [CoverageAudit.Finding]
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let length = max(shown.upperBound - shown.lowerBound, 0.001)
            let x: (Double) -> CGFloat = { CGFloat(($0 - shown.lowerBound) / length) * w }
            Canvas { ctx, _ in
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 4), with: .color(.black.opacity(0.45)))
                let a = x(CoverageAudit.seconds(interval.startTick)), b = x(CoverageAudit.seconds(interval.endTick))
                ctx.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: h)), with: .color(.gray.opacity(0.45)))
                for span in played {
                    let s = max(span.startTick, interval.startTick), e = min(span.endTick, interval.endTick)
                    guard e > s else { continue }
                    ctx.fill(Path(CGRect(x: x(CoverageAudit.seconds(s)), y: h - 7, width: max(1, x(CoverageAudit.seconds(e)) - x(CoverageAudit.seconds(s))), height: 7)),
                             with: .color(.green.opacity(0.85)))
                }
                for f in findings {
                    guard let t = f.approxStartSec else { continue }
                    ctx.fill(Path(CGRect(x: x(t), y: h * 0.15, width: max(3, x(f.approxEndSec ?? t) - x(t)), height: h * 0.35)), with: .color(.red.opacity(0.8)))
                }
                if let markIn {
                    ctx.fill(Path(CGRect(x: x(markIn), y: h * 0.15, width: max(2, x(markOut ?? max(markIn, playhead)) - x(markIn)), height: h * 0.35)), with: .color(.orange.opacity(0.6)))
                }
                ctx.fill(Path(CGRect(x: x(playhead) - 1, y: 0, width: 2, height: h)), with: .color(.white))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { seek(shown.lowerBound + Double($0.location.x / max(w, 1)) * length) })
        }
    }
}
