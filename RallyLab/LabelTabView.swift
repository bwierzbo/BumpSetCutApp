//
//  LabelTabView.swift
//  RallyLab
//
//  Where labeling happens, the same flow as RallyLab on the phone: Next
//  shows the round's progress and one big card with the most useful thing
//  to do (LabelQueue — the same rules as the phone), then the few after it.
//  A track task trims the rally on a filmstrip, then tracks its ball and
//  stops you only on the frames worth a look; a review task confirms the
//  rallies RallyLab found and skims for missed ones. Finishing one opens
//  the next. Coverage and Plan are the project's frame counts and rounds.
//

import AppKit
import SwiftUI

struct LabelTabView: View {
    let projects: ProjectsModel
    let library: ModelLibrary
    let tracker: TrackLabelModel
    let marker: RallyMarkModel
    let phone: LabelingSync
    let isActive: Bool
    @AppStorage("RallyLab.labelPage") private var page: Page = .next
    @State private var plan: TrainingPlanModel
    @State private var review: ProjectReviewStore
    /// The task on screen, if any.
    @State private var active: LabelQueue.Job?

    enum Page: String { case next, review, coverage, plan }

    init(projects: ProjectsModel, library: ModelLibrary, tracker: TrackLabelModel, marker: RallyMarkModel, phone: LabelingSync,
         isActive: Bool) {
        self.projects = projects
        self.library = library
        self.tracker = tracker
        self.marker = marker
        self.phone = phone
        self.isActive = isActive
        _plan = State(initialValue: TrainingPlanModel(library: library))
        _review = State(initialValue: ProjectReviewStore(sampler: projects.sampler, tracker: tracker))
    }

    private var sampler: SamplerModel { projects.sampler }

    var body: some View {
        Group {
            if let active, let session = sampler.sessions.first(where: { $0.name == active.video }) {
                job(active, session)
                    .id(active)
            } else {
                pages
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pages: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text("Next").tag(Page.next)
                Text("Review").tag(Page.review)
                Text("Coverage").tag(Page.coverage)
                Text("Plan").tag(Page.plan)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 380)
            .padding(.vertical, 10)
            Divider()
            switch page {
            case .next:
                LabelHomeView(sampler: sampler, round: plan.currentRound, jobs: jobs, isActive: isActive) { active = $0 }
            case .review:
                NavigationStack { ReviewHomeView(store: review, progress: review.progress) }
            case .coverage:
                ProjectCoverageView(projects: projects)
            case .plan:
                ProjectPlanView(projects: projects, library: library, phone: phone) { session in
                    active = jobs.first { $0.video == session.name }
                        ?? LabelQueue.Video(session: session).nextRally.map { .track(session.name, $0) }
                }
            }
        }
    }

    @ViewBuilder
    private func job(_ job: LabelQueue.Job, _ session: VideoSession) -> some View {
        switch job {
        case .track(_, let rally):
            LabelTrackTask(session: session, rally: rally, tracker: tracker, marker: marker, isActive: isActive,
                           onClose: { active = nil }, onDone: next)
        case .review:
            LabelReviewView(session: session, marker: marker, isActive: isActive, onClose: { active = nil }, onDone: next)
        }
    }

    /// The task after the one just finished.
    private func next() {
        let finished = active
        active = jobs.first { $0 != finished }
    }

    private var jobs: [LabelQueue.Job] {
        LabelQueue.jobs(sampler.sessions.map(LabelQueue.Video.init(session:)), round: plan.currentRound)
    }
}

extension LabelQueue.Video {
    /// A Mac video: rallies marked in its rallylabels file and found by the
    /// Sampler (less the ones you said aren't rallies); a rally you started
    /// tracking and didn't finish comes first.
    @MainActor
    init(session s: VideoSession) {
        let tracks = s.tracks ?? []
        let marked = RallyMarkModel.marks(in: s).map { LabelRally(start: $0.start, end: $0.end) }
        let notRallies = s.notRallies ?? []
        let found = TrackLabelModel.suggestions(from: s, excluding: [])
            .filter { f in !notRallies.contains { abs($0 - f.start) < 0.05 } }
            .map { LabelRally(start: $0.start, end: $0.end) }
            .filter { f in !marked.contains { min($0.end, f.end) - max($0.start, f.start) > 0.3 } }
        let unfinished = tracks.filter { !$0.done }.map(\.bounds)
        let open = (marked + found)
            .filter { r in !tracks.contains { min($0.end, r.end) - max($0.start, r.start) > 0.5 * (r.end - r.start) } }
            .sorted { $0.start < $1.start }
        self.init(plan: PlanVideo(session: s), nextRally: (unfinished + open).first, found: found.count,
                  complete: s.ralliesMarked ?? false)
    }
}

