//
//  TesterFootage.swift
//  RallyLab
//
//  Pulls the footage testers' phones sent (BumpSetCut's data flywheel: every
//  rally of each processed video, as clips) and rallies people posted to the
//  feed into the project, for training in places and light the planned
//  footage doesn't cover. Labelers' own footage is left out (it's in the
//  project already). Each video becomes an extra card, training only, with
//  its surface guessed from the picture; sampling then finds its rallies, so
//  `--pretrack` picks it up like any other video.
//

import AVFoundation
import Foundation
import Vision

@MainActor
enum TesterFootage {

    struct Report { var added = 0, skipped = 0, failed = 0 }

    /// Pull everything not yet in the project; `posted` also pulls rallies
    /// those people posted (one card per person per day).
    static func pull(projects: ProjectsModel, posted: [String], log: (String) -> Void) async -> Report {
        var report = Report()
        let client = LabelingClient.shared
        guard let dir = projects.projectDir else { return report }
        let incoming = dir.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let pulled = Set(projects.project?.clips.compactMap(\.pulledFrom) ?? [])

        var batches: [Batch] = []
        do {
            for footage in try await client.testerFootage() where !pulled.contains(footage.id) {
                let name = footage.username ?? String(footage.userId.prefix(8))
                let day = Self.day.string(from: footage.createdAt)
                batches.append(Batch(key: footage.id, who: name,
                                     notes: "Tester \(name) · \(day) · \(footage.deviceModel ?? "phone")",
                                     license: "tester contribution: \(name), consent \(footage.consentVersion ?? "?"), \(day)",
                                     files: footage.clipUrls.map { .stored($0) }))
            }
            if !posted.isEmpty {
                let clips = try await client.postedClips(by: posted)
                let groups = Dictionary(grouping: clips) { "posted:\($0.profiles.username):\(Self.day.string(from: $0.createdAt))" }
                for (key, group) in groups.sorted(by: { $0.key < $1.key }) where !pulled.contains(key) {
                    let name = group[0].profiles.username, day = Self.day.string(from: group[0].createdAt)
                    let place = group.compactMap(\.locationName).first.map { " · \($0)" } ?? ""
                    batches.append(Batch(key: key, who: name, notes: "Posted by \(name) · \(day)\(place)",
                                         license: "posted to BumpSetCut by \(name), permission, \(day)",
                                         files: group.flatMap(\.urls).map { .posted($0) }))
                }
            }
        } catch {
            log("❌ Couldn't list tester footage: \(error.localizedDescription)")
            report.failed += 1
            return report
        }
        if batches.isEmpty { log("No new tester footage.") }

        for batch in batches {
            // Download every clip first: the surface is guessed from them, and a
            // card is only made once there's something to put on it.
            var files: [URL] = []
            for (i, file) in batch.files.enumerated() {
                let local = incoming.appendingPathComponent("tester-\(UUID().uuidString).mp4")
                do {
                    switch file {
                    case .stored(let path): try await client.download(path, from: "training-data", to: local)
                    case .posted(let url): try await client.downloadPublic(url, to: local)
                    }
                    files.append(local)
                } catch {
                    log("  ⚠️ \(batch.who): clip \(i + 1) didn't download: \(error.localizedDescription)")
                }
            }
            defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
            guard !files.isEmpty else { report.failed += 1; continue }

            let surface = await guessSurface(files)
            guard let card = projects.addTesterCard(environment: surface, notes: batch.notes, pulledFrom: batch.key) else {
                report.failed += 1
                continue
            }
            var added = 0
            for file in files {
                let seconds = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
                guard seconds > 0,
                      let videoId = projects.addVideo(to: card, source: file.path, start: 0, length: seconds + 1,
                                                      license: batch.license) else {
                    report.skipped += 1
                    continue
                }
                if await projects.waitForSampling(videoId) { added += 1 } else { report.failed += 1 }
            }
            report.added += added
            if added == 0 { projects.removeExtra(card) }
            log("▸ \(card) (\(surface), guessed — fix with --move): \(batch.notes) — \(added) of \(files.count) clips")
        }
        return report
    }

    private struct Batch {
        enum File { case stored(String), posted(URL) }
        let key: String, who: String, notes: String, license: String
        let files: [File]
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Surface

    /// "Indoor", "Beach" or "Grass", from Vision's scene labels on a few
    /// frames: no sky or open ground means indoor, then grass if Vision sees
    /// it more than half as surely as beach, else beach. Right on 84 of the 94 Scratch videos (2026-10-11;
    /// every grass one); the misses are beaches with lawns about and frames
    /// that are all players.
    static func guessSurface(_ files: [URL]) async -> String {
        var best: [String: Float] = [:]
        for file in files.prefix(3) {
            let asset = AVURLAsset(url: file)
            guard let seconds = try? await asset.load(.duration).seconds, seconds > 0 else { continue }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            for fraction in [0.25, 0.75] {
                guard let image = try? await generator.image(at: CMTime(seconds: seconds * fraction, preferredTimescale: 600)).image
                else { continue }
                let request = VNClassifyImageRequest()
                try? VNImageRequestHandler(cgImage: image).perform([request])
                for label in request.results ?? [] {
                    best[label.identifier] = max(best[label.identifier] ?? 0, label.confidence)
                }
            }
        }
        func score(_ labels: [String]) -> Float { labels.map { best[$0] ?? 0 }.max() ?? 0 }
        let outdoors = score(["outdoor", "sky", "blue_sky", "cloudy", "night_sky", "land"])
        let indoors = score(["wood_processed", "basketball", "badminton", "scoreboard", "indoor"])
        if outdoors < 0.1 || outdoors <= indoors { return "Indoor" }
        let grass = score(["grass"])
        return grass > 0.05 && grass > score(["beach", "sand", "shore", "palm_tree"]) / 2 ? "Grass" : "Beach"
    }
}
