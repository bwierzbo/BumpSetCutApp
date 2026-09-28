//
//  ProjectsTabView.swift
//  RallyLab
//
//  The open project's clip plan as a working list: for each clip paste a
//  video link or drop a file, set where it starts, and Get Clip — 5 minutes
//  are cut, logged with their licence, and sampled into the project's
//  dataset under the clip's ID. Review happens in the Sampler tab.
//

import AppKit
import SwiftUI

struct ProjectsTabView: View {
    @Bindable var projects: ProjectsModel
    /// Opens a clip's frames in the Sampler tab.
    let review: (VideoSession) -> Void

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                ClipBoardView(projects: projects)
                    .frame(maxHeight: .infinity)
                Divider()
                Text(projects.status)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if let clip = projects.selectedClip {
                    ClipDetailPane(projects: projects, clip: clip, review: review)
                        .id(clip.id)
                } else {
                    ContentUnavailableView("Pick a Clip", systemImage: "film",
                                           description: Text("Select a clip to give it footage."))
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Button("New Project…") { projects.isCreatingProject = true }
                    Button("Open Existing Project…") { ProjectPanels.openExisting(projects) }
                    Menu("Open Recent") {
                        ForEach(projects.recentProjects, id: \.self) { dir in
                            Button("\(dir.lastPathComponent)  —  \((dir.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)") {
                                projects.open(dir)
                            }
                        }
                    }
                    .disabled(projects.recentProjects.isEmpty)
                    Divider()
                    Button("Close Project") { projects.close() }
                } label: {
                    Label(projects.project?.name ?? "Choose Project", systemImage: "folder")
                }
                .fixedSize()

                Spacer()

                if let target = projects.project?.targetFrames {
                    Stepper(value: Binding(get: { target }, set: { projects.setTargetFrames($0) }),
                            in: 10...400, step: 5) {
                        Text("\(target) frames per clip").font(.caption).monospacedDigit()
                    }
                    .fixedSize()
                    .help("Each clip is thinned to this many frames after sampling. Misses are kept first.")
                }
                if let dir = projects.projectDir {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    } label: { Image(systemName: "folder") }
                    .help(dir.path)
                }
            }

        }
        .padding(12)
    }

}

// MARK: - Status label

struct ClipStatusLabel: View {
    let progress: ClipProgress

    var body: some View {
        switch progress {
        case .notStarted:
            Label("No footage", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .cutting(let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 50)
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Cutting…")
                }
            }
        case .sampling:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Sampling…") }
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .pulled(let frames, let reviewed):
            if frames > 0, reviewed == frames {
                Label("Labeled · \(frames)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("\(reviewed)/\(frames) reviewed", systemImage: "circle.lefthalf.filled").foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Detail pane

private struct ClipDetailPane: View {
    @Bindable var projects: ProjectsModel
    let clip: PlannedClip
    let review: (VideoSession) -> Void

    @State private var source = ""
    @State private var start = "0:00"
    @State private var length = "5:00"
    @State private var license = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.id).font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Text([clip.environment, clip.camera, clip.lighting, clip.orientation, clip.ball]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if !clip.notes.isEmpty {
                        Text(clip.notes).font(.callout)
                    }
                }

                statusBox

                GroupBox("Footage") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste a video link, or drop a video here from Photos or Finder. Use footage you have permission for.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            TextField("https://youtube.com/watch?v=…  or a file path", text: $source)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            Button("File…") { chooseFile() }
                        }
                        HStack(spacing: 10) {
                            labeled("start", TextField("0:00", text: $start).frame(width: 64))
                            labeled("length", TextField("5:00", text: $length).frame(width: 64))
                        }
                        .textFieldStyle(.roundedBorder)
                        labeled("licence", TextField("CC-BY, or permission: who, how, when", text: $license)
                            .textFieldStyle(.roundedBorder))
                        HStack {
                            Button {
                                projects.getFootage(for: clip.id, source: source,
                                                    start: Self.seconds(start) ?? 0,
                                                    length: Self.seconds(length) ?? 300,
                                                    license: license)
                            } label: {
                                Label(clip.source == nil ? "Get Clip" : "Replace Clip", systemImage: "scissors")
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canGet)
                            if Self.seconds(start) == nil || Self.seconds(length) == nil {
                                Text("Times are seconds or m:ss").font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(4)
                }
                // AppKit drop target: Photos hands over file promises, which
                // SwiftUI's onDrop can't receive. Photos videos are copied
                // into ~/Movies/RallyLab first, then cut from there.
                .background(
                    SamplerDropView(
                        onDrop: { urls in
                            if let video = urls.first(where: {
                                ProjectsModel.videoExtensions.contains($0.pathExtension.lowercased())
                            }) { source = video.path }
                        },
                        onStatus: { projects.note($0) }
                    )
                )

                GroupBox("Split") {
                    Picker("", selection: Binding(
                        get: { clip.split ?? "auto" },
                        set: { projects.setSplit($0 == "auto" ? nil : $0, for: clip.id) }
                    )) {
                        Text("Auto").tag("auto")
                        Text("Train").tag("train")
                        Text("Val").tag("val")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(projects.session(for: clip) != nil)
                    Text(projects.session(for: clip) != nil
                         ? "Fixed once the clip is sampled. Replace the clip to change it."
                         : "Val clips are held out to check the model. Auto balances it for you.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let src = clip.source { sourceBox(src) }
            }
            .padding(14)
        }
        .onAppear(perform: prefill)
        // A drop cuts in the background; show what it used once it lands.
        .onChange(of: clip.source) { prefill() }
        .onChange(of: projects.droppedFootage, initial: true) { _, drop in
            guard let drop, drop.clipId == clip.id else { return }
            source = drop.path
            if license.isEmpty { license = drop.license }
            projects.droppedFootage = nil
        }
    }

    private var canGet: Bool {
        !source.trimmingCharacters(in: .whitespaces).isEmpty
            && !license.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.seconds(start) != nil && Self.seconds(length) != nil
            && {
                if case .cutting = projects.progress(of: clip) { return false }
                if case .sampling = projects.progress(of: clip) { return false }
                return true
            }()
    }

    @ViewBuilder
    private var statusBox: some View {
        let progress = projects.progress(of: clip)
        HStack {
            ClipStatusLabel(progress: progress)
            Spacer()
            if let session = projects.session(for: clip) {
                Button("Review in Sampler") { review(session) }
            }
        }
        if case .failed(let why) = progress {
            Text(why).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func sourceBox(_ src: ClipSource) -> some View {
        GroupBox("Current footage") {
            VStack(alignment: .leading, spacing: 4) {
                if !src.title.isEmpty { Text(src.title).font(.callout).lineLimit(2) }
                if !src.uploader.isEmpty { Text(src.uploader).font(.caption).foregroundStyle(.secondary) }
                Text("\(Self.clock(src.start)) → \(Self.clock(src.start + src.length)) · \(src.license)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(src.origin).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Show Clip in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: src.clipFile)])
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func labeled<V: View>(_ name: String, _ field: V) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            field
        }
    }

    private func prefill() {
        guard let src = clip.source else { return }
        source = src.origin
        start = Self.clock(src.start)
        length = Self.clock(src.length)
        license = src.license
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url.path
    }

    /// "90", "1:30", "1:02:03" → seconds; nil if unreadable.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
