//
//  HeadlessSampler.swift
//  RallyLab
//
//  `RallyLab --sample <video-or-folder> [more…] [--dataset dir] [--burst fps]
//  [--random n] [--confidence c] [--all-frames]` runs the Sampler tab's
//  ingest queue without the UI — every argument after --sample that isn't a
//  flag is a video or a folder of frames — then writes the labels and
//  data.yaml and exits. Nothing is reviewed, so with the default policy the
//  new frames are parked until they're looked at in the tab; --all-frames
//  labels them anyway.
//

import Foundation

enum HeadlessSampler {

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let start = args.firstIndex(of: "--sample") else { return }

        var inputs: [URL] = []
        var i = start + 1
        while i < args.count, !args[i].hasPrefix("--") {
            inputs.append(URL(fileURLWithPath: args[i]))
            i += 1
        }
        guard !inputs.isEmpty else {
            log("usage: RallyLab --sample <video-or-folder>… [--dataset dir] [--burst fps] [--random n] [--confidence c] [--all-frames]")
            exit(2)
        }

        Task { @MainActor in
            let sampler = SamplerModel()
            if let dir = value(after: "--dataset", in: args) {
                sampler.setDatasetRoot(URL(fileURLWithPath: dir, isDirectory: true))
            }
            if let v = value(after: "--burst", in: args).flatMap(Double.init) { sampler.burstFPS = v }
            if let v = value(after: "--random", in: args).flatMap(Double.init) { sampler.randomCount = v }
            if let v = value(after: "--confidence", in: args).flatMap(Double.init) { sampler.prelabelConfidence = v }
            if args.contains("--all-frames") { sampler.reviewedOnly = false }

            log("Dataset: \(sampler.datasetRoot.path)")
            sampler.enqueue(inputs)
            // enqueue() starts the queue on its own task; wait for that to
            // pick the jobs up, then for the queue to drain.
            while !sampler.isIngesting, sampler.queue.contains(where: { $0.state == .pending }) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await sampler.processQueue()
            while sampler.isIngesting { try? await Task.sleep(nanoseconds: 100_000_000) }

            var ok = true
            for job in sampler.queue {
                switch job.state {
                case .done(let text): log("✅ \(job.url.lastPathComponent): \(text)")
                case .failed(let text): log("❌ \(job.url.lastPathComponent): \(text)"); ok = false
                default: log("⚠️ \(job.url.lastPathComponent): \(job.state)"); ok = false
                }
            }
            sampler.writeDataset()
            log(sampler.status)
            let s = sampler.stats
            log("Dataset now: \(s.videos) videos (\(s.valVideos) val), \(s.frames) frames, \(s.reviewed) reviewed, \(s.boxes) boxes")
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
}
