//
//  ProjectCoverageView.swift
//  RallyLab
//
//  What the multi-frame model has to learn from, and what it still needs:
//  tracked rallies per environment and split against targets, videos with
//  every rally's time marked, sampled frames usable (their video is on the
//  Mac) or blocked, and every video's state — so the next hour of labeling
//  goes where it counts. Targets come from the research: ~50 training and
//  ~30 validation rallies (10+ indoor), validation from 10+ videos.
//

import SwiftUI

struct ProjectCoverageView: View {
    let projects: ProjectsModel

    var body: some View {
        let c = Coverage(sessions: projects.sampler.sessions)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Tile(title: "Tracked rallies", value: "\(c.total(\.trainRallies) + c.total(\.valRallies))",
                         detail: "\(c.total(\.trainRallies)) train · \(c.total(\.valRallies)) val · target 80",
                         progress: Double(c.total(\.trainRallies) + c.total(\.valRallies)) / 80, tint: ReviewStyle.yours)
                    Tile(title: "Labeled rally frames", value: c.total(\.trackedFrames).formatted(),
                         detail: "every frame of a tracked rally", progress: Double(c.total(\.trackedFrames)) / 16_000, tint: .teal)
                    Tile(title: "Rally-time videos", value: "\(c.total(\.markedVideos))",
                         detail: "whole video marked · target 6", progress: Double(c.total(\.markedVideos)) / 6, tint: .purple)
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
                                Meter(value: row.valVideos, target: 3, tint: env.tint)
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Every video").font(.title3.weight(.bold))
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            ForEach(["Video", "Split", "On Mac", "Tracked", "Guesses left", "Rally times", "Sampled"], id: \.self) {
                                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(c.videos) { VideoRow(video: $0) }
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
    static let trainTarget = 17
    static let valTarget = 10
    static let markedTarget = 2

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
        switch name.prefix(3) {
        case "ind": return "Indoor"
        case "bch": return "Beach"
        case "grs": return "Grass"
        default: return "Other"
        }
    }

    init(sessions: [VideoSession]) {
        for s in sessions {
            let env = Self.environment(s.name)
            let onMac = FileManager.default.fileExists(atPath: s.sourcePath)
            let tracks = s.tracks ?? []
            let done = tracks.filter(\.done)
            let sampled = s.frames.filter { $0.keep && $0.reviewed }.count
            let guesses = TrackLabelModel.suggestions(from: s, excluding: tracks).count
            let labels = RallyMarkModel.labelsURL(for: URL(fileURLWithPath: s.sourcePath))
            let rallyTimes = (s.ralliesMarked ?? false) ? "marked" : FileManager.default.fileExists(atPath: labels.path) ? "partial" : "—"
            var row = rows[env] ?? Row()
            if s.split == "val" {
                row.valRallies += done.count
                if !done.isEmpty { row.valVideos += 1 }
            } else {
                row.trainRallies += done.count
            }
            if s.ralliesMarked ?? false { row.markedVideos += 1 }
            row.trackedFrames += done.reduce(0) { $0 + $1.points.filter { $0.state != .unknown }.count }
            if onMac { row.sampledUsable += sampled } else { row.sampledBlocked += sampled }
            rows[env] = row
            videos.append(Video(name: s.name, environment: env, split: s.split, onMac: onMac, done: done.count,
                                unfinished: tracks.count - done.count, guessesLeft: onMac ? guesses : 0,
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

    private var rallyTimesTint: Color {
        switch video.rallyTimes {
        case "marked": return ReviewStyle.yours
        case "partial": return ReviewStyle.guess
        default: return .secondary
        }
    }

    var body: some View {
        GridRow {
            Text(video.name).font(.caption.monospaced()).lineLimit(1)
            Chip(text: video.split, tint: video.split == "val" ? .purple : .secondary)
            Image(systemName: video.onMac ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(video.onMac ? ReviewStyle.yours : Color.red)
            Text(video.unfinished > 0 ? "\(video.done) done · \(video.unfinished) open" : "\(video.done)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(video.done == 0 ? Color.secondary : Color.primary)
            Text(video.guessesLeft > 0 ? "\(video.guessesLeft)" : "—").font(.caption.monospacedDigit())
                .foregroundStyle(video.guessesLeft > 0 ? ReviewStyle.guess : Color.secondary)
            Chip(text: video.rallyTimes, tint: rallyTimesTint)
            Text("\(video.sampled)").font(.caption.monospacedDigit())
                .foregroundStyle(video.onMac ? Color.primary : Color.red)
        }
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
private struct Meter: View {
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
