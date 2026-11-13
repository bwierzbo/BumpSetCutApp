//
//  ProjectCoverageView.swift
//  RallyLab
//
//  What the multi-frame model has to learn from, and what it still needs:
//  tracked rallies per environment and split against targets, videos with
//  every rally's time marked, sampled frames usable (their video is on the
//  Mac) or blocked, and every video's state — so the next hour of labeling
//  goes where it counts. Rallies and frames are what training gets
//  (TrackedRally.isReady, TrainingPlan.labels); targets follow the plan's next rounds: 60 train
//  and 10 val rallies per surface, val from 4+ videos each.
//

import SwiftUI

struct ProjectCoverageView: View {
    let projects: ProjectsModel
    /// Open a recording's task from a row: the marking pass, or its next rally to track (owner, 2026-11-05: "in
    /// coverage I need to be able to see the screen where I mark the rallies and everything else").
    var open: (LabelQueue.Job) -> Void = { _ in }
    /// Put a set-aside recording back in the queue (the backlog; server first, then the session) — the Mac's way
    /// back for a recording the phone never lists (no phone copy).
    var putBack: (String) -> Void = { _ in }
    /// The lead's check of another labeler's footage-type choice (LabelingSync.checkClaim): accept or decline;
    /// returns why it could not be done.
    var check: (RecordingTypeClaim, Bool) async -> String? = { _, _ in nil }

    var body: some View {
        let c = Coverage(sessions: projects.sampler.sessions)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    let rallyTarget = (Coverage.trainTarget + Coverage.valTarget) * TrainingPlan.surfaces.count
                    Tile(title: "Rallies", value: "\(c.total(\.trainRallies) + c.total(\.valRallies))",
                         detail: "\(c.total(\.trainRallies)) train · \(c.total(\.valRallies)) val · target \(rallyTarget)",
                         progress: Double(c.total(\.trainRallies) + c.total(\.valRallies)) / Double(rallyTarget), tint: ReviewStyle.yours)
                    let frameTarget = Coverage.frameTarget(c.total(\.trackedFrames))
                    Tile(title: "Labeled rally frames", value: c.total(\.trackedFrames).formatted(),
                         detail: "what training gets · next round \(frameTarget.formatted())",
                         progress: Double(c.total(\.trackedFrames)) / Double(frameTarget), tint: .teal)
                    let markedTarget = Coverage.markedTarget * TrainingPlan.surfaces.count
                    Tile(title: "Rally-time videos", value: "\(c.total(\.markedVideos))",
                         detail: "whole video marked · target \(markedTarget)", progress: Double(c.total(\.markedVideos)) / Double(markedTarget), tint: .purple)
                    Tile(title: "Sampled frames usable", value: c.total(\.sampledUsable).formatted(),
                         detail: "\(c.total(\.sampledBlocked).formatted()) blocked: video not on this Mac",
                         progress: Double(c.total(\.sampledUsable)) / Double(max(1, c.total(\.sampledUsable) + c.total(\.sampledBlocked))),
                         tint: .blue)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("By environment").font(.title3.weight(.bold))
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                        GridRow {
                            Text("")
                            header("Train rallies", "target \(Coverage.trainTarget) each")
                            header("Val rallies", "target \(Coverage.valTarget) each")
                            header("Val videos", "with a tracked rally")
                            header("Rally-time videos", "target \(Coverage.markedTarget) each")
                        }
                        ForEach(ClipBoardView.environments, id: \.name) { env in
                            let row = c.rows[env.name] ?? Coverage.Row()
                            GridRow {
                                Label(env.name, systemImage: env.icon).foregroundStyle(env.tint).font(.headline)
                                Meter(value: row.trainRallies, target: Coverage.trainTarget, tint: env.tint)
                                Meter(value: row.valRallies, target: Coverage.valTarget, tint: env.tint)
                                Meter(value: row.valVideos, target: Coverage.valVideoTarget, tint: env.tint)
                                Meter(value: row.markedVideos, target: Coverage.markedTarget, tint: env.tint)
                            }
                        }
                    }
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                }

                if !c.nextSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Do next").font(.title3.weight(.bold))
                        ForEach(Array(c.nextSteps.enumerated()), id: \.offset) { _, step in
                            Label {
                                Text(step.text).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: step.icon).foregroundStyle(step.tint)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                }

                FootageTypeList(projects: projects, open: open, putBack: putBack, check: check)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Every video").font(.title3.weight(.bold))
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            ForEach(["Video", "Split", "On Mac", "Rallies", "Guesses left", "Rally times", "Sampled", ""], id: \.self) {
                                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(c.videos) { video in
                            VideoRow(video: video) { OpenButtons(name: video.name, projects: projects, open: open, putBack: putBack) }
                        }
                    }
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                }
            }
            .padding(20)
        }
        .background(.background.secondary)
    }

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Coverage of the multi-frame training data, from the dataset's sessions.
@MainActor
struct Coverage {
    static let trainTarget = 60
    static let valTarget = 10
    static let valVideoTarget = 4
    static let markedTarget = 4

