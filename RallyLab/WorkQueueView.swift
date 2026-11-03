//
//  WorkQueueView.swift
//  RallyLab
//
//  The Queue tab (RallyLab 2.0, phase 1): every labeling task the project
//  has, by kind and state, with what the annotation files say about each,
//  and a way to the tab that does the work. Small on purpose: the existing
//  labeling tabs stay where they are; this is the one place that shows what
//  is done and what is pending.
//

import SwiftUI

struct WorkQueueView: View {
    let model: WorkQueueModel
    let isActive: Bool
    /// Take the person to the tab that labels this kind, on this recording.
    let open: (WorkQueue.Kind, String) -> Void
    @State private var selection: WorkQueue.Task.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let index = model.index, !index.problems.isEmpty {
                ForEach(index.problems, id: \.self) { Text("⚠️ \($0)").font(.caption).foregroundStyle(.orange) }
            }
            table
            footer
        }
        .padding(12)
        .onChange(of: isActive) { _, active in if active, model.file == nil, model.problem == nil { model.load() } }
        .onAppear { if model.file == nil { model.load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(WorkQueue.Kind.allCases, id: \.self) { kind in
                    let tasks = model.file?.tasks(kind) ?? []
                    if !tasks.isEmpty || kind != .contactLabels {
                        KindTile(kind: kind, tasks: tasks, selected: model.filterKind == kind) {
                            model.filterKind = model.filterKind == kind ? nil : kind
                        }
                    }
                }
                Spacer()
                if let index = model.index {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(index.sources.count) sources · \(index.groups) groups").font(.caption.bold())
                        Text("\(index.count(.admitted)) admitted · \(index.count(.withheld)) withheld · \(index.count(.pendingIngest)) pending · \(index.count(.unidentified)) unidentified")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Picker("State", selection: Binding(get: { model.filterState }, set: { model.filterState = $0 })) {
                    Text("Any state").tag(WorkQueue.State?.none)
                    ForEach(WorkQueue.State.allCases, id: \.self) { Text($0.title).tag(WorkQueue.State?.some($0)) }
                }
                .frame(width: 170)
                TextField("Search recordings", text: Binding(get: { model.search }, set: { model.search = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshing || model.root == nil)
                    .help("Reconcile the queue with the project's annotation files and the source index. Writes tasks/work-queue.json.")
            }
        }
    }

    private var table: some View {
        Table(model.visible, selection: $selection) {
            TableColumn("Recording") { t in
                Text(t.video).font(.system(.body, design: .monospaced)).lineLimit(1)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Kind") { t in Text(t.kind.title) }.width(110)
            TableColumn("State") { t in StateBadge(state: t.state) }.width(110)
            TableColumn("What the files say") { t in
                Text(t.observed?.summary ?? "not reconciled yet").foregroundStyle(.secondary).lineLimit(2)
            }
            .width(min: 240, ideal: 420)
            TableColumn("Reason") { t in Text(t.reason ?? "").foregroundStyle(.secondary).lineLimit(2) }.width(min: 160, ideal: 300)
            TableColumn("Split") { t in Text(model.source(of: t)?.split.rawValue ?? "").foregroundStyle(.secondary) }.width(100)
            TableColumn("Updated") { t in Text(t.updatedAt).font(.caption).foregroundStyle(.tertiary) }.width(150)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let t = model.visible.first(where: { $0.id == selection }) {
                Button("Open in \(tabName(t.kind))") { open(t.kind, t.video) }
                    .disabled(t.kind == .contactLabels || !t.state.isActionable)
                if t.state == .failed { Button("Retry") { model.retry(t.id) } }
                if t.state == .cancelled { Button("Reopen") { model.reopen(t.id) } }
                else { Button("Cancel task") { model.cancel(t.id) } }
                if let o = t.observed {
                    Text(details(o)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let at = model.lastRefreshed { Text(at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
        }
    }

    private func tabName(_ kind: WorkQueue.Kind) -> String {
        switch kind {
        case .rallyBoundaries: return "Review"
        case .ballTracks: return "Track"
        case .netCorners: return "Net labels"
        case .contactLabels: return "Contacts"
        }
    }

    private func details(_ o: WorkQueue.Observed) -> String {
        var parts: [String] = []
        if let d = o.declaredComplete { parts.append(d ? "legacy marks declared complete (unverified)" : "legacy marks not declared complete") }
        if let c = o.verifiedCoverage { parts.append(String(format: "verified coverage %.0f%%", c * 100)) }
        if let h = o.humanLabeled { parts.append("\(h) human-labeled") }
        if let m = o.machineProposed, m > 0 { parts.append("\(m) machine proposals (not labels)") }
        if let open = o.open, open > 0 { parts.append("\(open) open") }
        if o.proposalPending == true { parts.append("proposal pending") }
        return parts.joined(separator: " · ")
    }
}

private struct KindTile: View {
    let kind: WorkQueue.Kind
    let tasks: [WorkQueue.Task]
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.caption.bold())
                let complete = tasks.filter { $0.state == .complete }.count
                let blocked = tasks.filter { $0.state == .blocked }.count
                Text("\(complete) / \(tasks.count - blocked) complete").font(.title3.monospacedDigit())
                Text("\(tasks.filter { $0.state == .inProgress }.count) in progress · \(tasks.filter { $0.state == .needsReview }.count) to review · \(tasks.filter { $0.state == .ready || $0.state == .pending }.count) waiting · \(blocked) blocked · \(tasks.filter { $0.state == .failed }.count) failed")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(minWidth: 220, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StateBadge: View {
    let state: WorkQueue.State

    var body: some View {
        Text(state.title)
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .complete: return .green
        case .inProgress: return .blue
        case .needsReview: return .purple
        case .ready, .pending: return .secondary
        case .blocked, .quarantined: return .orange
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}
