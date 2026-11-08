//
//  PlayerLab.swift
//  RallyLab
//
//  The two launches of the player-feasibility research (P0), both decided before any
//  RallyLab model exists — so no project is restored, no phone sync starts, no sampler
//  is created, and the person's RallyLab preferences are not read or written:
//
//    RallyLab --player-lab-run <experiment> --source-project <project> --plan <plan.json> --run <name>
//        PlayerFeaturesRun, headless: reads the source project, writes only <experiment>.
//    RallyLab --player-lab <experiment> [--script <steps.json>]
//        The Player Lab window over <experiment>'s runs (PlayerLabView). With --script it
//        performs the listed steps — choose a run, recording, interval and frame, set the
//        layers, play, snapshot — then quits: the GUI exercised end to end without a pointer.
//

import AppKit
import SwiftUI

enum PlayerLab {
    /// A scripted GUI step; every field optional, applied in this order.
    struct Step: Codable {
        var run: String?
        var recording: String?
        var interval: String?
        var frame: Int?
        /// Layer name (`boxes`, `labels`, `skeletons`, `unmatchedPoses`, `net`, `lane`, `tentative`, `outOfCourt`, `header`) → on/off.
        var layers: [String: Bool]?
        /// Play for this many seconds from the current frame.
        var play: Double?
        var snapshot: String?
        /// Keep the window as it is for this many seconds (an outside screen capture can be taken).
        var hold: Double?
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }

    private static func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }

    /// Starts the requested Player Lab launch and never returns; returns false when none was requested.
    @MainActor
    static func runIfRequested(_ args: [String] = CommandLine.arguments) -> Bool {
        if let experiment = value(after: "--player-lab-run", in: args) {
            guard let source = value(after: "--source-project", in: args), let planPath = value(after: "--plan", in: args),
                  let name = value(after: "--run", in: args) else {
                log("--player-lab-run <experiment> needs --source-project <project> --plan <plan.json> --run <name>")
                exit(2)
            }
            Task { @MainActor in
                do {
                    guard let codeSha = RallyClassifierExporter.buildRevision() else {
                        log("❌ This build doesn't record the commit it was compiled from (source-revision.txt): rebuild it from a git checkout."); exit(1)
                    }
                    let plan = try JSONDecoder().decode(PlayerFeaturesRun.Plan.self, from: Data(contentsOf: path(planPath)))
                    let planSha = DatasetSplitManifest.sha256(of: path(planPath)) ?? "?"
                    let r = try await PlayerFeaturesRun.run(sourceProject: path(source), experiment: path(experiment), name: name, plan: plan,
                                                            codeSha: codeSha, tool: "RallyLab --player-lab-run (plan sha256 \(planSha))",
                                                            log: { log($0) })
                    log("✅ \(PlayerFeatures.schemaVersion): \(r.frames) frames → \(r.folder.path) · manifest \(r.manifestSha256)")
                    exit(0)
                } catch {
                    log("❌ \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        if let experiment = value(after: "--player-lab", in: args) {
            openWindow(experiment: path(experiment), script: value(after: "--script", in: args).map(path))
        }
        return false
    }

    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    }
    private static var closer: Closer?

    @MainActor
    private static func openWindow(experiment: URL, script: URL?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem()
        menu.addItem(appItem)
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Quit Player Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        app.mainMenu = menu
        let model = PlayerLabModel(experiment: experiment)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 980), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Player Lab — \(experiment.lastPathComponent) (research, P0)"
        window.contentView = NSHostingView(rootView: PlayerLabView(model: model))
        closer = Closer()
        window.delegate = closer
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        // The window number lets `screencapture -l <number>` capture the whole window during a scripted `hold`.
        log("Player Lab window \(window.windowNumber)")
        if let script {
            Task { @MainActor in
                do {
                    let steps = try JSONDecoder().decode([Step].self, from: Data(contentsOf: script))
                    try await Task.sleep(for: .milliseconds(500))
                    for (n, s) in steps.enumerated() {
                        try await perform(s, model: model)
                        log("step \(n + 1)/\(steps.count) done\(s.snapshot.map { " → snapshot \($0)" } ?? "")")
                    }
                } catch { log("❌ script: \(error.localizedDescription)") }
                app.terminate(nil)
            }
        }
        app.run()
        exit(0)
    }

    enum ScriptError: LocalizedError {
        case missing(String)
        var errorDescription: String? { if case .missing(let what) = self { return "not found: \(what)" }; return nil }
    }

    @MainActor
    private static func perform(_ s: Step, model: PlayerLabModel) async throws {
        if let r = s.run {
            guard let entry = model.runs.first(where: { $0.name == r }) else { throw ScriptError.missing("run \(r)") }
            model.run = entry
        }
        if let r = s.recording {
            guard model.manifest?.recordings.contains(where: { $0.recordingId == r }) == true else { throw ScriptError.missing("recording \(r)") }
            model.recordingId = r
        }
        if let i = s.interval {
            guard model.recording?.intervals.contains(where: { $0.name == i }) == true else { throw ScriptError.missing("interval \(i)") }
            model.intervalName = i
        }
        if let f = s.frame { model.go(to: f) }
        if let layers = s.layers {
            var o = model.options
            for (k, v) in layers {
                switch k {
                case "boxes": o.boxes = v
                case "labels": o.labels = v
                case "skeletons": o.skeletons = v
                case "unmatchedPoses": o.unmatchedPoses = v
                case "net": o.net = v
                case "lane": o.lane = v
                case "tentative": o.tentative = v
                case "outOfCourt": o.outOfCourt = v
                case "header": o.header = v
                default: throw ScriptError.missing("layer \(k)")
                }
            }
            model.options = o
        }
        if let seconds = s.play {
            model.togglePlay()
            try await Task.sleep(for: .seconds(seconds))
            model.stop()
        }
        await model.waitUntilShown()
        try await Task.sleep(for: .milliseconds(300))
        if let name = s.snapshot { _ = model.snapshot(name: name) }
        if let seconds = s.hold {
            // The window now shows this step: an outside capture taken during the hold is of this step.
            log("ready \(s.snapshot ?? "hold")")
            try await Task.sleep(for: .seconds(seconds))
        }
    }
}