    /// The frames of the next round in the plan above `frames` (the last round's once past it).
    static func frameTarget(_ frames: Int) -> Int {
        TrainingPlan.rounds.first { $0.frames > frames }?.frames ?? TrainingPlan.rounds.last?.frames ?? frames
    }

    struct Row {
        var trainRallies = 0, valRallies = 0, valVideos = 0, markedVideos = 0
        var trackedFrames = 0, sampledUsable = 0, sampledBlocked = 0
    }

    struct Video: Identifiable {
        var id: String { name }
        let name: String, environment: String, split: String, onMac: Bool
        let done: Int, unfinished: Int, guessesLeft: Int, rallyTimes: String, sampled: Int
    }

    struct Step { let text: String; let icon: String; let tint: Color }

    var rows: [String: Row] = [:]
    var videos: [Video] = []
    var nextSteps: [Step] = []

    func total(_ key: KeyPath<Row, Int>) -> Int { rows.values.reduce(0) { $0 + $1[keyPath: key] } }

    static func environment(_ name: String) -> String {
        ClipID.surface(of: name)?.title ?? "Other"
    }

    init(sessions: [VideoSession]) {
        for s in sessions {
            let env = Self.environment(s.name)
            let onMac = FileManager.default.fileExists(atPath: s.sourcePath)
            let tracks = s.tracks ?? []
            let done = tracks.filter(\.isReady)
            let sampled = s.frames.filter { $0.keep && $0.reviewed }.count
            let guesses = TrackLabelModel.suggestions(from: s, excluding: tracks).count
            let labels = RallyMarkModel.labelsURL(for: URL(fileURLWithPath: s.sourcePath))
            let rallyTimes = s.backlogAt != nil ? "backlog" : (s.ralliesMarked ?? false) ? "marked" : FileManager.default.fileExists(atPath: labels.path) ? "partial" : "—"
            var row = rows[env] ?? Row()
            if s.split == "val" {
                row.valRallies += done.count
                if !done.isEmpty { row.valVideos += 1 }
            } else {
                row.trainRallies += done.count
            }
            if s.ralliesMarked ?? false { row.markedVideos += 1 }
            row.trackedFrames += done.reduce(0) { $0 + TrainingPlan.labels(labeled: $1.labeledFrames, checked: $1.checkedFrames, split: s.split) }
            if onMac { row.sampledUsable += sampled } else { row.sampledBlocked += sampled }
            rows[env] = row
            videos.append(Video(name: s.name, environment: env, split: s.split, onMac: onMac, done: done.count,
                                unfinished: tracks.filter(\.isOpen).count, guessesLeft: onMac ? guesses : 0,
                                rallyTimes: rallyTimes, sampled: sampled))
        }
        videos.sort { ($0.environment, $0.split, $0.name) < ($1.environment, $1.split, $1.name) }
        nextSteps = Self.steps(rows: rows, videos: videos)
    }

