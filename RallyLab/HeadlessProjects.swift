//
//  HeadlessProjects.swift
//  RallyLab
//
//  The Projects tab from the command line, so a clip can be pulled without
//  opening the app (and Claude can do it from a pasted link):
//
//    RallyLab --project v3 --import-checklist ~/Downloads/BumpSetCut_Clip_Checklist.xlsx
//    RallyLab --project v3 --get grs_onl_sun_land_onl_01 "https://youtube.com/…" \
//             --license "permission: Jake R., DM 2026-09-26" [--start 2:00] [--length 5:00]
//    RallyLab --project v3 --status
//
//  --get cuts the clip, logs it, samples it into the project's dataset and
//  waits for the sampling to finish. The project is created if it's new.
//

import Foundation

enum HeadlessProjects {

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let name = value(after: "--project", in: args) else { return }

        Task { @MainActor in
            let projects = ProjectsModel(sampler: SamplerModel())
            if projects.projectNames.contains(DatasetStore.safeName(name)) {
                projects.open(DatasetStore.safeName(name))
            } else {
                projects.create(name: name)
            }
            log("Project: \(projects.project?.name ?? name) → \(projects.projectDir?.path ?? "?")")

            if let sheet = value(after: "--import-checklist", in: args) {
                projects.importChecklist(URL(fileURLWithPath: (sheet as NSString).expandingTildeInPath))
                log(projects.status)
            }

            var ok = true
            if let i = args.firstIndex(of: "--get") {
                guard args.indices.contains(i + 2) else {
                    log("usage: --get <clip id> <link or file> --license <note> [--start m:ss] [--length m:ss]")
                    exit(2)
                }
                ok = await get(clipId: args[i + 1], source: args[i + 2], args: args, projects: projects)
            }

            if args.contains("--status") || args.contains("--get") {
                printStatus(projects)
            }
            exit(ok ? 0 : 1)
        }
    }

    @MainActor
    private static func get(clipId: String, source: String, args: [String], projects: ProjectsModel) async -> Bool {
        guard projects.project?.clips.contains(where: { $0.id == clipId }) == true else {
            log("❌ \(clipId) isn't in this project's checklist. Import it with --import-checklist first.")
            return false
        }
        guard let license = value(after: "--license", in: args) else {
            log("❌ --license is required (CC-BY, CC0, or \"permission: who, how, when\").")
            return false
        }
        let start = value(after: "--start", in: args).flatMap(seconds) ?? 0
        let length = value(after: "--length", in: args).flatMap(seconds) ?? 300
        let source = FileManager.default.fileExists(atPath: (source as NSString).expandingTildeInPath)
            ? (source as NSString).expandingTildeInPath : source

        projects.getFootage(for: clipId, source: source, start: start, length: length, license: license)
        log("▸ \(clipId): \(projects.status)")

        // Wait through cutting, then sampling.
        var last = ""
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let clip = projects.project?.clips.first(where: { $0.id == clipId }) else { return false }
            let progress = projects.progress(of: clip)
            let line: String
            switch progress {
            case .cutting(let f): line = f.map { "  downloading \(Int($0 * 100))%" } ?? "  cutting…"
            case .sampling(let text): line = "  \(text)"
            case .failed(let why): log("❌ \(why)"); return false
            case .pulled(let frames, _):
                log("✅ \(clipId): \(frames) frames sampled into the dataset")
                return true
            case .notStarted:
                if projects.sampler.isIngesting || !projects.sampler.queue.isEmpty { continue }
                log("❌ \(projects.status)")
                return false
            }
            if line != last, !line.hasPrefix("  downloading") || line.hasSuffix("0%") {
                log(line)
                last = line
            }
        }
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
