//
//  ProjectsTabView.swift
//  RallyLab
//
//  The open project's clip plan as a board of cards. Each clip takes any
//  number of videos — dropped on its card, or added from a link or file in
//  the detail pane — each cut (5 minutes), logged with its licence, and
//  sampled into the project's dataset with its own frame count. Review
//  happens in the Sampler tab.
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
                        Text("\(target) frames per video").font(.caption).monospacedDigit()
                    }
                    .fixedSize()
                    .help("The default for new videos: each is thinned to this many frames after sampling, misses kept first. Set a video's own count in its clip.")
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
    @State private var start = ""
    @State private var length = "5:00"
    @State private var license = ""
    @State private var frames = StandardClipPlan.targetFrames
    @State private var removing: String?

    private var defaultFrames: Int { projects.project?.targetFrames ?? StandardClipPlan.targetFrames }
    private var ownFootage: Bool { clip.kind != .online }

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

                HStack {
                    ClipStatusLabel(progress: projects.progress(of: clip))
                    Spacer()
                    let count = clip.videos.count
                    Text("\(count) video\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("Videos") {
                    VStack(alignment: .leading, spacing: 0) {
                        let jobs = projects.jobs.filter { $0.clipId == clip.id }
                        if clip.videos.isEmpty && jobs.isEmpty {
                            Text(ownFootage
                                 ? "None yet. Drop videos on the card — as many as you like — or add one below."
                                 : "None yet. Add a video below with its licence.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        ForEach(clip.videos, id: \.clipFile) { video in
                            videoRow(video)
                            Divider().padding(.vertical, 6)
                        }
                        ForEach(jobs) { job in
                            jobRow(job)
                            Divider().padding(.vertical, 6)
                        }
                    }
                    .padding(4)
                }

                addVideoBox

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
                    .disabled(!projects.sessions(for: clip).isEmpty)
                    Text(!projects.sessions(for: clip).isEmpty
                         ? "Fixed once a video is sampled. Remove its videos to change it."
                         : "Val clips are held out to check the model. Auto balances it for you.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .onAppear {
            frames = defaultFrames
            if ownFootage { license = ProjectsModel.ownFootageLicense }
        }
        .onChange(of: projects.droppedFootage, initial: true) { _, drop in
            guard let drop, drop.clipId == clip.id else { return }
            source = drop.path
            projects.droppedFootage = nil
        }
        .confirmationDialog("Remove \(removing ?? "this video")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { videoId in
            Button("Remove Video", role: .destructive) { projects.removeVideo(videoId, from: clip.id) }
        } message: { _ in
            Text("Its cut footage and its frames, reviewed or not, are deleted. The original isn't touched.")
        }
    }

    // MARK: Video rows

    private func videoRow(_ video: ClipSource) -> some View {
        let videoId = clip.videoId(of: video)
        let progress = projects.progress(ofVideo: videoId)
        let wanted = video.frames ?? defaultFrames
        let session = projects.session(named: videoId)
        let busy: Bool = {
            if case .sampling = progress { return true }
            return false
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(video.title.isEmpty ? URL(fileURLWithPath: video.origin).lastPathComponent : video.title)
                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu {
                    Button("Show Cut in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: video.clipFile)])
                    }
                    Divider()
                    Button("Remove Video…", role: .destructive) { removing = videoId }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(busy)
            }
            Text("\(videoId) · \(Self.clock(video.start)) → \(Self.clock(video.start + video.length)) · \(video.license)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                ClipStatusLabel(progress: progress).font(.caption)
                Spacer()
                if let session { Button("Review") { review(session) }.controlSize(.small) }
            }
            HStack(spacing: 8) {
                Stepper(value: Binding(get: { wanted },
                                       set: { projects.setFrames($0, forVideo: videoId, in: clip.id) }),
                        in: 5...400, step: 5) {
                    Text("\(wanted) frames").font(.caption).monospacedDigit()
                }
                .fixedSize()
                Spacer()
                if let session, session.frames.count != wanted, !busy {
                    Button("Re-pull \(wanted)") { projects.repull(videoId, in: clip.id) }
                        .controlSize(.small)
                        .help(session.reviewedCount > 0
                              ? "Samples this video again. Its \(session.reviewedCount) reviewed frames are replaced."
                              : "Samples this video again at the new count.")
                }
            }
        }
    }

    private func jobRow(_ job: VideoJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            HStack {
                ClipStatusLabel(progress: projects.progress(ofVideo: job.id)).font(.caption)
                Spacer()
                if job.failure != nil {
                    Button("Dismiss") { projects.dismissFailure(job.id) }.controlSize(.small)
                }
            }
            if let why = job.failure {
                Text(why).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    // MARK: Adding a video

    private var addVideoBox: some View {
        GroupBox("Add a Video") {
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
                    labeled("start", TextField("middle", text: $start).frame(width: 64))
                    labeled("length", TextField("5:00", text: $length).frame(width: 64))
                }
                .textFieldStyle(.roundedBorder)
                labeled("licence", TextField("CC-BY, or permission: who, how, when", text: $license)
                    .textFieldStyle(.roundedBorder))
                Stepper(value: $frames, in: 5...400, step: 5) {
                    Text("\(frames) frames from this video").font(.caption).monospacedDigit()
                }
                .fixedSize()
                HStack {
                    Button(action: add) { Label("Add Video", systemImage: "plus") }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdd)
                    if !timesReadable {
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
    }

    /// An empty start means the middle for a file, the beginning for a link.
    private var timesReadable: Bool {
        (start.trimmingCharacters(in: .whitespaces).isEmpty || Self.seconds(start) != nil)
            && Self.seconds(length) != nil
    }

    private var canAdd: Bool {
        !source.trimmingCharacters(in: .whitespaces).isEmpty
            && !license.trimmingCharacters(in: .whitespaces).isEmpty
            && timesReadable
    }

    private func add() {
        let path = (source.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let len = Self.seconds(length) ?? ProjectsModel.dropClipLength
        let wanted = frames == defaultFrames ? nil : frames
        if start.trimmingCharacters(in: .whitespaces).isEmpty, FileManager.default.fileExists(atPath: path) {
            projects.cutMiddle(of: URL(fileURLWithPath: path), into: clip.id, length: len,
                               license: license, frames: wanted)
        } else {
            guard projects.addVideo(to: clip.id, source: source, start: Self.seconds(start) ?? 0,
                                    length: len, license: license, frames: wanted) != nil else { return }
        }
        source = ""
    }

    private func labeled<V: View>(_ name: String, _ field: V) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            field
        }
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
