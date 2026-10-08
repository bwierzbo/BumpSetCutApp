//
//  NextView.swift
//  RallyLab (iPhone)
//
//  Where the app opens: the round's progress, what you did today, and one
//  big card with the most useful thing to do next (from the training plan)
//  — then the few after it, and keeping their clips on the phone for when
//  there's no signal.
//

import SwiftUI

struct NextView: View {
    @Bindable var model: LabelerModel
    @Binding var path: NavigationPath
    @State private var offlineBusy = false

    var body: some View {
        let tasks = model.tasks
        let progress = model.progress
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                roundCard(progress)
                if let first = tasks.first {
                    NavigationLink(value: first) { taskCard(first, big: true) }.buttonStyle(.plain)
                } else {
                    ContentUnavailableView("Nothing to do", systemImage: "checkmark.seal",
                                           description: Text("Every video's rallies are marked and the round has its frames. Sync from RallyLab on the Mac for more."))
                }
                if tasks.count > 1 {
                    Text("Up next").font(.headline)
                    ForEach(tasks.dropFirst().prefix(5)) { task in
                        NavigationLink(value: task) { taskCard(task, big: false) }.buttonStyle(.plain)
                    }
                }
                offlineCard(tasks)
            }
            .padding()
        }
        .refreshable { await model.reload() }
        .onAppear { model.prefetch() }
        .navigationTitle("Next")
        .toolbar {
            if model.isOffline || !model.outbox.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Label(model.isOffline ? "Offline · \(model.outbox.count) to send" : "\(model.outbox.count) to send",
                          systemImage: model.isOffline ? "wifi.slash" : "arrow.up.circle")
                        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func roundCard(_ progress: PlanProgress) -> some View {
        let round = model.currentRound
        let target = round?.frames ?? max(progress.frames, 1)
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle().trim(from: 0, to: min(1, Double(progress.frames) / Double(target)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(min(100, progress.frames * 100 / target))%").font(.headline.monospacedDigit())
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text(round.map { "Round \($0.number)" } ?? "Every round trained").font(.headline)
                Text("\(progress.frames.formatted()) of \(target.formatted()) frames").font(.callout.monospacedDigit())
                Text("Today: \(model.today.rallies) rallies · \(model.today.frames.formatted()) frames · \(model.today.videos) videos finished")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func taskCard(_ task: LabelerModel.LabelTask, big: Bool) -> some View {
        let (title, detail, icon): (String, String, String) = {
            switch task {
            case .review(let v):
                let open = model.openFound(in: v).count
                return ("Check the rallies", open > 0 ? "\(open) found rallies to confirm, then skim for missed ones" : "Skim for missed rallies and finish",
                        "checklist")
            case .track(let v, let r):
                if let t = model.unfinishedTrack(of: r, in: v) { return ("Finish tracking a rally", Self.progress(t), "scope") }
                if let t = LocalStore.trim(of: r, in: v) {
                    return ("Finish tracking a rally", "\(RallyTimesView.clock(t.start)) – \(RallyTimesView.clock(t.end)) · trimmed, tracking not started", "scope")
                }
                return ("Track a rally", "\(RallyTimesView.clock(r.start)) – \(RallyTimesView.clock(r.end)) · about \(Int((r.end - r.start + 2 * TrackedRally.margin) * TrackSession.frameRate)) frames",
                        "scope")
            }
        }()
        return HStack(spacing: 14) {
            Image(systemName: icon).font(big ? .largeTitle : .title2).foregroundStyle(Color.accentColor).frame(width: big ? 48 : 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(big ? .title3.bold() : .headline)
                Text(task.video.name).font(.callout.monospaced()).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(task.video.surface.rawValue, systemImage: task.video.surface.icon)
                    if task.video.split == "val" { Text("val").foregroundStyle(.purple) }
                    if LocalStore.hasClip(task.video) {
                        Label("on phone", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
                    } else if let p = model.downloads[task.video.id] {
                        Label("downloading \(Int(p * 100))%", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(big ? 18 : 12)
        .background(big ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func offlineCard(_ tasks: [LabelerModel.LabelTask]) -> some View {
        let next = tasks.prefix(5)
        let have = next.filter { LocalStore.hasClip($0.video) }.count
        return VStack(alignment: .leading, spacing: 8) {
            Label("No signal?", systemImage: "airplane").font(.headline)
            Text("\(have) of the next \(next.count) tasks' clips are on this phone. Edits made offline are sent when you're back online.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    offlineBusy = true
                    Task { await model.makeOffline(next: 5); offlineBusy = false }
                } label: { Label("Keep the next 5 on this phone", systemImage: "arrow.down.circle") }
                    .disabled(offlineBusy || have == next.count)
                if offlineBusy { ProgressView() }
                Spacer()
                Button("Free space") { model.removeFinishedClips() }.font(.caption)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

extension NextView {
    /// Where a rally you left part way through stands.
    static func progress(_ t: LabelTrack) -> String {
        let n = t.points.points.count
        let at = LocalStore.position(t.id).flatMap { p in t.points.points.firstIndex { abs($0.time - p) < 0.002 } }
        let place = at.map { "back to frame \($0 + 1) of \(n)" } ?? "\(n) frames"
        return "\(RallyTimesView.clock(t.start)) – \(RallyTimesView.clock(t.end)) · \(place) · \(t.toCheck == 0 ? "nothing" : "\(t.toCheck)") left to check"
    }
}

extension LabelerModel.LabelTask {
    /// The screen for this task.
    @MainActor @ViewBuilder
    func destination(_ model: LabelerModel) -> some View {
        switch self {
        case .review(let v): RallyReviewView(model: model, video: v)
        case .track(let v, let r): TrackTaskView(model: model, video: v, span: r)
        }
    }
}