/// Next: the round, today, and what to do — the first task big.
private struct LabelHomeView: View {
    let sampler: SamplerModel
    let round: TrainingPlan.Round?
    let jobs: [LabelQueue.Job]
    let isActive: Bool
    let open: (LabelQueue.Job) -> Void

    var body: some View {
        let progress = PlanProgress(videos: sampler.sessions.map(PlanVideo.init(session:)), round: round)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                roundCard(progress)
                if let first = jobs.first {
                    Button { open(first) } label: { card(first, big: true) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    ContentUnavailableView("Nothing to do", systemImage: "checkmark.seal",
                                           description: Text("Every video's rallies are marked and the round has its frames. Import more videos, or train the round on the Plan page."))
                        .padding(.vertical, 30)
                }
                if jobs.count > 1 {
                    Text("Up next").font(.headline).padding(.top, 4)
                    ForEach(jobs.dropFirst().prefix(6), id: \.self) { job in
                        Button { open(job) } label: { card(job, big: false) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(.background.secondary)
    }

    private func roundCard(_ progress: PlanProgress) -> some View {
        let target = round?.frames ?? max(progress.frames, 1)
        let fraction = min(1, Double(progress.frames) / Double(target))
        let today = Today(sessions: sampler.sessions)
        return HStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 11)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int(fraction * 100))%").font(.title3.bold().monospacedDigit())
            }
            .frame(width: 86, height: 86)
            VStack(alignment: .leading, spacing: 5) {
                Text(round.map { "Round \($0.number)" } ?? "Every round trained").font(.title2.bold())
                Text("\(progress.frames.formatted()) of \(target.formatted()) frames").font(.body.monospacedDigit())
                HStack(spacing: 14) {
                    ForEach(TrainingPlan.surfaces, id: \.self) { surface in
                        let frames = progress.surfaces[surface]?.frames ?? 0
                        Label("\(frames.formatted())", systemImage: LabelSurface(rawValue: surface)?.icon ?? "circle")
                            .help("\(surface) frames")
                    }
                }
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text("Today: \(today.rallies) rallies · \(today.frames.formatted()) frames")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func card(_ job: LabelQueue.Job, big: Bool) -> some View {
        let session = sampler.sessions.first { $0.name == job.video }
        let (title, detail, icon): (String, String, String) = {
            switch job {
            case .review:
                let found = session.map { LabelQueue.Video(session: $0).found } ?? 0
                return ("Check the rallies", found > 0 ? "\(found) found rallies to confirm, then skim for missed ones" : "Skim for missed rallies and finish",
                        "checklist")
            case .track(_, let r):
                let resuming = session?.tracks?.contains { !$0.done && $0.bounds == r } ?? false
                let frames = Int((r.end - r.start + 2 * TrackedRally.margin) * TrackLabelModel.frameRate)
                return (resuming ? "Finish tracking a rally" : "Track a rally",
                        "\(TrackLabelModel.clock(r.start)) – \(TrackLabelModel.clock(r.end)) · about \(frames) frames", "scope")
            }
        }()
        let surface = LabelSurface(rawValue: Coverage.environment(job.video))
        return HStack(spacing: 16) {
            Image(systemName: icon).font(big ? .system(size: 34) : .title2).foregroundStyle(Color.accentColor)
                .frame(width: big ? 56 : 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(big ? .title2.bold() : .headline)
                Text(job.video).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let surface { Label(surface.rawValue, systemImage: surface.icon) }
                    if session?.split == "val" { Text("val").foregroundStyle(.purple) }
                }
                .font(.caption)
            }
            Spacer()
            if big {
                Text("Start ↩").font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .padding(big ? 22 : 14)
        .background(big ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Rallies finished today, by when their track was last changed.
    private struct Today {
        var rallies = 0, frames = 0
        init(sessions: [VideoSession]) {
            for t in sessions.flatMap({ $0.tracks ?? [] }) where t.done {
                guard let at = t.updatedAt, Calendar.current.isDateInToday(at) else { continue }
                rallies += 1
                frames += t.labeledFrames
            }
        }
    }
}

/// Keys for a labeling screen while its tab shows — handled ahead of the
/// focused control, except while typing or in a sheet or panel. The
/// handler returns whether it used the key.
struct LabelKeys: ViewModifier {
    let isActive: Bool
    let handle: (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard isActive, let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
                          !(window is NSPanel), !(window.firstResponder is NSText) else { return event }
                    return handle(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    func labelKeys(isActive: Bool, _ handle: @escaping (NSEvent) -> Bool) -> some View {
        modifier(LabelKeys(isActive: isActive, handle: handle))
    }
}

/// The top of a task screen: back, what it is, and what it's on.
struct LabelTaskHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onClose) { Label("Next", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to the task list (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
