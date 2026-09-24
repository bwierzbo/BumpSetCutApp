//
//  HeadlessSampler.swift
//  RallyLab
//
//  `RallyLab --sample <video> [--out dir] [--burst fps] [--random n]` and
//  `RallyLab --sample-folder <frames dir> [--out dir]` run the Sampler
//  without the UI — the pipeline (or the video's .rallylabels.json), the
//  frame pull, the detector pre-labels and the dataset export — then exit.
//  Every frame is kept, since nobody reviewed them; the manifest says so
//  (reviewed=false), and the review can happen later by loading the
//  exported images folder back into the tab.
//

import Foundation

enum HeadlessSampler {

    static func runIfRequested() {
        let args = CommandLine.arguments
        let videoPath = value(after: "--sample", in: args)
        let folderPath = value(after: "--sample-folder", in: args)
        guard videoPath != nil || folderPath != nil else { return }

        let defaultOut = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RallyLab/datasets", isDirectory: true).path
        let out = URL(fileURLWithPath: value(after: "--out", in: args) ?? defaultOut, isDirectory: true)
        let burst = value(after: "--burst", in: args).flatMap(Double.init)
        let random = value(after: "--random", in: args).flatMap(Double.init)
        let confidence = value(after: "--confidence", in: args).flatMap(Double.init)

        Task { @MainActor in
            let sampler = SamplerModel()
            if let burst { sampler.burstFPS = burst }
            if let random { sampler.randomCount = random }
            if let confidence { sampler.prelabelConfidence = confidence }

            let ok: Bool
            if let videoPath {
                ok = await sampleVideo(URL(fileURLWithPath: videoPath), sampler: sampler, out: out)
            } else {
                ok = await sampleFolder(URL(fileURLWithPath: folderPath!, isDirectory: true), sampler: sampler, out: out)
            }
            exit(ok ? 0 : 1)
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1),
              !args[idx + 1].hasPrefix("--") else { return nil }
        return args[idx + 1]
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    @MainActor
    private static func sampleVideo(_ video: URL, sampler: SamplerModel, out: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: video.path) else {
            log("❌ No such video: \(video.path)")
            return false
        }

        // Hand labels when the video has them, else the pipeline's rallies.
        let labelsURL = video.deletingPathExtension().appendingPathExtension("rallylabels.json")
        let labeled = (try? Data(contentsOf: labelsURL))
            .flatMap { try? JSONDecoder().decode([LabeledRally].self, from: $0) } ?? []

        log("▸ \(video.lastPathComponent): running pipeline…")
        let processor = VideoProcessor()
        processor.config = ProcessorConfig()
        processor.collectFrameEvidence = true
        do {
            _ = try await processor.processVideo(video, videoId: UUID())
        } catch ProcessingError.noRalliesDetected {
        } catch {
            log("❌ pipeline failed: \(error.localizedDescription)")
            return false
        }
        let evidence = processor.frameEvidence
        let duration = processor.lastVideoDurationSec
        let rallies: [Interval]
        if labeled.isEmpty {
            rallies = EvidenceReplayer.decidedRanges(
                evidence: evidence, duration: duration, config: ProcessorConfig(),
                minRallySec: 1.1653, padded: false)
            log("  \(rallies.count) predicted rallies, \(evidence.count) evidence frames")
        } else {
            rallies = labeled.map { Interval(start: $0.startTime, end: $0.endTime) }
            log("  \(rallies.count) hand-labeled rallies, \(evidence.count) evidence frames")
        }

        await sampler.sample(video: video, duration: duration, rallies: rallies, evidence: evidence)
        log("  \(sampler.status)")
        return await finish(sampler, out: out)
    }

    @MainActor
    private static func sampleFolder(_ folder: URL, sampler: SamplerModel, out: URL) async -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            log("❌ No such folder: \(folder.path)")
            return false
        }
        log("▸ \(folder.lastPathComponent): pre-labeling files…")
        await sampler.loadFolder(folder)
        log("  \(sampler.status)")
        return await finish(sampler, out: out)
    }

    @MainActor
    private static func finish(_ sampler: SamplerModel, out: URL) async -> Bool {
        guard !sampler.samples.isEmpty else { return false }
        var bySource: [String: Int] = [:]
        for s in sampler.samples { bySource[s.source.label.components(separatedBy: " ")[0], default: 0] += 1 }
        log("  by source: " + bySource.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

        guard let summary = await sampler.export(to: out) else {
            log("❌ \(sampler.status)")
            return false
        }
        log("✅ \(summary.images) images, \(summary.boxes) boxes, \(summary.validation) val → \(summary.directory.path)")
        return true
    }
}
