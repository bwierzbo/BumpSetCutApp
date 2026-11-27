//
//  HomeView.swift
//  RallyLab (iPhone)
//
//  Where the app opens: what needs you, first — the most useful video to
//  mark (a new camera group before more of a covered one; WorkPlan) or
//  rally to track, the labels waiting for a check, the coverage audit's
//  intervals (the lead's), the recordings whose footage type nobody has
//  said, the ones whose marks an audit finding says to fix — each a card
//  that opens its tool. Then what is left in all and what waits on the
//  Mac, the camera groups marked and audited per surface, how far the
//  marking and the round are, the tasks after the first, and keeping
//  their clips on the phone for when there's no signal.
//

import SwiftUI

struct HomeView: View {
    @Bindable var model: LabelerModel
    /// The lead's coverage audit as this phone holds it (nothing is loaded or opened from here).
    let audit: AuditModel
    @Binding var path: NavigationPath
    /// Shows one of the other tabs: a card's tool.
    let show: (MainTabs.Selection) -> Void
    @State private var offlineBusy = false
    @State private var skipping: LabelVideo?

    var body: some View {
        let tasks = model.tasks
        let progress = model.progress
        let work = model.workPlan
        let opensGroup = Set(work.items(.mark).filter(\.newGroup).map(\.name))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let first = tasks.first {
                    NavigationLink(value: first) { taskCard(first, big: true, opensGroup: opensGroup) }.buttonStyle(.plain)
                    Button { skipping = first.video } label: { Label("Skip this video…", systemImage: "arrow.uturn.forward") }
                        .font(.callout).padding(.horizontal, 4)
                } else {
                    ContentUnavailableView("Nothing to do", systemImage: "checkmark.seal",
                                           description: Text("Every video's rallies are marked and the round has its frames. Sync from RallyLab on the Mac for more."))
                }
                tools(work)
                Text("What's left").font(.headline)
                workCard(work)
                groupsCard(work)
                Text("Progress").font(.headline)
                markingCard(model.marking)
                roundCard(progress)
                if tasks.count > 1 {
                    Text("Up next").font(.headline)
                    ForEach(tasks.dropFirst().prefix(5)) { task in
                        NavigationLink(value: task) { taskCard(task, big: false, opensGroup: opensGroup) }.buttonStyle(.plain)
                    }
                }
                offlineCard(tasks)
            }
            .padding()
        }
        .refreshable { await model.reload() }
        .onAppear { model.prefetch() }
        .backlogDialog(video: $skipping, model: model)
        .navigationTitle("Home")
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

    /// The other tools, each with what it has waiting: the checks, the audit (a lead's), the footage types to say,
    /// the marks an audit finding says to fix.
    @ViewBuilder
    private func tools(_ work: WorkPlan.Plan) -> some View {
        let fix = work.items(.fix).count
        let checks = model.rallyChecks().count + model.reviewItems([.crop, .noBall]).count
        let footage = model.footageTypeToConfirm.count
        VStack(spacing: 10) {
            toolCard("Check labels", checks == 0 ? "Nothing waiting for a check" : "Found rallies and uncertain frames to confirm",
                     icon: "checkmark.rectangle.stack", waiting: checks) { show(.review) }
            if model.snapshot.lead {
                let (detail, left) = auditState
                toolCard("Coverage audit", detail, icon: "checklist", waiting: left) { show(.audit) }
            }
            if footage > 0 {
                toolCard("Footage type", "Marked through; say whether each is continuous or edited", icon: "film.stack", waiting: footage) { show(.videos) }
            }
            if fix > 0 {
                toolCard("Fix marks", "The audit found something in their unmarked time: Videos → the recording → Edit rally times (a boundary trim: the Mac's Audit tab)",
                         icon: "pencil.and.outline", waiting: fix) { show(.videos) }
            }
        }
    }

    /// Everything left, in numbers: the marking that can train, the marking for scoring only, and what waits on
    /// the Mac rather than on you.
    private func workCard(_ work: WorkPlan.Plan) -> some View {
        let mark = work.items(.mark), held = work.items(.mark, held: true), draw = work.items(.draw)
        return VStack(alignment: .leading, spacing: 8) {
            workRow("flag", "\(mark.count) to mark",
                    mark.isEmpty ? "Every recording that can train is marked through."
                    : "\(work.markingSeconds > 0 ? "About \(MarkingProgress.clock(work.markingSeconds)) of footage · " : "")\(work.newGroups) open a new camera group")
            if !held.isEmpty {
                workRow("lock", "\(held.count) to mark for scoring", "Withheld from every model: marked by hand, after the others, never training data.")
            }
            if work.auditKnown, !draw.isEmpty {
                workRow("desktopcomputer", "\(draw.count) wait on the Mac", "Marked and continuous: they join the next coverage-audit draw.")
            }
            if work.backlog > 0 {
                workRow("tray", "\(work.backlog) set aside", "The backlog: Videos → Backlog puts one back.")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func workRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.monospacedDigit().weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Camera groups per surface, of the recordings that can train: in all, with a recording marked through, and
    /// with one audited clean (once the Mac has published where the audits stand).
    private func groupsCard(_ work: WorkPlan.Plan) -> some View {
        let published = model.projectState?.work
        let t = work.total
        return VStack(alignment: .leading, spacing: 10) {
            Text("Camera groups").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Groups").gridColumnAlignment(.trailing)
                    Text("Marked").gridColumnAlignment(.trailing)
                    if work.auditKnown { Text("Audited clean").gridColumnAlignment(.trailing) }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(work.surfaces, id: \.surface) { s in
                    GridRow {
                        Label(s.surface, systemImage: LabelSurface(rawValue: s.surface)?.icon ?? "film").font(.callout)
                        Text("\(s.groups)")
                        Text("\(s.groupsMarked)").foregroundStyle(s.groupsMarked == 0 ? Color.red : .primary)
                        if work.auditKnown { Text("\(s.groupsClean)").foregroundStyle(s.groupsClean == 0 ? Color.red : .primary) }
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("\(t.marked) of \(t.recordings) recordings marked · \(t.continuous) continuous" + (work.auditKnown ? " · \(t.clean) audited clean" : ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(published == nil ? "The Mac has not published the camera groups yet: each recording counts as its own group, and the audit is not counted, until RallyLab on the Mac next syncs."
                 : "Groups and audit states as RallyLab on the Mac last published them; marking and footage types as this phone has them now.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Where the audit stands on this phone, in the pass it is in, and the intervals that pass still owes a look.
    private var auditState: (detail: String, left: Int) {
        guard let t = audit.totals else { return (audit.syncNote ?? "Open it to load the published draw", 0) }
        let pending = t.pending > 0 ? " · \(t.pending) to send" : ""
        switch audit.pass {
        case .first: return ("\(t.reviewed) of \(t.total) intervals reviewed" + pending, t.left)
        case .repeatLook: return ((t.left == 0 ? "No second look is due" : "Second looks are due") + pending, t.left)
        case .resolution: return ((t.left == 0 ? "Nothing to resolve" : "Disagreements to resolve") + pending, t.left)
        }
    }

    private func toolCard(_ title: String, _ detail: String, icon: String, waiting: Int, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
                if waiting > 0 {
                    Text("\(waiting)").font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(minHeight: 44)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Videos marked through, left, and the footage still to watch, per surface.
    private func markingCard(_ marking: MarkingProgress) -> some View {
        let t = marking.total
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                    Circle().trim(from: 0, to: t.fraction)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int((t.fraction * 100).rounded()))%").font(.headline.monospacedDigit())
                }
                .frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Marking the rallies").font(.headline)
                    Text("\(t.marked) of \(t.videos) videos marked · \(t.left) left").font(.callout.monospacedDigit())
                    Text(t.left == 0 ? "Every video is marked through."
                         : t.footageLeft > 0 ? "About \(MarkingProgress.clock(t.footageLeft)) of footage to watch · \(t.rallies) rallies marked so far"
                         : "\(t.rallies) rallies marked so far")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                ForEach(marking.surfaces, id: \.surface) { surface, b in
                    VStack(alignment: .leading, spacing: 3) {
                        Label("\(b.marked)/\(b.videos)", systemImage: LabelSurface(rawValue: surface)?.icon ?? "film")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        ProgressView(value: b.fraction).tint(b.marked == 0 ? .red : .green)
                        Text(b.footageLeft > 0 ? "\(b.left) left · \(MarkingProgress.clock(b.footageLeft))" : "\(b.left) left")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
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

    private func taskCard(_ task: LabelerModel.LabelTask, big: Bool, opensGroup: Set<String>) -> some View {
        let (title, detail, icon): (String, String, String) = {
            switch task {
            case .review(let v):
                let open = model.openFound(in: v).count
                return ("Mark the rallies", open > 0 ? "Watch at speed, one tap per touch · \(open) found rallies confirm as you go"
                                                    : "Watch at speed, one tap per touch, then finish",
                        "flag")
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
                    if case .review = task, opensGroup.contains(task.video.name) { Label("new camera group", systemImage: "sparkles").foregroundStyle(.orange) }
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

extension HomeView {
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
        case .review(let v): MarkRalliesView(model: model, video: v)
        case .track(let v, let r): TrackTaskView(model: model, video: v, span: r)
        }
    }
}

/// "Skip this video…": the reasons on offer; the choice sets the recording aside (the backlog, migration 053) —
/// it leaves the queue on both devices until put back, and the marks made so far stay.
struct BacklogDialog: ViewModifier {
    @Binding var video: LabelVideo?
    let model: LabelerModel
    var afterSkip: () -> Void = {}

    func body(content: Content) -> some View {
        content.confirmationDialog("Skip this video?", isPresented: Binding(get: { video != nil }, set: { if !$0 { video = nil } }),
                                   titleVisibility: .visible, presenting: video) { v in
            ForEach(BacklogReason.allCases, id: \.self) { reason in
                Button(reason.title) { model.setBacklog(v, reason: reason.rawValue); afterSkip() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { v in
            Text("\(v.name) leaves the queue on the phone and the Mac until it is put back (Videos → Backlog). The rallies marked so far stay.")
        }
    }
}

extension View {
    func backlogDialog(video: Binding<LabelVideo?>, model: LabelerModel, afterSkip: @escaping () -> Void = {}) -> some View {
        modifier(BacklogDialog(video: video, model: model, afterSkip: afterSkip))
    }

    /// The same, for one known video and a yes/no flag.
    func backlogDialog(isPresented: Binding<Bool>, video: LabelVideo, model: LabelerModel, afterSkip: @escaping () -> Void = {}) -> some View {
        modifier(BacklogDialog(video: Binding(get: { isPresented.wrappedValue ? video : nil }, set: { isPresented.wrappedValue = $0 != nil }),
                               model: model, afterSkip: afterSkip))
    }
}
