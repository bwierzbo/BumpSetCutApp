//
//  AuditView.swift
//  Labeler
//
//  Audit mode: the coverage-audit pilot, one interval at a time, for one hand in portrait.
//  The video has no system controls (a scrub there would bypass what earns viewing credit);
//  a finding is placed by scrubbing a bar of its own, which is a jump and earns none;
//  no ball path, detector output or found rally is drawn anywhere on this screen.
//

import SwiftUI

struct AuditView: View {
    @Bindable var audit: AuditModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if audit.audit == nil {
                    ContentUnavailableView("No audit loaded", systemImage: "checklist",
                                           description: Text(audit.syncNote ?? "Pull down to load the published draw."))
                } else {
                    passPicker
                    progress
                    if let position = audit.position {
                        intervalTitle(position)
                        footage
                        if case .ready = audit.footage {
                            if let marking = audit.marking {
                                MarkingPanel(audit: audit, marking: marking)
                            } else {
                                coverageBar
                                transport
                                verdicts
                            }
                        }
                        looks
                    } else {
                        ContentUnavailableView("Nothing left in this pass", systemImage: "checkmark.circle",
                                               description: Text(audit.pass == .repeatLook ? "Your own repeat of an interval opens 24 hours after its first verdict." : ""))
                        // The last verdict can still be taken back from here (Undo reopens its interval).
                        if !audit.undoStack.isEmpty {
                            Button { audit.undo() } label: { Label("Undo the last verdict", systemImage: "arrow.uturn.backward").frame(minHeight: 44) }
                                .buttonStyle(.bordered)
                        }
                    }
                    conflicts
                    if let message = audit.message {
                        Text(message).font(.callout).foregroundStyle(audit.refused ? .red : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await audit.refresh() }
        .navigationTitle("Audit")
        .navigationBarTitleDisplayMode(.inline)
        .task { await audit.refresh(); if audit.footage == .none, let p = audit.position { audit.go(to: p, play: false) } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { audit.leftApp() } }
        // A recording withheld (or its copy withdrawn) while it is open stops here at once.
        .onChange(of: audit.labeler.snapshot.withheld) { _, _ in audit.recheck() }
        .onChange(of: audit.labeler.snapshot.videos) { _, _ in audit.recheck() }
        .onDisappear { audit.leave() }
    }

    // MARK: - Top

    private var header: some View {
        HStack {
            Text(audit.audit.map { "Draw \($0.drawId)" } ?? "Coverage audit").font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            if audit.syncing { ProgressView().controlSize(.small) }
            if let pending = audit.totals?.pending, pending > 0 {
                Label("\(pending) to send", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let note = audit.syncNote { Text(note).font(.caption2).foregroundStyle(.secondary).offset(y: 16) }
        }
    }

    private var passPicker: some View {
        Picker("Pass", selection: Binding(get: { audit.pass }, set: { audit.setPass($0) })) {
            Text("First look").tag(CoverageAudit.Pass.first)
            Text("Blind repeat").tag(CoverageAudit.Pass.repeatLook)
            Text("Resolve").tag(CoverageAudit.Pass.resolution)
        }
        .pickerStyle(.segmented)
        .padding(.top, 8)
    }

    private var progress: some View {
        let t = audit.totals ?? .init()
        let findings = CoverageAudit.countsText(t.findings)
        let line = switch audit.pass {
        case .first: "\(t.reviewed) of \(t.total) intervals reviewed · \(t.left) to go · \(t.recordingsDone) of \(t.recordings - t.unavailable) recordings done"
        case .repeatLook: "\(t.left) second look(s) to go · \(t.recordingsDone) of \(t.recordings - t.unavailable) recordings done"
        case .resolution: t.left == 0 ? "nothing to resolve" : "\(t.left) disagreement(s) to resolve"
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(line).font(.subheadline.weight(.medium))
            Text((t.findingsHidden ? "findings hidden during the blind repeat" : "findings: \(findings)") + (t.unavailable > 0 ? " · \(t.unavailable) recording(s) not available on this phone" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func intervalTitle(_ p: CoverageAuditPhone.Position) -> some View {
        let interval = audit.interval
        let count = audit.audit?.draw.draw.recording(p.recordingId)?.intervals.count ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(p.recordingId).font(.headline.monospaced()).lineLimit(1).minimumScaleFactor(0.7)
            if let interval {
                Text("interval \(p.index + 1) of \(count) · \(clockText(CoverageAudit.seconds(interval.startTick)))–\(clockText(CoverageAudit.seconds(interval.endTick)))"
                     + String(format: " (%.0f s)", CoverageAudit.seconds(interval.span.ticks)))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Video

    @ViewBuilder private var footage: some View {
        switch audit.footage {
        case .none:
            EmptyView()
        case .unavailable(let why):
            VStack(spacing: 8) {
                Label(why, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                Button("Skip to the next interval") { audit.next(play: false) }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .needsDownload:
            VStack(spacing: 8) {
                Text("The recording's copy is not on this phone. It is checked frame by frame against the original before review.")
                    .font(.callout).foregroundStyle(.secondary)
                Button { Task { await audit.download() } } label: { Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading:
            ProgressView(value: audit.position.flatMap { audit.video($0.recordingId) }.flatMap { audit.labeler.downloads[$0.id] } ?? 0) { Text("Downloading…") }
        case .checking:
            ProgressView("Checking the copy's frames against the original…")
        case .ready:
            PlayerLayer(player: audit.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { audit.togglePlay() }
        }
    }

    /// The shown stretch: the interval between its second of context either side, what has played of it, and the playhead.
    private var coverageBar: some View {
        GeometryReader { geo in
            if let shown = audit.shown, let interval = audit.interval, shown.upperBound > shown.lowerBound {
                let width = geo.size.width, span = shown.upperBound - shown.lowerBound
                let x = { (t: Double) -> CGFloat in CGFloat((t - shown.lowerBound) / span) * width }
                let a = CoverageAudit.seconds(interval.startTick), b = CoverageAudit.seconds(interval.endTick)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Rectangle().fill(.blue.opacity(0.25)).frame(width: max(0, x(b) - x(a))).offset(x: x(a))
                    ForEach(Array(audit.tracker.played.spans.enumerated()), id: \.offset) { _, s in
                        let s0 = max(a, CoverageAudit.seconds(s.startTick)), s1 = min(b, CoverageAudit.seconds(s.endTick))
                        if s1 > s0 { Rectangle().fill(.green).frame(width: x(s1) - x(s0)).offset(x: x(s0)) }
                    }
                    ForEach(Array(audit.trims.enumerated()), id: \.offset) { _, f in
                        if let t0 = f.approxStartSec, let t1 = f.approxEndSec, t1 > t0 {
                            Rectangle().fill(.orange).frame(width: x(t1) - x(t0)).offset(x: x(t0))
                        }
                    }
                    Rectangle().fill(.primary).frame(width: 2).offset(x: min(width - 2, max(0, x(audit.playhead))))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 10)
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button { audit.back(5) } label: { Image(systemName: "gobackward.5").font(.title2).frame(width: 52, height: 52) }
                .accessibilityLabel("Back 5 seconds (earns no viewing credit)")
            Button { audit.togglePlay() } label: {
                Image(systemName: audit.isPlaying ? "pause.fill" : "play.fill").font(.title).frame(width: 72, height: 56)
            }
            .buttonStyle(.borderedProminent)
            Picker("Rate", selection: Binding(get: { audit.rate }, set: { audit.setRate($0) })) {
                Text("½×").tag(Float(0.5)); Text("1×").tag(Float(1)); Text("2×").tag(Float(2)); Text("3×").tag(Float(3))
            }
            .pickerStyle(.segmented)
        }
    }

    /// The two boundary errors: the stretch of the interval the neighbouring mark should have covered, placed by scrubbing.
    private var trimButtons: some View {
        HStack(spacing: 10) {
            trimButton("Trim start", "the rally before is still going", .leading)
            trimButton("Trim end", "the next serve is already hit", .trailing)
        }
    }

    private func trimButton(_ title: String, _ why: String, _ edge: CoverageAudit.Edge) -> some View {
        Button { audit.beginMarking(.boundaryError, trim: edge) } label: {
            VStack(spacing: 2) {
                Label(title, systemImage: "scissors").font(.callout.weight(.semibold))
                Text(why).font(.caption2)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }

    // MARK: - Verdicts

    private var verdicts: some View {
        let left = audit.leftToPlay ?? 0
        return VStack(spacing: 10) {
            if audit.canComplete {
                big("Played whole — complete this look", "checkmark.seal", .blue) { audit.give(.playedWhole) }
            }
            big(left > 0.05 ? String(format: "Clean — watch %.0f s more", left.rounded(.up)) : "Clean", "checkmark.circle.fill", .green) {
                audit.give(.clean)
            }
            .disabled(left > 0.05)
            trimButtons
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(CoverageAudit.FindingKind.allCases.filter { $0 != .boundaryError }, id: \.self) { kind in
                    Button { audit.beginMarking(kind) } label: {
                        Text(Self.title(kind)).font(.callout.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .tint(kind == .missedRally || kind == .missedServe ? .red : .orange)
                }
            }
            HStack {
                Button { audit.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward").frame(minHeight: 44) }
                    .disabled(audit.undoStack.isEmpty)
                Spacer()
                Button { audit.next(play: true) } label: { Label("Next interval", systemImage: "forward.end").frame(minHeight: 44) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func big(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.headline).frame(maxWidth: .infinity, minHeight: 56) }
            .buttonStyle(.borderedProminent).tint(tint)
    }

    static func title(_ kind: CoverageAudit.FindingKind) -> String {
        switch kind {
        case .missedRally: return "Missed rally"
        case .missedServe: return "Missed serve"
        case .boundaryError: return "Boundary error"
        case .nonRallyActivity: return "Non-rally activity"
        case .editedFootage: return "Edited footage"
        case .uncertain: return "Uncertain"
        }
    }

    /// The looks this pass may show (never the first verdict in the blind repeat).
    @ViewBuilder private var looks: some View {
        let shown = audit.looks
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, look in Text(Self.describe(look)).font(.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// What a boundary error trims off the interval: which end, and how long.
    private static func trimText(_ f: CoverageAudit.Finding) -> String {
        guard f.kind == .boundaryError, let edge = f.edge, let a = f.approxStartSec, let b = f.approxEndSec else { return "" }
        return String(format: " — %.1f s off the %@", b - a, edge == .leading ? "start" : "end")
    }

    static func describe(_ look: CoverageAuditSync.Look) -> String {
        func text(_ pass: String, _ verdict: CoverageAudit.Verdict, _ findings: [CoverageAudit.Finding], _ whole: Double?) -> String {
            "\(pass): \(verdict.rawValue)" + (findings.isEmpty ? "" : " — " + findings.map { $0.kind.rawValue + trimText($0) + ($0.note.map { " (\($0))" } ?? "") }.joined(separator: ", "))
                + (whole == nil ? " · not yet played whole" : "")
        }
        switch look {
        case .first(let r): return text("First look", r.verdict, r.findings, r.playedAllAtMaxRate)
        case .repeatLook(let r): return text("Repeat", r.verdict, r.findings, r.playedAllAtMaxRate)
        case .resolution(let r): return text("Resolution", r.verdict, r.findings, r.playedAllAtMaxRate)
        }
    }

    @ViewBuilder private var conflicts: some View {
        ForEach(audit.conflicts) { open in
            let c = open.conflict
            VStack(alignment: .leading, spacing: 6) {
                Text("\(open.recordingId), interval \(c.slot.index + 1) (\(c.slot.pass.rawValue)) was changed on another device too. Theirs is kept; this phone's was: "
                     + (c.mine.map(Self.describe) ?? "taken back")).font(.caption)
                HStack {
                    Button("Open") { audit.go(to: .init(pass: audit.pass, recordingId: open.recordingId, index: c.slot.index), play: false) }
                    Button("Keep theirs") { audit.resolve(open, keepMine: false) }
                    Button("Use this phone's") { audit.resolve(open, keepMine: true) }
                }
                .buttonStyle(.bordered)
            }
            .padding(8)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }

}

/// Placing a finding: the reviewer drags the bar (the footage follows, paused), says where the finding starts and
/// where it ends, and saves. It takes the place of the transport and the verdicts, so the video stays in view.
private struct MarkingPanel: View {
    @Bindable var audit: AuditModel
    let marking: CoverageAuditPhone.Marking

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                HStack {
                    Text("Drag the bar to find the moment, then mark it.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(clockText(audit.playhead)).font(.callout.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            scrubBar
            nudges
            HStack(spacing: 10) {
                if !marking.startIsFixed {
                    edgeButton(marking.trim == .trailing ? "The next serve is hit here" : "Starts here", clockText(marking.start)) { audit.markStart() }
                }
                if !marking.endIsFixed {
                    edgeButton(marking.trim == .leading ? "The rally before ends here" : "Ends here", marking.end.map(clockText) ?? "not set") { audit.markEnd() }
                }
            }
            if marking.trim == nil, marking.end != nil {
                Button("Only where it starts (no end)") { audit.clearMarkEnd() }.font(.caption)
            }
            if marking.trim == nil, !marking.kind.edges.isEmpty {
                Picker("Clipped by the recording's", selection: Binding(get: { marking.edge }, set: { audit.marking?.edge = $0 })) {
                    Text("Not clipped").tag(CoverageAudit.Edge?.none)
                    ForEach(marking.kind.edges, id: \.self) { e in Text("Clipped by the recording's \(e.rawValue)").tag(Optional(e)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField(marking.kind == .uncertain ? "Note (required: what could not be told)" : "Note (optional)",
                      text: Binding(get: { marking.note }, set: { audit.marking?.note = $0 }), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            if let problem = marking.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button(role: .cancel) { audit.cancelMarking() } label: { Text("Cancel").frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.bordered)
                Button { audit.saveMarking() } label: { Label("Save", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.borderedProminent)
                    .disabled(marking.problem != nil)
            }
        }
    }

    private var title: String {
        switch marking.trim {
        case .leading: return "Trim start: where does the rally before really end?"
        case .trailing: return "Trim end: where is the next serve hit?"
        default: return AuditView.title(marking.kind) + ": where is it?"
        }
    }

    /// The shown stretch, tall enough for a thumb: the interval, the stretch marked so far, and the playhead under the finger.
    private var scrubBar: some View {
        GeometryReader { geo in
            if let shown = audit.shown, let interval = audit.interval, shown.upperBound > shown.lowerBound {
                let width = geo.size.width, span = shown.upperBound - shown.lowerBound
                let x = { (t: Double) -> CGFloat in CGFloat((t - shown.lowerBound) / span) * width }
                let a = CoverageAudit.seconds(interval.startTick), b = CoverageAudit.seconds(interval.endTick)
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(.blue.opacity(0.25)).frame(width: max(0, x(b) - x(a))).offset(x: x(a))
                    Rectangle().fill(.orange.opacity(0.8)).frame(width: max(3, x(marking.end ?? marking.start) - x(marking.start))).offset(x: x(marking.start))
                    Rectangle().fill(.primary).frame(width: 3).offset(x: min(width - 3, max(0, x(audit.playhead) - 1.5)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    audit.scrub(to: shown.lowerBound + Double(min(max(drag.location.x / width, 0), 1)) * span)
                })
            }
        }
        .frame(height: 44)
        .accessibilityLabel("Scrub bar")
    }

    /// Fine steps either side of the playhead, and play: a long interval is coarser under a thumb than a finding needs.
    private var nudges: some View {
        HStack(spacing: 8) {
            nudge("−1 s", -1)
            nudge("−0.1", -0.1)
            Button { audit.togglePlay() } label: { Image(systemName: audit.isPlaying ? "pause.fill" : "play.fill").frame(maxWidth: .infinity, minHeight: 40) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(audit.isPlaying ? "Pause" : "Play")
            nudge("+0.1", 0.1)
            nudge("+1 s", 1)
        }
    }

    private func nudge(_ title: String, _ by: Double) -> some View {
        Button { audit.scrub(to: audit.playhead + by) } label: { Text(title).font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 40) }
            .buttonStyle(.bordered)
    }

    private func edgeButton(_ title: String, _ time: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(time).font(.caption.monospacedDigit())
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }
}
