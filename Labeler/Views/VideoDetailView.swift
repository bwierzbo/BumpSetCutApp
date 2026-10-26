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

    var body: some View {
        let times = model.rallyTimes(for: video)
        let tracks = model.tracks(for: video)
        let untracked = model.untrackedRallies(in: video)
        List {
            Section {
                LabeledContent("Surface", value: "\(video.surface.rawValue) · \(video.camera.title)")
                LabeledContent("Split", value: video.split)
                LabeledContent("Rally times", value: times.complete ? "every rally marked (\(times.rallies.count))" : "\(times.rallies.count) marked")
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
                // Stage 1 rally boundaries (D-024): the same record and rules as RallyLab's Review tab.
                NavigationLink {
                    RallyBoundariesPhoneView(model: model, video: video)
                } label: {
                    Label(model.isReviewable(video) ? "Rally boundaries" : "Rally boundaries (withheld or not yet published)", systemImage: "flag.checkered")
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
        .navigationTitle(video.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
