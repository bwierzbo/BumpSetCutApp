//
//  OverviewView.swift
//  RallyLab (iPhone)
//
//  The dataset at a glance, like RallyLab's Coverage page: tracked rallies,
//  labeled frames and finished videos; each surface's frames against the
//  round's even share, its validation share and rally-time videos; and
//  every video's state.
//

import SwiftUI

struct OverviewView: View {
    let model: LabelerModel

    var body: some View {
        let progress = model.progress
        let round = model.currentRound
        let videos = model.videos
        List {
            Section {
                HStack(spacing: 10) {
                    tile("\(progress.rallies)", "tracked rallies", .orange)
                    tile(progress.frames.formatted(), "labeled frames", .teal)
                    tile("\(videos.filter { model.rallyTimes(for: $0).complete }.count)/\(videos.count)", "videos finished", .purple)
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section(round.map { "By surface · round \($0.number) wants \(PlanProgress.quota($0).formatted()) frames each" } ?? "By surface") {
                ForEach(LabelSurface.allCases) { surface in
                    let s = progress.surfaces[surface.rawValue] ?? PlanProgress.Surface()
                    let quota = round.map(PlanProgress.quota) ?? max(s.frames, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(surface.rawValue, systemImage: surface.icon).font(.headline)
                            Spacer()
                            Text("\(s.frames.formatted()) / \(quota.formatted())").font(.callout.monospacedDigit())
                        }
                        ProgressView(value: min(1, Double(s.frames) / Double(quota)))
                        HStack {
                            Text(s.frames > 0 ? "val \(Int((Double(s.valFrames) / Double(s.frames) * 100).rounded()))%" : "val —")
                                .foregroundStyle(s.frames > 0 && s.valFrames == 0 ? .red : .secondary)
                            Spacer()
                            Text("\(s.rallyTimeVideos) rally-time videos")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Every video") {
                ForEach(videos.sorted { ($0.surface.rawValue, $0.name) < ($1.surface.rawValue, $1.name) }) { v in
                    NavigationLink(value: v) { VideoRow(model: model, video: v) }
                }
            }
        }
        .refreshable { await model.reload() }
        .navigationTitle("Overview")
    }

    private func tile(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A video's name and state: rally times, tracked rallies, on the phone.
struct VideoRow: View {
    let model: LabelerModel
    let video: LabelVideo

    var body: some View {
        let times = model.rallyTimes(for: video)
        let tracks = model.tracks(for: video)
        HStack(spacing: 10) {
            Image(systemName: times.complete ? "checkmark.circle.fill" : times.rallies.isEmpty ? "circle" : "circle.lefthalf.filled")
                .foregroundStyle(times.complete ? .green : times.rallies.isEmpty ? .secondary : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.name).font(.callout.monospaced()).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(times.rallies.count) marked")
                    Text("· \(tracks.filter(\.done).count)/\(TrainingPlan.maxRalliesPerVideo) tracked")
                    if !video.ralliesFound.isEmpty { Text("· \(video.ralliesFound.count) found") }
                    if video.status == .uploaded { Text("· waiting for the Mac") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if LocalStore.hasClip(video) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).font(.caption) }
            if video.split == "val" {
                Text("val").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
            }
        }
    }
}
