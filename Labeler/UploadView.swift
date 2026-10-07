//
//  UploadView.swift
//  Labeler
//
//  Upload a video recorded on this phone for labeling: pick it, choose up to
//  five minutes of it (past the warm-ups), say where and how it was filmed.
//  It's re-encoded small (ClipEncoder), uploaded, and listed for RallyLab,
//  whose next Sync pulls it into the project on the matching clip card,
//  finds its rallies and sends them back here.
//

import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @Bindable var model: LabelerModel
    @Environment(\.dismiss) private var dismiss

    @State private var pick: PhotosPickerItem?
    @State private var file: URL?
    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var loading = false
    @State private var title = ""
    @State private var surface = LabelSurface.indoor
    @State private var camera = LabelCamera.endlineRaised
    @State private var lighting = LabelSurface.indoor.lightings[0]

    static let length = 300.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pick, matching: .videos, preferredItemEncoding: .current) {
                        Label(file == nil ? "Choose a Video" : "Choose Another", systemImage: "video")
                    }
                    if loading { ProgressView("Loading the video…") }
                    if file != nil {
                        LabeledContent("Length", value: RallyTimesView.clock(duration))
                    }
                }
                if file != nil, duration > Self.length {
                    Section {
                        Slider(value: $start, in: 0...(duration - Self.length))
                        LabeledContent("Uses", value: "\(RallyTimesView.clock(start)) – \(RallyTimesView.clock(start + Self.length))")
                    } header: {
                        Text("Which five minutes")
                    } footer: {
                        Text("Pick steady play — not warm-ups or packing up.")
                    }
                }
                Section("Where it was filmed") {
                    Picker("Surface", selection: $surface) {
                        ForEach(LabelSurface.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Camera", selection: $camera) {
                        ForEach(LabelCamera.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Lighting", selection: $lighting) {
                        ForEach(surface.lightings, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Name (optional)", text: $title)
                }
                if let stage = model.uploadStage {
                    Section {
                        ProgressView(stage, value: model.uploadProgress)
                    }
                }
            }
            .navigationTitle("Upload a Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.uploadStage != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { upload() }
                        .disabled(file == nil || model.uploadStage != nil)
                }
            }
            .onChange(of: surface) { _, s in lighting = s.lightings[0] }
            .onChange(of: pick) { _, item in load(item) }
            .interactiveDismissDisabled(model.uploadStage != nil)
            .onDisappear { if let file { try? FileManager.default.removeItem(at: file) } }
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                if let file { try? FileManager.default.removeItem(at: file) }
                file = movie.url
                duration = try await AVURLAsset(url: movie.url).load(.duration).seconds
                // The middle five minutes by default.
                start = max(0, (duration - Self.length) / 2).rounded(.down)
            } catch {
                model.error = "Couldn't load that video: \(error.localizedDescription)"
            }
        }
    }

    private func upload() {
        guard let file else { return }
        let request = LabelerModel.UploadRequest(source: file, start: start, length: Self.length, title: title,
                                                 surface: surface, camera: camera, lighting: lighting)
        Task {
            if await model.upload(request) { dismiss() }
        }
    }
}

/// A video from Photos, copied to a temporary file.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
