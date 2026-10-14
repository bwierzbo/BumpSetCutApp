//
//  VideoListView.swift
//  RallyLab (iPhone)
//
//  Every video by surface, unfinished first, to pick one yourself;
//  uploading a video recorded on this phone; and Process, which runs one
//  through BumpSetCut's pipeline for a debug video (PipelineRunView).
//

import SwiftUI

struct VideoListView: View {
    @Bindable var model: LabelerModel
    @State private var uploading = false
    @State private var processing = false

    var body: some View {
        List {
            ForEach(LabelSurface.allCases) { surface in
                let videos = sorted(model.videos.filter { $0.surface == surface })
                if !videos.isEmpty {
                    Section {
                        ForEach(videos) { video in
                            NavigationLink(value: video) { VideoRow(model: model, video: video) }
                        }
                    } header: {
                        let done = videos.filter { model.rallyTimes(for: $0).complete }.count
                        Label("\(surface.rawValue) · \(done)/\(videos.count) finished", systemImage: surface.icon)
                    }
                }
            }
        }
        .overlay {
            if model.videos.isEmpty, !model.isLoading {
                ContentUnavailableView("No videos yet", systemImage: "film.stack",
                                       description: Text("Sync from RallyLab on the Mac, or upload a video from this phone."))
            }
        }
        .refreshable { await model.reload() }
        .navigationTitle("Videos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { uploading = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { processing = true } label: { Label("Process", systemImage: "wand.and.rays") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
                } label: { Image(systemName: "person.circle") }
            }
        }
        .sheet(isPresented: $uploading) { UploadView(model: model) }
        .fullScreenCover(isPresented: $processing) { PipelineRunView() }
    }

    /// Unfinished first, then by name.
    private func sorted(_ videos: [LabelVideo]) -> [LabelVideo] {
        videos.sorted {
            let a = model.rallyTimes(for: $0).complete, b = model.rallyTimes(for: $1).complete
            return a != b ? !a : $0.name < $1.name
        }
    }
}