    /// The gaps that matter most, in order: validation first (scores you
    /// can trust), then missing videos (labels already done), then where
    /// the Sampler already found rallies to track.
    private static func steps(rows: [String: Row], videos: [Video]) -> [Step] {
        var steps: [Step] = []
        for env in ["Indoor", "Beach", "Grass"] {
            let r = rows[env] ?? Row()
            guard r.valRallies < valTarget else { continue }
            let openVal = videos.filter { $0.environment == env && $0.split == "val" && $0.onMac }
            let detail = openVal.isEmpty
                ? "No \(env.lowercased()) validation video is on this Mac — move one to Val."
                : "Track rallies in " + openVal.prefix(3).map(\.name).joined(separator: ", ") + "."
            steps.append(Step(text: "\(env) validation: \(r.valRallies) of \(valTarget) rallies. \(detail)",
                              icon: "checkmark.shield", tint: r.valRallies == 0 ? .red : .orange))
        }
        let unfinished = videos.filter { $0.unfinished > 0 }
        if !unfinished.isEmpty {
            steps.append(Step(text: "\(unfinished.reduce(0) { $0 + $1.unfinished }) tracked rallies aren't marked done (D): "
                              + unfinished.map(\.name).joined(separator: ", ") + ".",
                              icon: "checkmark.circle", tint: .orange))
        }
        let missing = videos.filter { !$0.onMac }
        if !missing.isEmpty {
            steps.append(Step(text: "\(missing.count) videos aren't on this Mac — their \(missing.reduce(0) { $0 + $1.sampled }) labeled frames can't train the multi-frame model until they're restored.",
                              icon: "externaldrive.badge.exclamationmark", tint: .red))
        }
        let guesses = videos.filter { $0.guessesLeft > 0 && $0.split == "train" }.sorted { $0.guessesLeft > $1.guessesLeft }
        if !guesses.isEmpty {
            steps.append(Step(text: "Most rallies ready to track: " + guesses.prefix(4).map { "\($0.name) (\($0.guessesLeft))" }.joined(separator: ", ")
                              + ". A few from each beats many from one.",
                              icon: "scope", tint: .teal))
        }
        for env in ["Indoor", "Beach", "Grass"] where (rows[env]?.markedVideos ?? 0) < markedTarget {
            steps.append(Step(text: "\(env): \(rows[env]?.markedVideos ?? 0) of \(markedTarget) videos with every rally's time marked (Track → Rally times).",
                              icon: "timeline.selection", tint: .purple))
        }
        return steps
    }
}

private struct VideoRow: View {
    let video: Coverage.Video
    let actions: () -> OpenButtons

