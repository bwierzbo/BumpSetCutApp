//
//  ContentView.swift
//  RallyLab
//

import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: RallyLabModel
    @State private var showingImporter = false

    var body: some View {
        HSplitView {
            playerColumn
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            InspectorPane(model: model)
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 480)
        }
        .frame(minWidth: 1040, minHeight: 680)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.movie, .video]) { result in
            if case .success(let url) = result { model.loadVideo(url) }
        }
        .background(VideoDropView(model: model))
        .task { model.restoreLastSession() }
    }

    private var playerColumn: some View {
        VStack(spacing: 10) {
            if let player = model.player {
                ZStack {
                    VideoPlayer(player: player)
                    if model.showOverlay {
                        DetectionOverlayView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Video",
                    systemImage: "film",
                    description: Text("Open a video or drag one here to start labeling rallies.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            scrubber
            SegmentsTimelineView(model: model)
                .frame(height: model.evidence.isEmpty ? 96 : 150)
            transportBar
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(timecode(model.currentTime))
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { model.currentTime },
                    set: { model.seek(to: $0) }
                ),
                in: 0...max(model.duration, 0.01)
            )
            .disabled(model.player == nil)
            Text(timecode(model.duration))
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button("Open Video…") { showingImporter = true }
                .keyboardShortcut("o")

            if !model.recentVideos.isEmpty {
                Menu("Recent") {
                    ForEach(model.recentVideos, id: \.self) { url in
                        Button(url.lastPathComponent) { model.loadVideo(url) }
                    }
                }
                .frame(width: 90)
            }

            Button {
                model.togglePlayPause()
            } label: {
                Label("Play/Pause", systemImage: "playpause.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.player == nil)

            Divider().frame(height: 16)

            Button {
                model.markStart()
            } label: {
                Label("Mark Start (S)", systemImage: "arrowtriangle.right.circle")
            }
            .keyboardShortcut("s", modifiers: [])
            .disabled(model.player == nil)

            Button {
                model.markEnd()
            } label: {
                Label("Mark End (E)", systemImage: "arrowtriangle.left.circle")
            }
            .keyboardShortcut("e", modifiers: [])
            .disabled(model.player == nil || model.pendingStart == nil)

            if let pending = model.pendingStart {
                Text(String(format: "start pending @ %.2fs", pending))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Cancel") { model.cancelPendingStart() }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            Spacer()

            if model.showOverlay && !model.evidence.isEmpty {
                overlayLegend
            }
            Toggle("Overlay", isOn: $model.showOverlay)
                .toggleStyle(.checkbox)
                .disabled(model.evidence.isEmpty)
            Toggle("ROI", isOn: $model.showROI)
                .toggleStyle(.checkbox)
                .disabled(model.evidence.isEmpty || !model.showOverlay)
        }
    }

    private var overlayLegend: some View {
        HStack(spacing: 10) {
            legendItem(.yellow, "detection")
            trailLegend
            legendItem(.red, "projectile")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// The trail is colored by gravity signature, so show the gradient.
    private var trailLegend: some View {
        HStack(spacing: 3) {
            LinearGradient(colors: [.red, .yellow, .green], startPoint: .leading, endPoint: .trailing)
                .frame(width: 18, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text("trail = gravity")
        }
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}
