//
//  ProjectsTabView.swift
//  RallyLab
//
//  The open project's clip plan as a board of cards. Each clip takes any
//  number of videos — dropped on its card, or added from a link or file in
//  the detail pane — each cut (5 minutes), logged with its licence, and
//  sampled into the project's dataset with its own frame count. Labeling
//  happens in the Label tab (its coverage and training plan too).
//

import AppKit
import SwiftUI

struct ProjectsTabView: View {
    @Bindable var projects: ProjectsModel
    /// Opens a clip's frames in the Import tab's stills review.
    let review: (VideoSession) -> Void
    @AppStorage("RallyLab.projectPage") private var page: Page = .board

    enum Page: String { case board, overview, activity }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch page {
                    case .board: ClipBoardView(projects: projects)
                    case .overview: ProjectOverviewView(projects: projects)
                    case .activity:
                        ProjectActivityView(projects: projects, showCard: { id in
                            projects.selectedClipId = id
                            page = .board
                        }, review: review)
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                Text(projects.status)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            if page == .board {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    /// Videos being imported, cut or sampled, or waiting to be.
    private var activeCount: Int {
        projects.activity().filter { $0.phase == .running || $0.phase == .waiting }.count
    }

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

                Picker("", selection: $page) {
                    Label("Board", systemImage: "square.grid.2x2").tag(Page.board)
                    Label("Overview", systemImage: "chart.bar.xaxis").tag(Page.overview)
                    Text(activeCount > 0 ? "Activity · \(activeCount)" : "Activity").tag(Page.activity)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                if let perRally = projects.project?.framesPerRally {
                    Stepper(value: Binding(get: { perRally }, set: { projects.setFramesPerRally($0) }),
                            in: 2...20) {
                        Text("\(perRally) frames per rally").font(.caption).monospacedDigit()
                    }
                    .fixedSize()
                    .help("The default for new videos: stills kept from each rally the Sampler finds. Two (its first and last frame) mark the rally for the Track tab, where tracking it labels every frame; more are stills to review. Set a video's own count in its clip.")
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
        case .busy(let stage, let overall):
            WorkProgressBar(stage: stage, overall: overall)
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

/// A video's whole journey — import, cut, finding rallies, pre-labeling —
/// as one bar, with the stage it's in and how far along it is.
struct WorkProgressBar: View {
    let stage: String
    let overall: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let overall {
                ProgressView(value: overall)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(stage).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let overall { Text("\(Int((overall * 100).rounded(.down)))%").monospacedDigit() }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.25), value: overall)
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
    @State private var frames = StandardClipPlan.framesPerRally
    @State private var removing: String?

    private var defaultFrames: Int { projects.project?.framesPerRally ?? StandardClipPlan.framesPerRally }
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

                let clipProgress = projects.progress(of: clip)
                HStack {
                    ClipStatusLabel(progress: clipProgress)
                    if !clipProgress.isBusy { Spacer() }
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
            Text("Its cut footage and its reviewed frames are deleted. The original video isn't touched.")
        }
    }

    // MARK: Video rows

    private func videoRow(_ video: ClipSource) -> some View {
        let videoId = clip.videoId(of: video)
        let progress = projects.progress(ofVideo: videoId)
        let wanted = video.frames ?? defaultFrames
        let session = projects.session(named: videoId)
        let busy = projects.moving.contains(videoId) || progress.isBusy
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(video.title.isEmpty ? URL(fileURLWithPath: video.origin).lastPathComponent : video.title)
                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                MoveVideoMenu(projects: projects, clip: clip, videoId: videoId) {
                    Image(systemName: "arrow.right.square")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Move to another card")
                .disabled(busy)
                Button {
                    if projects.needsConfirmToRemove(videoId) { removing = videoId }
                    else { projects.removeVideo(videoId, from: clip.id) }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove from this card")
                .disabled(busy)
            }
            .contextMenu {
                Button("Show Cut in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: video.clipFile)])
                }
            }
            if projects.moving.contains(videoId) {
                Label("Moving…", systemImage: "arrow.right.square").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(videoId) · \(Self.clock(video.start)) → \(Self.clock(video.start + video.length)) · \(video.license)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            let others = projects.uses(of: projects.fingerprint(of: video), excluding: videoId)
            if !others.isEmpty {
                Label("Same video as " + others.map { "\($0.videoId) (\($0.range))" }.joined(separator: ", "),
                      systemImage: "doc.on.doc")
                    .font(.caption2).foregroundStyle(.orange)
                    .help(others.contains { $0.overlaps(start: video.start, length: video.length) }
                          ? "These overlap: the same moments are sampled twice."
                          : "Different stretches of the same video.")
            }
            ClipStatusLabel(progress: progress).font(.caption)
            HStack(spacing: 8) {
                Stepper(value: Binding(get: { wanted },
                                       set: { projects.setFrames($0, forVideo: videoId, in: clip.id) }),
                        in: 2...20) {
                    Text("\(wanted) per rally").font(.caption).monospacedDigit()
                }
                .fixedSize()
                Spacer()
                if let session, !busy { Button("Review") { review(session) }.controlSize(.small) }
                if session != nil, !busy {
                    Button("Re-pull") { projects.repull(videoId, in: clip.id) }
                        .controlSize(.small)
                        .help((session?.reviewedCount ?? 0) > 0
                              ? "Samples this video again at \(wanted) per rally. Its \(session?.reviewedCount ?? 0) reviewed frames are replaced."
                              : "Samples this video again at \(wanted) per rally.")
                }
            }
        }
    }

    private func jobRow(_ job: VideoJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            HStack {
                ClipStatusLabel(progress: projects.progress(ofVideo: job.id)).font(.caption)
                if job.failure != nil {
                    Spacer()
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
                Stepper(value: $frames, in: 2...20) {
                    Text("\(frames) frames per rally from this video").font(.caption).monospacedDigit()
                }
                .fixedSize()
                if !usedBefore.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("You've used this video before", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                        ForEach(usedBefore, id: \.videoId) { use in
                            Text("\(use.videoId) · \(use.range)\(use.clipId == clip.id ? " · this card" : "")")
                                .font(.caption2.monospaced())
                        }
                        Text("Pick a different start to sample new moments, or add it anyway.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button(action: add) {
                        Label(usedBefore.isEmpty ? "Add Video" : "Add Anyway", systemImage: "plus")
                    }
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

    /// Earlier uses of the video in the form, anywhere in the project.
    private var usedBefore: [ProjectsModel.VideoUse] {
        projects.uses(of: projects.fingerprint(of: source))
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
                               license: license, frames: wanted, allowDuplicate: !usedBefore.isEmpty)
        } else {
            guard projects.addVideo(to: clip.id, source: source, start: Self.seconds(start) ?? 0,
                                    length: len, license: license, frames: wanted,
                                    allowDuplicate: !usedBefore.isEmpty) != nil else { return }
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
