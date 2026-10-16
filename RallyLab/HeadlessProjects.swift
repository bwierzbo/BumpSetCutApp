//
//  HeadlessProjects.swift
//  RallyLab
//
//  The Projects tab from the command line, so a clip can be pulled without
//  opening the app (and Claude can do it from a pasted link):
//
//    RallyLab --project v3 --get grs_onl_sun_land_onl_01 "https://youtube.com/…" \
//             --license "permission: Jake R., DM 2026-09-26" [--start 2:00] [--length 5:00] [--frames 4]
//             [--allow-duplicate]   (add a stretch of a video already used; --frames is per rally)
//    RallyLab --project v3 --sync-phone [--labels-only]    (sync with the Labeler iPhone app — sign in once in the
//                                                           app, or --phone-sign-in <email> with RALLYLAB_PASSWORD set;
//                                                           --labels-only: rally times, tracks, reviews, plan — no videos;
//                                                           --remake-copies [names…]: those videos' older phone copies
//                                                           made again, no names every video's)
//    RallyLab --project v3 --train-round                   (the training plan's next round, as Plan's button: export,
//                                                           train its runs on the desktop, bring each back; then the
//                                                           phone gets the plan)
//    RallyLab --project v3 --repull-all                    (sample every video's cut again, e.g. after
//                                                           changing frames per rally — nothing re-downloaded;
//                                                           videos with tracked rallies or reviewed frames are kept)
//    RallyLab --project v3 --pull-tester-footage [--posted <username>…]   (what testers' phones sent for training —
//             every rally of each processed video — as extra train cards, surface guessed; labelers' own
//             footage left out; --posted also pulls rallies those people posted, a card per person per day.
//             Signed in as for --sync-phone. Then --pretrack labels them)
//    RallyLab --project v3 --move ind_ele_bright_land_self_01_v2 bch_ele_sun_land_self_01
//    RallyLab --project v3 --status
//    RallyLab --project v3 --location /Volumes/Footage   (new project, somewhere else)
//
//    RallyLab --project v3 --package                       (training package zip)
//    RallyLab --project v3 --package-multiframe [--unreviewed] [--val-only] [--long-side 512]   (multi-frame package zip;
//             --unreviewed: every labeled frame, not only reviewed ones — a quick look, not a round;
//             --val-only: the val clips alone, as a folder (no zip) — the test set for scoring models here;
//             --long-side: frames this big (default 1024; 512 is enough for 512 training, a quarter the disk))
//    RallyLab --project v3 --fit-boxes [--apply]          (tighten unreviewed balls' boxes; --apply pulls the
//             phone's changes, saves, and sends them back)
//    RallyLab --project v3 --pretrack [clip…] [--per-video 3] [--redo] [--val] [--heat M]   (self-training: the newest multi-frame
//             model (or M) tracks
//             rallies in train videos on its own; sure frames become machine labels, the rest go to review;
//             --redo: track the pre-tracked ones again, e.g. after a better model; --val: val videos instead, a head
//             start for the test set — every frame goes to review and only checked frames score)
//    RallyLab --project v3 --tune-pipeline [--replay-only] [--rounds 2]   (search the pipeline's settings for the cuts
//             closest to the marked rallies of pipeline_tuning/validation.json's videos; reports, applies nothing)
//    RallyLab --project v3 --serve-report [--verbose]    (the serve found in each marked rally of the validation
//             videos, how far from the mark, and what starting clips at the serve would score)
//    RallyLab --project v3 --pretrack-check [--heat M]     (how right "sure" frames are, against val rallies people tracked)
//    RallyLab --project v3 --add-heat <bring_back folder>  (convert + add a multi-frame model)
//    RallyLab --project v3 --evaluate-heat [model name]    (score vs YOLO on the newest package)
//    RallyLab --project v3 --render-heat <clip> <seconds>  (side-by-side video of a tracked rally)
//    RallyLab --project v3 --pipeline-compare <multi-frame model> <clip>…   (pipeline YOLO vs YOLO+multi-frame)
//    RallyLab --project v3 --compare-color <clip>…          (pipeline on raw frames vs standard-colour frames)
//    RallyLab --project v3 --score-rallies [clip…] [--rotate] [--heat <multi-frame model> [--heat-only]]
//             (rally cutting vs your rally times; default: every fully marked video, YOLO only)
//             [--heat-hop n]   (multi-frame model runs every n frames; default 5)
//    RallyLab --project v3 --render-pipeline <clip> <start s> <length s> [<start s> <length s>…] [--heat <model> [--heat-only]] [--rotate]
//             (those stretches with the pipeline's overlay → ~/Movies/RallyLab/Renders)
//    RallyLab --project v3 --diagnose-rallies <clip>… [--rotate] [--ball-model <name>]   (what the pipeline saw in each marked rally)
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

    /// True when a run was started: the app then mustn't sync on its own.
    @discardableResult
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let name = value(after: "--project", in: args) else { return false }

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

            if ok, args.contains("--repull-all") { ok = await repullAll(projects) }
            if ok, let email = value(after: "--phone-sign-in", in: args) {
                // The password comes from RALLYLAB_PASSWORD, not the command line.
                let sync = LabelingSync(projects: projects)
                await sync.signIn(email: email, password: ProcessInfo.processInfo.environment["RALLYLAB_PASSWORD"] ?? "")
                log(sync.status)
                ok = sync.signedIn
            }
            if ok, args.contains("--sync-phone") {
                let sync = LabelingSync(projects: projects)
                // --remake-copies [names…]: those videos' older phone copies
                // made again (no names: every video's).
                let remake = args.firstIndex(of: "--remake-copies").map { i in Set(args[(i + 1)...].prefix { !$0.hasPrefix("--") }) }
                ok = await sync.sync(videos: !args.contains("--labels-only"),
                                     remaking: { name in remake.map { $0.isEmpty || $0.contains(name) } ?? false })
                log((ok ? "✅ " : "❌ ") + sync.status)
            }
            if ok, args.contains("--pull-tester-footage") {
                let posted = args.firstIndex(of: "--posted").map { i in args[(i + 1)...].prefix { !$0.hasPrefix("--") } } ?? []
                let report = await TesterFootage.pull(projects: projects, posted: Array(posted), log: log)
                log("\(report.failed == 0 ? "✅" : "⚠️") \(report.added) tester clips added, \(report.skipped) skipped "
                    + "(already in the project or unreadable), \(report.failed) failed")
                ok = report.failed == 0
            }

            if args.contains("--status") || args.contains("--get") || args.contains("--move") || args.contains("--repull-all")
                || args.contains("--pull-tester-footage") {
                printStatus(projects)
            }

            let library = ModelLibrary(sampler: projects.sampler)
            // Tighten unreviewed balls' boxes (BoxFitter); --apply saves them.
            if ok, args.contains("--fit-boxes") {
                let store = ProjectReviewStore(sampler: projects.sampler, tracker: TrackLabelModel(sampler: projects.sampler))
                var last = 0
                let fitted = await store.fittedBoxes { done, total in
                    let pct = done * 100 / max(total, 1)
                    if pct >= last + 10 { last = pct; log("fitting… \(pct)%") }
                }
                let n = fitted.values.flatMap(\.values).reduce(0) { $0 + $1.count }
                log("\(n) of \(store.reviewItems([.crop]).count) unreviewed balls fitted\(args.contains("--apply") ? " — saved" : " (dry run; --apply saves)").")
                if args.contains("--apply") {
                    // Take what changed on the phone meanwhile first (frames
                    // reviewed there are skipped), then send the result back.
                    let sync = LabelingSync(projects: projects)
                    await sync.sync(videos: false)
                    store.apply(fitted)
                    for s in projects.sampler.sessions {
                        projects.sampler.markFitted((s.tracks ?? []).filter(\.done).map(\.id), session: s.name)
                    }
                    ok = await sync.sync(videos: false)
                    log((ok ? "✅ " : "❌ ") + sync.status)
                }
            }
            // Self-training: the model tracks rallies in train videos on its own.
            if ok, args.contains("--pretrack") {
                let perVideo = value(after: "--per-video", in: args).flatMap(Int.init) ?? PreTracker.perVideo
                let only = Array(args.drop { $0 != "--pretrack" }.dropFirst().prefix { !$0.hasPrefix("--") })
                let r = await PreTracker.run(sampler: projects.sampler, only: only, perVideo: perVideo, redo: args.contains("--redo"),
                                             val: args.contains("--val"),
                                             model: value(after: "--heat", in: args).map { heatModel($0, in: library) }, log: log)
                log("✅ \(r.rallies) rallies pre-tracked" + (r.redone > 0 ? ", \(r.redone) tracked again" : "")
                    + ", \(r.dropped) dropped (ball found on under \(Int(PreTracker.minFound * 100))% of frames)")
                log("   all pre-tracked rallies: \(r.frames) frames · \(r.sure) sure (machine labels) · \(r.toReview) to review")
            }
            if ok, args.contains("--tune-pipeline") {
                ok = await PipelineTuner.run(sampler: projects.sampler, replayOnly: args.contains("--replay-only"),
                                             rounds: value(after: "--rounds", in: args).flatMap(Int.init) ?? 2, log: log)
            }
            if ok, args.contains("--serve-report") {
                ok = await ServeReport.run(sampler: projects.sampler, verbose: args.contains("--verbose"), log: log)
            }
            if ok, args.contains("--pretrack-check") {
                let checks = await PreTracker.check(sampler: projects.sampler,
                                                    model: value(after: "--heat", in: args).map { heatModel($0, in: library) }, log: log)
                if let c = checks.first { log("The path found a ball on \(c.found) checked frames; people saw \(c.people) balls.") }
                log("reach  confidence  off arc   sure  right   precision  share of people's balls   (no ball where it was sure)")
                for c in checks {
                    log(String(format: "  %d      %.1f      %.3f  %6d %6d     %5.1f%%        %5.1f%%                 %d",
                               c.reach, c.minConfidence, c.maxOffArc, c.sure, c.right, c.precision * 100, c.coverage * 100, c.wrongNoBall))
                }
                log("In use: reach \(MachineLabels.reach), confidence \(MachineLabels.minConfidence), off arc \(MachineLabels.maxOffArc).")
            }
            if ok, args.contains("--train-round") {
                let plan = TrainingPlanModel(library: library)
                guard let round = plan.currentRound else { log("Every round is trained."); exit(0) }
                let progress = PlanProgress(videos: projects.sampler.sessions.map(PlanVideo.init(session:)), round: round)
                log("Round \(round.number): \(progress.frames) frames (\(progress.surfaces.map { "\($0.key) \($0.value.frames)" }.sorted().joined(separator: ", ")))")
                plan.exportAndTrain(round, progress: progress)
                var said = ""
                while plan.isRunning || library.isBusy {
                    let now = [plan.status, library.heatmaps.desktopLine].joined(separator: " · ")
                    if now != said { log(now); said = now }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                log(plan.status)
                ok = plan.status.contains("is trained")
                if ok {
                    let sync = LabelingSync(projects: projects)
                    await sync.sync(videos: false)
                }
            }
            if ok, args.contains("--package") { ok = await package(library) }
            if ok, args.contains("--package-multiframe") { 
                let side = value(after: "--long-side", in: args).flatMap(Double.init).map { CGFloat($0) } ?? MultiFramePackage.longSide
                ok = await packageMultiFrame(library, unreviewed: args.contains("--unreviewed"), valOnly: args.contains("--val-only"), longSide: side)
            }
            if ok, let model = value(after: "--add-model", in: args) {
                await library.addModel(URL(fileURLWithPath: (model as NSString).expandingTildeInPath))
                log(library.status)
                ok = !library.status.lowercased().contains("fail") && !library.status.contains("Add a")
            }
            if ok, args.contains("--evaluate") { ok = await evaluate(library, args: args) }
            if ok, let folder = value(after: "--add-heat", in: args) {
                library.heatmaps.reload()
                await library.heatmaps.addModel(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath))
                log(library.heatmaps.status)
                ok = library.heatmaps.status.hasPrefix("Saved")
            }
            if ok, let i = args.firstIndex(of: "--diagnose-rallies") {
                var config = ProcessorConfig()
                config.applyVideoRotation = args.contains("--rotate")
                if let name = value(after: "--ball-model", in: args), let model = BallModel(rawValue: name) { config.ballModel = model }
                log("ball model \(config.ballModel.rawValue) · rotation \(config.applyVideoRotation ? "applied" : "not applied")")
                for clip in args[(i + 1)...].prefix(while: { !$0.hasPrefix("--") }) {
                    guard let session = projects.sampler.sessions.first(where: { $0.name == clip }) else { log("❌ No clip \(clip)"); continue }
                    log("\(clip):")
                    guard let v = await RallyCutScore.process(session, config: config.withCamera(of: session)) else { log("   no rally times or couldn't process"); continue }
                    var t = RallyCutScore.Tally()
                    t.add(clips: v.clips, truth: v.truth)
                    log("   " + t.line)
                    RallyCutScore.diagnose(v, log: log)
                }
            }
            if ok, let i = args.firstIndex(of: "--score-rallies") {
                let named = args[(i + 1)...].prefix { !$0.hasPrefix("--") }
                let sessions = projects.sampler.sessions.filter {
                    named.isEmpty ? ($0.ralliesMarked ?? false) : named.contains($0.name)
                }
                var config = ProcessorConfig()
                config.applyVideoRotation = args.contains("--rotate")
                log("rotation \(config.applyVideoRotation ? "applied" : "not applied")")
                if let key = value(after: "--heat", in: args) {
                    config.heatmapModel = heatModel(key, in: library)
                    config.heatmapOnly = args.contains("--heat-only")
                    if let hop = value(after: "--heat-hop", in: args).flatMap(Int.init) { config.heatmapHop = hop }
                    log("ball finder: \(config.heatmapOnly ? "multi-frame only" : "YOLO + multi-frame") (\(key), window every \(config.heatmapHop) frames)")
                } else {
                    // ProcessorConfig's default is the app's (multi-frame only); say YOLO outright.
                    config.heatmapModel = nil
                    config.heatmapOnly = false
                    log("ball finder: YOLO only")
                }
                var videos: [RallyCutScore.Video] = []
                for session in sessions {
                    log("\(session.name) (\(session.split))…")
                    if let v = await RallyCutScore.process(session, config: config.withCamera(of: session)) { videos.append(v) } else { log("   no rally times or couldn't process") }
                }
                if videos.isEmpty { log("❌ No fully marked videos (Track tab → Rally times → Whole video marked).") }
                else { RallyCutScore.report(videos, log: log) }
            }
            if ok, let i = args.firstIndex(of: "--render-pipeline") {
                let numbers = args.dropFirst(i + 2).prefix { Double($0) != nil }.compactMap(Double.init)
                let stretches = stride(from: 0, to: numbers.count - 1, by: 2).map { (start: numbers[$0], length: numbers[$0 + 1]) }
                guard args.indices.contains(i + 1), !stretches.isEmpty,
                      let session = projects.sampler.sessions.first(where: { $0.name == args[i + 1] }) else {
                    log("usage: --render-pipeline <clip> <start s> <length s> [<start s> <length s>…] [--heat <model> [--heat-only]] [--rotate]")
                    exit(2)
                }
                var config = ProcessorConfig()
                config.applyVideoRotation = args.contains("--rotate")
                var finder = "YOLO"
                if let key = value(after: "--heat", in: args) {
                    config.heatmapModel = heatModel(key, in: library)
                    config.heatmapOnly = args.contains("--heat-only")
                    if let hop = value(after: "--heat-hop", in: args).flatMap(Int.init) { config.heatmapHop = hop }
                    finder = config.heatmapOnly ? "multi-frame only" : "YOLO + multi-frame"
                }
                log("\(session.name): pipeline (\(finder))…")
                if let v = await RallyCutScore.process(session, config: config.withCamera(of: session)) {
                    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/RallyLab/Renders", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for (start, length) in stretches {
                        let name = "\(session.name)-\(Int(start))s-\(finder.replacingOccurrences(of: " ", with: "-")).mp4"
                        switch await PipelineVideo.render(evidence: v.evidence, clips: v.clips, truth: v.truth, serves: v.serves,
                                                          video: URL(fileURLWithPath: session.sourcePath), from: start, length: length,
                                                          title: "\(session.name) · \(finder)", to: dir.appendingPathComponent(name)) {
                        case .success(let url): log("✅ \(url.path)")
                        case .failure(let f): log("❌ \(f.message)"); ok = false
                        }
                    }
                } else {
                    log("❌ No rally times or couldn't process.")
                    ok = false
                }
            }
            if ok, let i = args.firstIndex(of: "--compare-color") {
                for clip in args[(i + 1)...] where !clip.hasPrefix("--") {
                    guard let session = projects.sampler.sessions.first(where: { $0.name == clip }) else { log("❌ No clip \(clip)"); continue }
                    var sdr = ProcessorConfig()
                    sdr.standardColorFrames = true
                    log("\(clip)…")
                    guard let (raw, std) = await PipelineCompare.run(session: session, a: ProcessorConfig(), b: sdr) else { log("   couldn't process"); continue }
                    log("   raw frames     : " + PipelineCompare.describe(raw))
                    log("   standard colour: " + PipelineCompare.describe(std))
                }
            }
            if ok, let i = args.firstIndex(of: "--pipeline-compare"), args.indices.contains(i + 2) {
                let model = heatModel(args[i + 1], in: library)
                for clip in args[(i + 2)...] where !clip.hasPrefix("--") {
                    guard let session = projects.sampler.sessions.first(where: { $0.name == clip }) else { log("❌ No clip \(clip)"); continue }
                    log("\(clip) (\(session.split), \((session.tracks ?? []).filter(\.done).count) done tracked rallies)…")
                    guard let (off, on) = await PipelineCompare.run(session: session, heatModel: model) else { log("   couldn't process"); continue }
                    log("   YOLO only        : " + PipelineCompare.describe(off))
                    log("   YOLO + multi-frame: " + PipelineCompare.describe(on))
                }
            }
            if ok, args.contains("--evaluate-heat") { ok = await evaluateHeat(library.heatmaps, args: args) }
            if ok, let i = args.firstIndex(of: "--render-heat"), args.indices.contains(i + 2) {
                let lab = library.heatmaps
                lab.reload()
                if let item = lab.trackedRallies.first(where: { $0.session == args[i + 1] && abs($0.rally.start - (Double(args[i + 2]) ?? -1)) < 1 }) {
                    lab.renderVideo(session: item.session, rally: item.rally)
                    while lab.isBusy { try? await Task.sleep(nanoseconds: 300_000_000) }
                    log(lab.status)
                    ok = lab.lastVideo != nil
                } else {
                    log("❌ No tracked rally at \(args[i + 2]) s in \(args[i + 1]).")
                    ok = false
                }
            }
            exit(ok ? 0 : 1)
        }
        return true
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
    private static func repullAll(_ projects: ProjectsModel) async -> Bool {
        let videos = (projects.project?.clips ?? []).flatMap { clip in
            clip.videos.map { (clip.id, clip.videoId(of: $0)) }
        }
        for (clipId, videoId) in videos {
            if let session = projects.session(named: videoId), !(session.tracks ?? []).isEmpty || session.reviewedCount > 0 {
                log("▸ \(videoId): kept — it has tracked rallies or reviewed frames")
                continue
            }
            projects.repull(videoId, in: clipId)
            log("▸ \(projects.status)")
            while projects.sampler.isIngesting || !projects.sampler.queue.allSatisfy(\.isFinished) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let frames = projects.session(named: videoId)?.frames.count ?? 0
            log(frames > 0 ? "✅ \(videoId): \(frames) frames" : "❌ \(videoId): \(projects.sampler.status)")
        }
        return true
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
    private static func packageMultiFrame(_ library: ModelLibrary, unreviewed: Bool, valOnly: Bool, longSide: CGFloat) async -> Bool {
        library.exportMultiFramePackage(unreviewed: unreviewed, valOnly: valOnly, longSide: longSide)
        while library.isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
        log(library.status)
        return library.lastMultiFramePackage != nil
    }

    @MainActor
    private static func evaluateHeat(_ lab: HeatmapLab, args: [String]) async -> Bool {
        lab.reload()
        if let name = value(after: "--evaluate-heat", in: args), !name.hasPrefix("--") {
            guard let m = lab.models.first(where: { $0.name == name }) else {
                log("❌ No multi-frame model \(name). Models: \(lab.models.map(\.name).joined(separator: ", "))")
                return false
            }
            lab.selected = m
        }
        guard let model = lab.selected, let package = lab.package else { log("❌ Need a multi-frame model and package."); return false }
        log("Scoring \(model.name) [\(model.size), trained on \(model.package)] on \(package.lastPathComponent)…")
        lab.evaluate()
        while lab.isBusy { try? await Task.sleep(nanoseconds: 300_000_000) }
        log(lab.status)
        guard let r = lab.result else { return false }
        for d in HeatEvaluation.Detector.allCases {
            let line = ["tracked", "sampled", "all"].map { k -> String in
                guard let s = r.scores[d]?[k] else { return "\(k) —" }
                return String(format: "%@ %.1f%%/%.1f%% F1 %.3f", k, s.recall * 100, s.precision * 100, s.f1)
            }.joined(separator: "   ")
            log("  \(d.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(line)")
        }
        log("  tracked balls in play: both \(r.both) · only YOLO \(r.onlyYOLO) · only multi-frame \(r.onlyHeatmap) · neither \(r.neither)")
        log("  multi-frame by environment (tracked): " + r.byEnvironment.sorted { $0.key < $1.key }
            .map { String(format: "%@ %.1f%%/%.1f%%", $0.key, $0.value.recall * 100, $0.value.precision * 100) }.joined(separator: " · "))
        return true
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

    /// A multi-frame model by name or path; exits when there's none.
    @MainActor
    private static func heatModel(_ key: String, in library: ModelLibrary) -> URL {
        library.heatmaps.reload()
        guard let model = library.heatmaps.models.first(where: { $0.name == key || $0.url.path == key })?.url else {
            log("❌ No multi-frame model \(key). Models: \(library.heatmaps.models.map(\.name).joined(separator: ", "))")
            exit(1)
        }
        return model
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

extension ProcessorConfig {
    /// This config with the camera position the session's clip ID names.
    func withCamera(of session: VideoSession) -> ProcessorConfig {
        var config = self
        config.applyCamera(CameraSetup(clipID: session.name))
        return config
    }
}