    private var rallyTimesTint: Color {
        switch video.rallyTimes {
        case "marked": return ReviewStyle.yours
        case "partial": return ReviewStyle.guess
        case "backlog": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        GridRow {
            Text(video.name).font(.caption.monospaced()).lineLimit(1)
            Chip(text: video.split, tint: video.split == "val" ? .purple : .secondary)
            Image(systemName: video.onMac ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(video.onMac ? ReviewStyle.yours : Color.red)
            Text(video.unfinished > 0 ? "\(video.done) · \(video.unfinished) open" : "\(video.done)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(video.done == 0 ? Color.secondary : Color.primary)
            Text(video.guessesLeft > 0 ? "\(video.guessesLeft)" : "—").font(.caption.monospacedDigit())
                .foregroundStyle(video.guessesLeft > 0 ? ReviewStyle.guess : Color.secondary)
            Chip(text: video.rallyTimes, tint: rallyTimesTint)
            Text("\(video.sampled)").font(.caption.monospacedDigit())
                .foregroundStyle(video.onMac ? Color.primary : Color.red)
            actions()
        }
    }
}

/// From any row straight to the recording's work: the marking pass (Mark the rallies), or its next rally to track.
struct OpenButtons: View {
    let name: String
    let projects: ProjectsModel
    let open: (LabelQueue.Job) -> Void
    var putBack: (String) -> Void = { _ in }

    var body: some View {
        let session = projects.sampler.sessions.first { $0.name == name }
        HStack(spacing: 6) {
            Button("Mark") { open(.review(name)) }
                .help("Mark the rallies in this recording (the live pass)")
            Button("Track") { if let s = session, let rally = LabelQueue.Video.nextRally(in: s) { open(.track(name, rally)) } }
                .disabled(session.flatMap { LabelQueue.Video.nextRally(in: $0) } == nil)
                .help("Track the next rally of this recording frame by frame")
            if session?.backlogAt != nil {
                Button("Put back") { putBack(name) }
                    .help("Set aside (the backlog): \(session?.backlogReason ?? "no reason given") — put it back in the queue on the phone and the Mac")
            }
        }
        .controlSize(.small)
        .disabled(session == nil)
    }
}

private struct Tile: View {
    let title: String, value: String, detail: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
            ProgressView(value: min(max(progress, 0), 1)).tint(tint)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// value / target with a bar; empty shows red, met shows a check.
struct Meter: View {
    let value: Int, target: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\(value)").font(.headline.monospacedDigit()).foregroundStyle(value == 0 ? .red : .primary)
                Text("/ \(target)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if value >= target { Image(systemName: "checkmark.circle.fill").foregroundStyle(ReviewStyle.yours).font(.caption) }
            }
            ProgressView(value: min(Double(value) / Double(max(target, 1)), 1)).tint(value == 0 ? .red : tint)
                .frame(width: 120)
        }
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Footage type: what still needs confirming, and what each recording is

/// Every recording's footage type as the project knows it (the footage-properties record, D-032) and as the phone
/// has asked for it (the newest claim on the server, D-033): the ones still to confirm first — a marked recording
/// with no confirmed type is what holds the classifier's negatives back — with a Confirm button that opens the same
/// step the pass ends with. Owner, 2026-11-05: "a list in the GUI of things to be confirmed with the type of
/// footage it is".
struct FootageTypeList: View {
    let projects: ProjectsModel
    var open: (LabelQueue.Job) -> Void = { _ in }
    var putBack: (String) -> Void = { _ in }
    var check: (RecordingTypeClaim, Bool) async -> String? = { _, _ in nil }

    /// This Mac's account: a claim it sent is the lead's own and counts without a check (D-033 amendment).
    @State private var me: UUID?
    /// Other labelers' names (the lead's view of them, labeler_summary); a short id when unknown.
    @State private var names: [UUID: String] = [:]
    @State private var checkProblem: String?

    @State private var claims: [String: RecordingTypeClaim] = [:]
    @State private var claimsProblem: String?
    @State private var records: [String: FootageProperties.File] = [:]
    @State private var unreadable: [String: String] = [:]
    @State private var onlyUnconfirmed = true
    @State private var confirming: Confirming?
    @State private var reloads = 0

    private struct Confirming: Identifiable {
        let id = UUID()
        let session: VideoSession
        let opening: ProjectsModel.Opening
    }

    struct Row: Identifiable {
        var id: String { name }
        let name: String
        let marked: Bool
        /// The confirmed type with its provenance; nil when no one has confirmed one.
        let confirmed: (type: FootageProperties.RecordingType, by: String?, at: String?)?
        /// The phone's newest claim, when there is one and nothing is confirmed yet.
        let claim: RecordingTypeClaim?
        let unreadable: String?
        var backlog: Bool = false
        /// The claim is another labeler's, waiting for the lead's check.
        var awaitingCheck: Bool = false
        var needsConfirming: Bool { confirmed == nil }
        /// Marked all the way through, no type confirmed, and no phone choice waiting for the Mac (a refused one
        /// asks again; another labeler's waits for you); set-aside recordings wait.
        var toConfirm: Bool {
            guard marked, confirmed == nil, !backlog else { return false }
            return awaitingCheck || (claim.map { $0.status == .rejected || $0.status == .superseded } ?? true)
        }
    }

    var rows: [Row] {
        let project = projects.project
        let all = projects.sampler.sessions.map { s -> Row in
            // A record bound to another file's fingerprint (the recording was replaced under its name) is not this
            // recording's confirmation — the confirmation step's and the source index's rule.
            let record = (records[DatasetStore.safeName(s.name)] ?? records[s.name]).flatMap { r in
                FootageTypeConfirmation.anotherFile(r, sourceFingerprint: FootageTypeConfirmation.sourceFingerprint(of: s.name, in: project)) == nil ? r : nil
            }
            let confirmed = record.flatMap { r in r.recordingTypeAt == nil ? nil : (r.recordingType, r.recordingTypeBy, r.recordingTypeAt) }
            let claim = claims[s.name]
            return Row(name: s.name, marked: s.ralliesMarked ?? false, confirmed: confirmed, claim: claim,
                       unreadable: unreadable[DatasetStore.safeName(s.name)] ?? unreadable[s.name], backlog: s.backlogAt != nil,
                       awaitingCheck: claim.map { $0.status == .submitted && (me == nil || $0.submittedBy != me) } ?? false)
        }
        // Marked and unconfirmed first (they gate training), then unmarked and unconfirmed, then the confirmed.
        return all.sorted { a, b in
            let ka = (a.needsConfirming ? 0 : 1, a.marked ? 0 : 1, a.name), kb = (b.needsConfirming ? 0 : 1, b.marked ? 0 : 1, b.name)
            return ka < kb
        }
    }

    var body: some View {
        let rows = rows
        let shown = onlyUnconfirmed ? rows.filter(\.toConfirm) : rows
        let marked = rows.filter(\.marked)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Footage type").font(.title3.weight(.bold))
                Text("\(rows.count - rows.filter(\.needsConfirming).count) of \(rows.count) confirmed · \(marked.filter { !$0.needsConfirming }.count) of \(marked.count) marked recordings")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Only marked ones still to confirm (\(rows.filter(\.toConfirm).count))", isOn: $onlyUnconfirmed).toggleStyle(.checkbox).font(.callout)
            }
            if let claimsProblem {
                Label(claimsProblem, systemImage: "iphone.slash").font(.caption).foregroundStyle(.secondary)
            }
            if let checkProblem {
                Label(checkProblem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if shown.isEmpty {
                Text(onlyUnconfirmed ? "Every marked recording has a footage type confirmed or waiting for the Mac." : "No recordings.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Video", "Pass", "Footage type", "Phone", "", " "], id: \.self) {
                            Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(shown) { row in
                        GridRow {
                            Text(row.name).font(.caption.monospaced()).lineLimit(1)
                            Chip(text: row.marked ? "marked" : "not finished", tint: row.marked ? ReviewStyle.yours : .secondary)
                            if let c = row.confirmed {
                                // Confirmed means a person is on record (`recordingTypeAt`); the date itself is only shown.
                                Chip(text: RecordingTypeClaims.reviewed(kind: RecordingTypeClaims.Kind(rawValue: c.type.rawValue), at: c.at.map { Self.date($0) ?? Date() }),
                                     tint: c.type == .continuous ? ReviewStyle.yours : c.type == .edited ? .orange : .secondary)
                            } else if let why = row.unreadable {
                                Chip(text: "record unreadable", tint: .red).help(why)
                            } else {
                                Chip(text: "not yet reviewed", tint: .secondary)
                            }
                            if let claim = row.claim, row.awaitingCheck {
                                // Another labeler's choice: yours to check, as their ball frames are.
                                HStack(spacing: 6) {
                                    Text("\(who(claim)): \(claim.kind?.title ?? claim.recordingType)").font(.caption).lineLimit(1)
                                    Button("Accept") { review(claim, accept: true) }.controlSize(.small)
                                    Button("Decline") { review(claim, accept: false) }.controlSize(.small)
                                }
                            } else if let claim = row.claim {
                                Text(Self.phone(claim)).font(.caption).foregroundStyle(claim.status == .rejected ? .red : .secondary).lineLimit(1)
                            } else {
                                Text("—").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(row.confirmed == nil ? "Confirm…" : "Change…") {
                                guard let opening = projects.opening, let session = projects.sampler.sessions.first(where: { $0.name == row.name }) else { return }
                                confirming = Confirming(session: session, opening: opening)
                            }
                            .controlSize(.small).disabled(projects.opening == nil)
                            OpenButtons(name: row.name, projects: projects, open: open, putBack: putBack)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        .task(id: "\(reloads)-\(projects.opening?.generation.uuidString ?? "")") { await load() }
        .sheet(item: $confirming) { step in
            FootageTypeSheet(recording: FootageTypeConfirmation.Recording(step.session), opening: step.opening, projects: projects,
                             duration: nil, afterPass: false) {
                confirming = nil
                reloads += 1
            }
        }
    }

    /// The records from the project's files; the phone's claims from the server (the newest per recording). Read
    /// for the opening in force when the load began: another project opened meanwhile keeps nothing of it (the
    /// task restarts for the new opening), and nothing read for the old one lands on the new one's names.
    private func load() async {
        records = [:]; unreadable = [:]; claims = [:]; claimsProblem = nil
        guard let opening = projects.opening else { return }
        let me = await LabelingClient.shared.userId
        let names = (try? await LabelingClient.shared.labelerSummary())?.map { ($0.labeler, $0.name) } ?? []
        // The awaits above suspend: a project opened meanwhile gets nothing of this one's.
        guard !Task.isCancelled, projects.opening == opening else { return }
        self.me = me
        self.names = Dictionary(names, uniquingKeysWith: { a, _ in a })
        if let all = try? FootageProperties.Store(root: opening.root).loadAll() { records = all.records; unreadable = all.unreadable }
        do {
            let rows = try await LabelingClient.shared.recordingTypeClaims(since: nil).filter { $0.project == opening.name }
            guard projects.opening == opening else { return }
            var newest: [String: RecordingTypeClaim] = [:]
            for c in rows where (newest[c.sessionName].map { ($0.revision, $0.submittedAt) < (c.revision, c.submittedAt) } ?? true) { newest[c.sessionName] = c }
            claims = newest
            claimsProblem = nil
        } catch {
            guard projects.opening == opening else { return }
            claims = [:]
            claimsProblem = "The phone's choices can't be read: \(error.localizedDescription) (sign in under Plan)"
        }
    }

    private func who(_ c: RecordingTypeClaim) -> String {
        c.submittedBy.map { names[$0] ?? String($0.uuidString.lowercased().prefix(8)) } ?? "a labeler"
    }

    /// Accepted, the next sync round applies it (a few seconds); declined, it is settled now. The list reloads after.
    private func review(_ claim: RecordingTypeClaim, accept: Bool) {
        Task {
            checkProblem = await check(claim, accept)
            if accept { try? await Task.sleep(for: .seconds(4)) }
            reloads += 1
        }
    }

    private static func phone(_ c: RecordingTypeClaim) -> String {
        let kind = c.kind?.title ?? c.recordingType
        switch c.status {
        case .submitted: return "\(kind) · waiting for the Mac"
        case .accepted: return "\(kind) · accepted"
        case .rejected: return "\(kind) · not accepted" + (c.reason.map { " — \($0)" } ?? "")
        case .superseded: return "\(kind) · replaced"
        }
    }

    private static func date(_ iso: String) -> Date? { ISO8601DateFormatter().date(from: iso) }
}
