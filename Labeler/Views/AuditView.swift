//
//  AuditView.swift
//  Labeler
//
//  Audit mode: the coverage-audit pilot, one interval at a time, for one hand in portrait.
//  The video has no system controls (a scrub there would bypass what earns viewing credit);
//  no ball path, detector output or found rally is drawn anywhere on this screen.
//

import SwiftUI

struct AuditView: View {
    @Bindable var audit: AuditModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var finding: CoverageAudit.FindingKind?

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
                            coverageBar
                            transport
                            verdicts
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
        .sheet(item: $finding) { kind in
            FindingSheet(audit: audit, kind: kind) { finding = nil }
                .presentationDetents([.medium, .large])
        }
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

    /// The two boundary errors, given at the playhead: the stretch of the interval the neighbouring mark should have covered.
    private var trimButtons: some View {
        HStack(spacing: 10) {
            trimButton("Trim start to here", "the rally before is still going", .leading)
            trimButton("Trim end from here", "the next serve is already hit", .trailing)
        }
    }

    private func trimButton(_ title: String, _ why: String, _ edge: CoverageAudit.Edge) -> some View {
        Button { audit.trim(edge) } label: {
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
                    Button { audit.pause(); finding = kind } label: {
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

extension CoverageAudit.FindingKind: Identifiable { var id: String { rawValue } }

/// A finding's details: an approximate time (the playhead, to the second), an edge where the kind has one, a note.
private struct FindingSheet: View {
    let audit: AuditModel
    let kind: CoverageAudit.FindingKind
    let done: () -> Void
    @State private var start = 0.0
    @State private var hasEnd = false
    @State private var end = 0.0
    @State private var edge: CoverageAudit.Edge?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("About when (to the second)") {
                    Stepper(value: $start, in: range, step: 1) { Text("Starts \(clockText(start))") }
                    Toggle("Ends within the interval", isOn: $hasEnd)
                    if hasEnd { Stepper(value: $end, in: start...range.upperBound, step: 1) { Text("Ends \(clockText(end))") } }
                }
                if !kind.edges.isEmpty {
                    Section("Clipped by the recording's") {
                        Picker("Edge", selection: $edge) {
                            Text("—").tag(CoverageAudit.Edge?.none)
                            ForEach(kind.edges, id: \.self) { e in Text(e.rawValue).tag(Optional(e)) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section(kind == .uncertain ? "Note (required: what could not be told)" : "Note (optional)") {
                    TextField("Note", text: $note, axis: .vertical).lineLimit(2...5)
                }
            }
            .navigationTitle(AuditView.title(kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        audit.give(.finding(CoverageAudit.Finding(kind: kind, approxStartSec: start, approxEndSec: hasEnd ? end : nil, edge: edge,
                                                                  note: trimmed.isEmpty ? nil : trimmed)))
                        done()
                    }
                    .disabled(kind == .uncertain && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            start = min(max(audit.playhead.rounded(), range.lowerBound), range.upperBound)
            end = start
        }
    }

    /// The times a finding may name: the interval with its second of context either side.
    private var range: ClosedRange<Double> {
        guard let interval = audit.interval else { return 0...0 }
        let a = max(0, (CoverageAudit.seconds(interval.startTick) - CoverageAudit.contextSec).rounded(.up))
        let b = (CoverageAudit.seconds(interval.endTick) + CoverageAudit.contextSec).rounded(.down)
        return a...max(a, b)
    }

}
