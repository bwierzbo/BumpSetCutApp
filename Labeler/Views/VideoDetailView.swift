//
//  VideoDetailView.swift
//  RallyLab (iPhone)
//
//  One video: its rally times (mark them live, or edit freely), its tracked
//  rallies (open to check or fix, swipe to delete) and the rallies still
//  to track.
//

import SwiftUI

struct VideoDetailView: View {
    let model: LabelerModel
    let video: LabelVideo
    @State private var skipping = false

    var body: some View {
        let times = model.rallyTimes(for: video)
        let tracks = model.tracks(for: video)
        let untracked = model.untrackedRallies(in: video)
        // The row as the model has it now (the one handed in may predate a skip or a put-back).
        let current = model.video(video.id) ?? video
        List {
            Section {
                LabeledContent("Surface", value: "\(video.surface.rawValue) · \(video.camera.title)")
                LabeledContent("Split", value: video.split)
                LabeledContent("Rally times", value: times.complete ? "every rally marked (\(times.rallies.count))" : "\(times.rallies.count) marked")
                if current.isBacklogged {
                    LabeledContent("Backlog", value: current.backlogReason ?? "set aside")
                    Button { model.setBacklog(current, reason: nil) } label: { Label("Put back in the queue", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { skipping = true } label: { Label("Skip this video…", systemImage: "arrow.uturn.forward") }
                }
            }
            Section("Rally times") {
                NavigationLink {
                    MarkRalliesView(model: model, video: video)
                } label: {
                    Label(model.openFound(in: video).isEmpty ? "Mark the rallies" : "Mark the rallies · \(model.openFound(in: video).count) found to confirm",
                          systemImage: "flag")
                }
                NavigationLink {
                    RallyTimesView(model: model, video: video)
                } label: { Label("Edit rally times", systemImage: "slider.horizontal.3") }
                // The footage type (D-033): chosen here, confirmed on the Mac; the state shown is the claim's.
                NavigationLink {
                    FootageTypeView(model: model, video: video, duration: video.duration, afterPass: false)
                } label: {
                    Label(footageTypeTitle, systemImage: "film.stack")
                }
                // Stage 1 rally boundaries (D-024): the same record and rules as RallyLab's Review tab.
                NavigationLink {
                    RallyBoundariesPhoneView(model: model, video: video)
                } label: {
                    Label(boundariesTitle, systemImage: "flag.checkered")
                }
            }
            Section("Tracked rallies (\(tracks.filter(\.done).count) done)") {
                ForEach(tracks) { t in
                    NavigationLink {
                        TrackReviewView(model: model, video: video, track: t)
                    } label: {
                        HStack {
                            Image(systemName: t.isMachine ? "cpu" : t.done ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(t.isMachine ? .teal : t.done ? .green : .orange)
                            Text("\(RallyTimesView.clock(t.start)) – \(RallyTimesView.clock(t.end))").font(.callout.monospacedDigit())
                            Spacer()
                            if t.isMachine {
                                let review = AnnotationReview.items([(video.name, t.rally)], kinds: [.crop, .fix, .noBall, .unsure]).count
                                Text("pre-tracked · \(review) to review").font(.caption).foregroundStyle(.teal)
                            } else if t.done {
                                Text("\(t.labeledFrames) frames").font(.caption).foregroundStyle(.secondary)
                            } else {
                                let n = max(t.points.points.count, 1)
                                ProgressView(value: Double(n - t.toCheck) / Double(n)).frame(width: 60)
                                Text("\(t.toCheck) to check").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .onDelete { offsets in offsets.map { tracks[$0] }.forEach(model.delete) }
            }
            if !untracked.isEmpty {
                Section("To track") {
                    ForEach(untracked) { r in
                        NavigationLink {
                            TrackTaskView(model: model, video: video, span: r)
                        } label: {
                            let trim = LocalStore.trim(of: r, in: video)
                            HStack {
                                Label("\(RallyTimesView.clock((trim ?? r).start)) – \(RallyTimesView.clock((trim ?? r).end))", systemImage: "scope")
                                    .font(.callout.monospacedDigit())
                                Spacer()
                                if trim != nil { Text("trimmed").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
            }
        }
        .backlogDialog(isPresented: $skipping, video: current, model: model)
        .navigationTitle(video.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The footage-type entry with what the Mac has and where this phone's choice stands.
    private var footageTypeTitle: String {
        let published = RecordingTypeClaims.reviewed(kind: video.recordingType.flatMap(RecordingTypeClaims.Kind.init(rawValue:)), at: video.recordingTypeAt)
        switch model.footageType(for: video) {
        case .none: return "Footage type · \(published)"
        case .pending: return "Footage type · \(published) · your choice is waiting to send"
        case .submitted: return "Footage type · \(published) · your choice is waiting for the Mac"
        case .accepted: return "Footage type · \(published)"
        case .rejected: return "Footage type · \(published) · your choice was not accepted"
        case .superseded: return "Footage type · \(published) · replaced by a newer choice"
        }
    }

    /// The Stage 1 entry with where the review stands, so an unfinished recording is easy to resume.
    private var boundariesTitle: String {
        guard model.isReviewable(video) else { return "Rally boundaries (withheld or not yet published)" }
        guard let f = model.rallyEvents(for: video)?.record else { return "Rally boundaries · not started" }
        if f.stage1Complete != nil { return "Rally boundaries · fully reviewed" }
        let reviewed = EventReview.union(f.coverage).reduce(0) { $0 + $1.end - $1.start }
        let share = f.durationSec > 0 ? Int((reviewed / f.durationSec * 100).rounded(.down)) : 0
        return "Rally boundaries · \(share) % reviewed · \(f.rallies.filter { $0.reviewState == .reviewed }.count) rallies"
    }
}
