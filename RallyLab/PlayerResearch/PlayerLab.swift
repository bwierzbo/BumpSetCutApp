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
//    RallyLab --player-lab-court <experiment> --run <run> --report <name> [--propose] [--audit <csv>]
//        CourtPilot, headless: court proposals and zones over an existing run; writes only <experiment>.
//    RallyLab --player-lab-court <experiment> --run <run> --import-web <export.json> [--dry-run]
//        CourtWebImport: the owner's decisions from the Court Check page into <experiment>/court-calibrations.
//    RallyLab --player-lab <experiment> [--run <run>] [--court] [--script <steps.json>]
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
        /// Court calibration (P2), applied after the frame and before the snapshot: `players` or `court` mode; the
        /// answers about the court; run the automatic proposals; start from one (`net_guided_v1`…) or place by hand
        /// (`manual`); move points (role → [x, y]); confirm as a scripted test (recorded as `player_lab_script`, never
        /// used as evidence); split at the current frame.
        var mode: String?
        var surface: String?
        var format: String?
        var markings: String?
        var propose: Bool?
        var start: String?
        var move: [String: [Double]]?
        var scriptConfirm: Bool?
        var split: Bool?
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
        if let experiment = value(after: "--player-lab-court", in: args) {
            if let run = value(after: "--run", in: args), let name = value(after: "--make-review", in: args) {
                Task { @MainActor in
                    do {
                        var avoid: [String: Set<Int>] = [:]
                        if let a = value(after: "--audit", in: args).map(path), let text = try? String(contentsOf: a, encoding: .utf8) {
                            // The earlier (Claude) audit's frames are left out: the review is a fresh sample.
                            let rows = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
                            if let h = rows.first, let r = h.firstIndex(of: "recording"), let t = h.firstIndex(of: "tick") {
                                for row in rows.dropFirst() where row.count > max(r, t) { if let k = Int(row[t]) { avoid[row[r], default: []].insert(k) } }
                            }
                        }
                        let out = try await CourtReview.make(experiment: path(experiment), runName: run, name: name,
                                                             perRecording: Int(value(after: "--per-recording", in: args) ?? "") ?? 4, avoid: avoid, log: { log($0) })
                        log("✅ review sheets → \(out.path)")
                        exit(0)
                    } catch { log("❌ \(error.localizedDescription)"); exit(1) }
                }
                dispatchMain()
            }
            if let run = value(after: "--run", in: args), let file = value(after: "--import-web", in: args) {
                Task { @MainActor in
                    do {
                        let out = try CourtWebImport.run(experiment: path(experiment), runName: run, exportFile: path(file),
                                                         dryRun: args.contains("--dry-run"), log: { log($0) })
                        log("✅ \(out.filter(\.applied).count) of \(out.count) page decisions applied")
                        exit(0)
                    } catch { log("❌ \(error.localizedDescription)"); exit(1) }
                }
                dispatchMain()
            }
            guard let run = value(after: "--run", in: args), let report = value(after: "--report", in: args) else {
                log("--player-lab-court <experiment> needs --run <run> --report <name> [--propose] [--audit <csv>] [--review <dir>], or --run <run> --make-review <name> [--per-recording n] [--audit <csv>], or --run <run> --import-web <export.json> [--dry-run]")
                exit(2)
            }
            Task { @MainActor in
                do {
                    let out = try await CourtPilot.run(experiment: path(experiment), runName: run, report: report, propose: args.contains("--propose"),
                                                       auditCSV: value(after: "--audit", in: args).map(path), reviewDir: value(after: "--review", in: args).map(path),
                                                       codeSha: RallyClassifierExporter.buildRevision(), log: { log($0) })
                    log("✅ court pilot → \(out.path)")
                    exit(0)
                } catch {
                    log("❌ \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        if let experiment = value(after: "--player-lab", in: args) {
            openWindow(experiment: path(experiment), script: value(after: "--script", in: args).map(path), run: value(after: "--run", in: args),
                       court: args.contains("--court"))
        }
        return false
    }

    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    }
    private static var closer: Closer?

    @MainActor
    private static func openWindow(experiment: URL, script: URL?, run: String?, court: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem()
        menu.addItem(appItem)
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Quit Player Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        app.mainMenu = menu
        let model = PlayerLabModel(experiment: experiment)
        if let run, let entry = model.runs.first(where: { $0.name == run }) { model.run = entry }
        if court { model.mode = .court }
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

    /// The calibration editor as drawn (SwiftUI's own rendering of the view, at 1400 × 800) beside the snapshot: an
    /// outside window capture needs a screen-recording grant this tool may not have.
    @MainActor
    private static func renderEditor(model: PlayerLabModel, court: CourtCalibrationModel, name: String) {
        guard let run = model.run else { return }
        let renderer = ImageRenderer(content: CourtCalibrationEditor(model: model, court: court).frame(width: 1400, height: 800).background(Color.black))
        renderer.scale = 1
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let safe = name.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        try? png.write(to: run.folder.appendingPathComponent("gui-snapshots/\(safe)-editor.png"))
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
        if let m = s.mode {
            guard let mode = PlayerLabModel.Mode.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(m.lowercased()) }) else { throw ScriptError.missing("mode \(m)") }
            model.mode = mode
        }
        if let court = model.court {
            if let v = s.surface { court.answer(surface: .some(CourtSetup.Surface(rawValue: v))) }
            if let v = s.format { court.answer(format: .some(CourtSetup.Format(rawValue: v))) }
            if let v = s.markings { court.answer(markings: .some(CourtSetup.Markings(rawValue: v))) }
            if s.propose == true { await court.propose() }
            if let start = s.start {
                if start == "manual" { court.placeManually() } else {
                    guard let m = CourtProposal.Method(rawValue: start) else { throw ScriptError.missing("proposal \(start)") }
                    court.use(m)
                }
            }
            for (role, p) in s.move ?? [:] {
                guard let r = CourtLayout.Role(rawValue: role), p.count == 2 else { throw ScriptError.missing("point \(role)") }
                court.move(r, to: p[0], p[1])
                court.commit()
            }
            if s.split == true, let t = model.time { court.split(at: t) }
            if s.scriptConfirm == true { court.confirm(by: "scripted GUI test (not a person)", method: CourtConfirmation.scriptMethod) }
        } else if s.propose != nil || s.start != nil || s.move != nil || s.scriptConfirm != nil || s.split != nil {
            throw ScriptError.missing("a recording for court calibration")
        }
        if let seconds = s.play {
            model.togglePlay()
            try await Task.sleep(for: .seconds(seconds))
            model.stop()
        }
        await model.waitUntilShown()
        try await Task.sleep(for: .milliseconds(300))
        if let name = s.snapshot {
            _ = model.snapshot(name: name)
            if model.mode == .court, let court = model.court { renderEditor(model: model, court: court, name: name) }
        }
        if let seconds = s.hold {
            // The window now shows this step: an outside capture taken during the hold is of this step.
            log("ready \(s.snapshot ?? "hold")")
            try await Task.sleep(for: .seconds(seconds))
        }
    }
}
