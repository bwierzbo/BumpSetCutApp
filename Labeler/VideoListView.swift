//
//  VideoListView.swift
//  Labeler
//
//  Every video to label, by surface: rallies marked so far, whether every
//  rally is marked, and how many rallies RallyLab found. Videos still to
//  finish come first. Upload a video recorded on this phone from here.
//

import SwiftUI

struct VideoListView: View {
    @Bindable var model: LabelerModel
    @State private var uploading = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(LabelSurface.allCases) { surface in
                    let videos = sorted(model.videos.filter { $0.surface == surface })
                    if !videos.isEmpty {
                        Section {
                            ForEach(videos) { video in
                                NavigationLink(value: video) { row(video) }
                                    .disabled(video.clipPath == nil)
                            }
                        } header: {
                            let done = videos.filter { model.rallyTimes(for: $0).complete }.count
                            Label("\(surface.rawValue) · \(done)/\(videos.count) done", systemImage: surface.icon)
                        }
                    }
                }
            }
            .overlay {
                if model.videos.isEmpty, !model.isLoading {
                    ContentUnavailableView("No videos yet", systemImage: "film.stack",
                                           description: Text("Sync from RallyLab, or upload a video from this phone."))
                }
            }
            .refreshable { await model.reload() }
            .navigationTitle("RallyLab")
            .navigationDestination(for: LabelVideo.self) { RallyTimesView(model: model, video: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { uploading = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
                    } label: { Image(systemName: "person.circle") }
                }
            }
            .sheet(isPresented: $uploading) { UploadView(model: model) }
        }
    }

    /// Unfinished first, then by name.
    private func sorted(_ videos: [LabelVideo]) -> [LabelVideo] {
        videos.sorted {
            let a = model.rallyTimes(for: $0).complete, b = model.rallyTimes(for: $1).complete
            return a != b ? !a : $0.name < $1.name
        }
    }

    private func row(_ video: LabelVideo) -> some View {
        let times = model.rallyTimes(for: video)
        return HStack(spacing: 10) {
            Image(systemName: times.complete ? "checkmark.circle.fill" : times.rallies.isEmpty ? "circle" : "circle.lefthalf.filled")
                .foregroundStyle(times.complete ? .green : times.rallies.isEmpty ? .secondary : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.name).font(.callout.monospaced()).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(times.rallies.count) marked")
                    if !video.ralliesFound.isEmpty { Text("· \(video.ralliesFound.count) found") }
                    Text("· \(video.camera.title)")
                    if video.status == .uploaded { Text("· waiting for RallyLab") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if video.split == "val" {
                Text("val").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
            }
        }
    }
}
