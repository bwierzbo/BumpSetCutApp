//
//  HeadlessProjects.swift
//  RallyLab
//
//  The Projects tab from the command line, so a clip can be pulled without
//  opening the app (and Claude can do it from a pasted link):
//
//    RallyLab --project v3 --get grs_onl_sun_land_onl_01 "https://youtube.com/…" \
//             --license "permission: Jake R., DM 2026-09-26" [--start 2:00] [--length 5:00] [--frames 80]
//             [--allow-duplicate]   (add a stretch of a video already used)
//    RallyLab --project v3 --move ind_ele_bright_land_self_01_v2 bch_ele_sun_land_self_01
//    RallyLab --project v3 --status
//    RallyLab --project v3 --location /Volumes/Footage   (new project, somewhere else)
//
//    RallyLab --project v3 --package                       (training package zip)
//    RallyLab --project v3 --package-multiframe            (multi-frame package zip)
//    RallyLab --project v3 --add-model ~/Desktop/best.pt   (convert + add)
//    RallyLab --project v3 --evaluate [--candidate <model name>] [--all] [--threshold 0.6] [--letterbox]
//
//  --project takes a known project's name or a path to its folder.
//
//  --get adds a video to the clip (clips take any number): cuts it, logs it,
//  samples it into the project's dataset and waits for the sampling to
//  finish. A new project is created with the
//  standard clip plan.
//

import Foundation

enum HeadlessProjects {

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let name = value(after: "--project", in: args) else { return }

        Task { @MainActor in
            let projects = ProjectsModel(sampler: SamplerModel())
            // A path opens (or creates) that folder; a bare name finds a known
            // project, else creates one in --location or the default place.
            let expanded = (name as NSString).expandingTildeInPath
            if name.contains("/") {
                let dir = URL(fileURLWithPath: expanded, isDirectory: true)
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.json").path) {
                    projects.open(dir)
                } else {
                    projects.create(name: dir.lastPathComponent, in: dir.deletingLastPathComponent())
                }
            } else if let known = projects.knownProjects.first(where: { $0.lastPathComponent == DatasetStore.safeName(name) }) {
                projects.open(known)
            } else {
                let location = value(after: "--location", in: args)
                    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                    ?? ProjectsModel.defaultLocation
                projects.create(name: name, in: location)
            }
            log("Project: \(projects.project?.name ?? name) → \(projects.projectDir?.path ?? "?")")

            var ok = true
            if let i = args.firstIndex(of: "--get") {
                guard args.indices.contains(i + 2) else {
                    log("usage: --get <clip id> <link or file> --license <note> [--start m:ss] [--length m:ss] [--frames n] [--allow-duplicate]")
                    exit(2)
                }
                ok = await get(clipId: args[i + 1], source: args[i + 2], args: args, projects: projects)
            }

            if ok, let i = args.firstIndex(of: "--move") {
                guard args.indices.contains(i + 2) else {
                    log("usage: --move <video id> <to clip id>")
                    exit(2)
                }
                ok = await move(videoId: args[i + 1], to: args[i + 2], projects: projects)
            }

            if args.contains("--status") || args.contains("--get") || args.contains("--move") {
                printStatus(projects)
            }

