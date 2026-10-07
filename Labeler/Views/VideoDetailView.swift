//
//  VideoDetailView.swift
//  RallyLab (iPhone)
//
//  One video: its rally times (review them, or edit freely), its tracked
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
                    RallyReviewView(model: model, video: video)
                } label: {
                    Label(model.openFound(in: video).isEmpty ? "Skim for missed rallies" : "Review \(model.openFound(in: video).count) found rallies",
                          systemImage: "checklist")
                }
                NavigationLink {
                    RallyTimesView(model: model, video: video)
                } label: { Label("Edit rally times", systemImage: "slider.horizontal.3") }
            }
            Section("Tracked rallies (\(tracks.filter(\.done).count) done)") {
                ForEach(tracks) { t in
                    NavigationLink {
                        TrackReviewView(model: model, video: video, track: t)
                    } label: {
                        HStack {
                            Image(systemName: t.done ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(t.done ? .green : .orange)
                            Text("\(RallyTimesView.clock(t.start)) – \(RallyTimesView.clock(t.end))").font(.callout.monospacedDigit())
                            Spacer()
                            Text("\(t.labeledFrames) frames").font(.caption).foregroundStyle(.secondary)
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
                            Label("\(RallyTimesView.clock(r.start)) – \(RallyTimesView.clock(r.end))", systemImage: "scope")
                                .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
        .navigationTitle(video.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