            let library = ModelLibrary(sampler: projects.sampler)
            if ok, args.contains("--package") { ok = await package(library) }
            if ok, args.contains("--package-multiframe") { ok = await packageMultiFrame(library) }
            if ok, let model = value(after: "--add-model", in: args) {
                await library.addModel(URL(fileURLWithPath: (model as NSString).expandingTildeInPath))
                log(library.status)
                ok = !library.status.lowercased().contains("fail") && !library.status.contains("Add a")
            }
            if ok, args.contains("--evaluate") { ok = await evaluate(library, args: args) }
            exit(ok ? 0 : 1)
        }
    }

    @MainActor
    private static func get(clipId: String, source: String, args: [String], projects: ProjectsModel) async -> Bool {
        guard projects.project?.clips.contains(where: { $0.id == clipId }) == true else {
            log("❌ \(clipId) isn't in the clip plan (see StandardClipPlan.swift).")
            return false
        }
        guard let license = value(after: "--license", in: args) else {
            log("❌ --license is required (CC-BY, CC0, or \"permission: who, how, when\").")
            return false
        }
        let start = value(after: "--start", in: args).flatMap(seconds) ?? 0
        let length = value(after: "--length", in: args).flatMap(seconds) ?? 300
        let frames = value(after: "--frames", in: args).flatMap { Int($0) }
        let source = FileManager.default.fileExists(atPath: (source as NSString).expandingTildeInPath)
            ? (source as NSString).expandingTildeInPath : source

        guard let videoId = projects.addVideo(to: clipId, source: source, start: start, length: length,
                                              license: license, frames: frames,
                                              allowDuplicate: args.contains("--allow-duplicate")) else {
            log("❌ \(projects.status)")
            return false
        }
        log("▸ \(videoId): \(projects.status)")

        // Wait through cutting, then sampling.
        var last = ""
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let progress = projects.progress(ofVideo: videoId)
            let line: String
            switch progress {
            case .busy(let stage, let overall):
                line = "  \(stage)" + (overall.map { " \(Int($0 * 10) * 10)%" } ?? "")
            case .failed(let why): log("❌ \(why)"); return false
            case .pulled(let frames, _):
                log("✅ \(videoId): \(frames) frames sampled into the dataset")
                return true
            case .notStarted:
                if projects.sampler.isIngesting || !projects.sampler.queue.isEmpty { continue }
                log("❌ \(projects.status)")
                return false
            }
            if line != last {
                log(line)
                last = line
            }
        }
    }

    @MainActor
    private static func move(videoId: String, to targetId: String, projects: ProjectsModel) async -> Bool {
        guard let from = projects.project?.clips.first(where: { clip in
            clip.videos.contains { clip.videoId(of: $0) == videoId }
        }) else {
            log("❌ No video \(videoId) in this project.")
            return false
        }
        projects.moveVideo(videoId, from: from.id, to: targetId)
        guard projects.moving.contains(videoId) else { log("❌ \(projects.status)"); return false }
        while projects.moving.contains(videoId) || projects.sampler.isIngesting || !projects.sampler.queue.allSatisfy(\.isFinished) {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        log(projects.status.hasPrefix("Moved") ? "✅ \(projects.status)" : "❌ \(projects.status)")
        return projects.status.hasPrefix("Moved")
    }

    @MainActor
    private static func package(_ library: ModelLibrary) async -> Bool {
        library.exportPackage()
        while library.isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
        log(library.status)
        return library.lastPackage != nil
    }

    @MainActor
    private static func packageMultiFrame(_ library: ModelLibrary) async -> Bool {
        library.exportMultiFramePackage()
        while library.isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
        log(library.status)
        return library.lastMultiFramePackage != nil
    }

    @MainActor
    private static func evaluate(_ library: ModelLibrary, args: [String]) async -> Bool {
        library.evaluateValOnly = !args.contains("--all")
        library.alwaysLetterbox = args.contains("--letterbox")
        if let t = value(after: "--threshold", in: args).flatMap(Double.init) { library.threshold = t }
        if let name = value(after: "--candidate", in: args) {
            guard let entry = library.models.first(where: { $0.name == name }) else {
                log("❌ No model called \(name). Models: \(library.models.map(\.name).joined(separator: ", "))")
                return false
            }
            library.candidate = entry
        }
        library.evaluate()
        while library.isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
        log(library.status)
        guard !library.results.isEmpty else { return false }
        for entry in [library.baseline] + (library.candidate.map { [$0] } ?? []) {
            guard let result = library.results[entry.id] else { continue }
            let score = result.score(at: library.threshold)
            func line(_ label: String, _ c: ModelEvaluation.Result.Counts) -> String {
                String(format: "  %-9@ P %5.1f%%  R %5.1f%%  F1 %5.1f%%   found %d  false %d  missed %d",
                       label, c.precision * 100, c.recall * 100, c.f1 * 100, c.tp, c.fp, c.fn)
            }
            log("\(entry.name) @ \(String(format: "%.2f", library.threshold))")
            log(line("All", score.all))
            for (env, c) in score.byEnv { log(line(env, c)) }
        }
        return true
    }

    @MainActor
    private static func printStatus(_ projects: ProjectsModel) {
        for (env, t) in projects.tallies() {
            log("  \(env.padding(toLength: 7, withPad: " ", startingAt: 0)) \(t.recorded)/\(t.total) footage · \(t.pulled) pulled · \(t.labeled) labeled")
        }
    }

    private static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return total
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
