//
//  WorkQueueReconciler.swift
//  RallyLab
//
//  What the annotation files say about each labeling task, and the queue
//  brought into line with it. The files own the truth: Stage 1 boundaries
//  in <video>.rallyevents.json (through EventInventory, which judges every
//  recording by the withheld guard), ball tracks in sessions/<video>.json
//  (a rally counts only when a person labeled it, LineagePackage.isHumanLabeled),
//  net corners in net-labels.json with the proposals in net-ai-proposals.json
//  (a proposal is offered, never counted). The reconciler reads them, decides
//  a state per task, and records what it saw beside the state; it writes no
//  annotation and makes no proposal a label. Running it twice changes
//  nothing the second time.
//
//  Fail closed: when the withheld closure or a recording's identity can't be
//  read, nothing is reconciled; when the net inventory can't be read (a stale
//  split manifest), the net tasks are left as they are and the problem said.
//

import Foundation

enum WorkQueueReconciler {

    struct NetObservation: Equatable, Sendable {
        var skip: NetLabels.Skip?
        var status: NetLabels.LabelStatus
        var proposalPending: Bool
    }

    struct Inputs: Sendable {
        var sessions: [VideoSession]
        /// The L2 withheld closure (ReservedVideos.lineageWithheldNames), read strictly.
        var withheld: Set<String>
        /// Stage 1 state per recording (EventInventory, the same guard as opening one).
        var events: [String: EventInventory.Recording]
        /// Net state per recording (session name); nil when the net inventory could not be read.
        var net: [String: NetObservation]?
        var netProblem: String?
        var identityKeys: [String: String]
        var policy: WorkQueue.Policy
        var now: Date
        /// Each recording's admission as the source index judges it from the authoritative files (project.json, the
        /// sessions, validation.json, the exposure ledger and the footage-properties records — built fresh by
        /// `gather`, never read from a written index). Anything but `admitted` — withheld, quarantined (a
        /// derivative of protected footage at any depth, an unverifiable parent, an unusable record), unidentified,
        /// rejected — gets no actionable task of any kind (owner, 2026-11-03). Missing = not judged = admitted
        /// only when the index could not name the recording at all, which `gather` never produces.
        var admission: [String: SourceRegistry.Admission] = [:]
        var admissionReason: [String: String] = [:]
    }

    struct Verdict: Equatable, Sendable {
        var state: WorkQueue.State
        var reason: String?
        var observed: WorkQueue.Observed
    }

    struct Summary: Equatable, Sendable {
        var created = 0
        var changed = 0
        var unchanged = 0
        /// Kinds left as they were, with why.
        var skipped: [WorkQueue.Kind: String] = [:]
    }

    // MARK: - Verdicts (pure)

    static func verdicts(_ inputs: Inputs) -> [WorkQueue.Kind: [String: Verdict]] {
        let at = WorkQueue.stamp(inputs.now)
        var out: [WorkQueue.Kind: [String: Verdict]] = [.rallyBoundaries: [:], .ballTracks: [:]]
        if inputs.net != nil { out[.netCorners] = [:] }
        for s in inputs.sessions {
            let withheld = inputs.withheld.contains(s.name) || inputs.events[s.name]?.withheld == true
            let withheldReason = "withheld: a lineage or legacy holdout, final test or candidate, or an alias of one (D-017) — not labeled"
            // The gate every kind passes before any observation is read: the withheld closure (by name, file and
            // content, as EventInventory judges it), then the source index's admission. An inadmissible recording's
            // task is blocked (withheld, unidentified, rejected) or quarantined (the index's quarantine: a
            // derivative of protected footage at any depth, an unverifiable parent, an unusable record) — never
            // actionable, whatever its annotation files say.
            let gate: (state: WorkQueue.State, summary: String, reason: String)? = {
                if withheld { return (.blocked, "withheld", withheldReason) }
                if let a = inputs.admission[s.name], a != .admitted {
                    let why = inputs.admissionReason[s.name].map { ": \($0)" } ?? ""
                    return (a == .quarantined ? .quarantined : .blocked, "not admitted: \(a.rawValue)",
                            "not admitted (\(a.rawValue)\(why)) — judged by the source index from the project's records; no labeling task is actionable")
                }
                return nil
            }()

            // Stage 1 rally boundaries.
            do {
                let e = inputs.events[s.name]
                var o = WorkQueue.Observed(at: at, summary: "", declaredComplete: s.ralliesMarked ?? false, verifiedCoverage: e?.coverageFraction)
                let verdict: Verdict
                if let gate {
                    o.summary = gate.summary
                    verdict = Verdict(state: gate.state, reason: gate.reason, observed: o)
                } else if let problem = e?.recordProblem {
                    o.summary = "record not accepted"
                    verdict = Verdict(state: .failed, reason: "rallyevents.json is not this recording's: \(problem)", observed: o)
                } else if let e, e.stage1Complete {
                    o.summary = "Stage 1 complete: \(e.reviewedRallies) rallies reviewed, coverage verified"
                    verdict = Verdict(state: .complete, reason: nil, observed: o)
                } else if let e, e.eventsFile {
                    o.summary = String(format: "Stage 1 in progress: %.0f%% reviewed, %d rallies, %d unknown gap(s)", (e.coverageFraction ?? 0) * 100, e.reviewedRallies, e.unknownGaps)
                    verdict = Verdict(state: .inProgress, reason: nil, observed: o)
                } else if s.ralliesMarked ?? false {
                    // The owner's declaration that every rally is marked stands as development-label evidence (owner,
                    // 2026-11-03 §9): the task is complete by declaration, nothing is to be redone; whether the
                    // timeline's coverage was verified is a separate fact (verifiedCoverage), kept nil here.
                    o.summary = "complete by the legacy declaration (every rally marked, \(e?.legacyMarks ?? 0) marks); coverage not verified by a Stage 1 record"
                    verdict = Verdict(state: .complete, reason: nil, observed: o)
                } else {
                    o.summary = "not started" + (e?.legacyMarks.map { "; \($0) legacy mark(s), unverified" } ?? "")
                    verdict = Verdict(state: .ready, reason: nil, observed: o)
                }
                out[.rallyBoundaries]![s.name] = verdict
            }

            // Dense ball tracks.
            do {
                let tracks = s.tracks ?? []
                let human = tracks.filter(LineagePackage.isHumanLabeled).count
                let machine = tracks.filter(\.awaitsRallyCheck).count
                let open = tracks.filter(\.isOpen).count
                var o = WorkQueue.Observed(at: at, summary: "", humanLabeled: human, machineProposed: machine, open: open)
                let target = inputs.policy.ballTrackRalliesPerRecording
                let verdict: Verdict
                if let gate {
                    o.summary = gate.summary
                    verdict = Verdict(state: gate.state, reason: gate.reason, observed: o)
                } else if open > 0 {
                    o.summary = "\(open) rally(ies) started and not finished; \(human) of \(target) human-labeled"
                    verdict = Verdict(state: .inProgress, reason: nil, observed: o)
                } else if human >= target {
                    o.summary = "\(human) human-labeled rallies (target \(target))" + (machine > 0 ? "; \(machine) machine proposals unchecked" : "")
                    verdict = Verdict(state: .complete, reason: nil, observed: o)
                } else if human > 0 {
                    o.summary = "\(human) of \(target) human-labeled rallies" + (machine > 0 ? "; \(machine) machine proposals unchecked" : "")
                    verdict = Verdict(state: .inProgress, reason: nil, observed: o)
                } else if machine > 0 {
                    o.summary = "\(machine) machine-proposed rallies to check; none human-labeled"
                    verdict = Verdict(state: .needsReview, reason: nil, observed: o)
                } else {
                    o.summary = "no rallies tracked"
                    verdict = Verdict(state: .ready, reason: nil, observed: o)
                }
                out[.ballTracks]![s.name] = verdict
            }

            // Net corners. The withheld closure (by name, file and content, as EventInventory judges it) is applied
            // before any net observation: the net inventory knows only the manifest's identities, so a recording it
            // lists as labelable can still be a withheld recording's file (Codex, PR #134).
            if let net = inputs.net {
                var o = WorkQueue.Observed(at: at, summary: "")
                let verdict: Verdict
                if let gate {
                    o.summary = gate.summary
                    verdict = Verdict(state: gate.state, reason: gate.reason, observed: o)
                } else if let n = net[s.name] {
                    o.proposalPending = n.proposalPending
                    if let skip = n.skip {
                        o.summary = "skipped: \(skip.rawValue)"
                        verdict = Verdict(state: .blocked, reason: skip == .withheld ? withheldReason : "skipped: \(skip.rawValue) (NetLabels.skip)", observed: o)
                    } else if n.status.labeled {
                        o.summary = "corners confirmed"
                        verdict = Verdict(state: .complete, reason: nil, observed: o)
                    } else if n.status.boxOnly {
                        o.summary = "box on file from before corners existed; corners to mark"
                        verdict = Verdict(state: .inProgress, reason: nil, observed: o)
                    } else if n.proposalPending {
                        o.summary = "a proposal awaits confirmation" + (n.status.stale ? "; the label on file is another recording's" : "")
                        verdict = Verdict(state: .needsReview, reason: nil, observed: o)
                    } else {
                        o.summary = n.status.stale ? "the label on file is another recording's; label again" : "not labeled"
                        verdict = Verdict(state: .ready, reason: nil, observed: o)
                    }
                } else {
                    o.summary = "not on a project card"
                    verdict = Verdict(state: .blocked, reason: "no project card: the net inventory knows only card videos", observed: o)
                }
                out[.netCorners]![s.name] = verdict
            }
        }
        return out
    }

    // MARK: - Apply

    /// Every recording gets its tasks (created pending if missing), then each is reconciled to its verdict. A task
    /// whose recording is no longer in the project is blocked and says so. Contact-label tasks are not created here.
    @discardableResult
    static func apply(_ inputs: Inputs, to file: inout WorkQueue.File) -> Summary {
        var summary = Summary()
        let verdicts = verdicts(inputs)
        if inputs.net == nil { summary.skipped[.netCorners] = inputs.netProblem ?? "net inventory not read" }
        let present = Set(inputs.sessions.map(\.name))
        for kind in [WorkQueue.Kind.rallyBoundaries, .ballTracks, .netCorners] {
            guard let byVideo = verdicts[kind] else { continue }
            for s in inputs.sessions {
                guard let v = byVideo[s.name] else { continue }
                let (_, created) = file.enqueue(kind: kind, video: s.name, identityKey: inputs.identityKeys[s.name], now: inputs.now)
                if created { summary.created += 1 }
                let changed = (try? file.reconcile(WorkQueue.Task.id(kind: kind, video: s.name, scope: nil), state: v.state, reason: v.reason, observed: v.observed, now: inputs.now)) ?? false
                if changed { summary.changed += 1 } else if !created { summary.unchanged += 1 }
            }
        }
        for t in file.tasks where !present.contains(t.video) && !t.state.isFinal && t.state != .blocked {
            let o = WorkQueue.Observed(at: WorkQueue.stamp(inputs.now), summary: "recording not in the project")
            _ = try? file.reconcile(t.id, state: .blocked, reason: "the recording is no longer in the project's dataset", observed: o, now: inputs.now)
            summary.changed += 1
        }
        return summary
    }

    // MARK: - Reading a project (file work; call off the main actor)

    static func gather(root: URL, policy: WorkQueue.Policy, now: Date = Date()) throws -> Inputs {
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        let withheld = try ReservedVideos.lineageWithheldNames(in: root)
        let report = try EventInventory.build(root: root, now: now)
        let events = Dictionary(report.recordings.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var net: [String: NetObservation]?
        var netProblem: String?
        // The recordings' cut ranges (D-030) by session name: a net label inside one is not a label.
        let cuts = Dictionary(sessions.map { ($0.name, $0.cutRanges) }, uniquingKeysWith: { a, _ in a })
        do { net = try netObservations(root: root, cuts: cuts) } catch { netProblem = error.localizedDescription }
        // The index built now from the project's own records (SourceRegistry.inputs reads them strictly) — not a
        // source-index file written earlier, which could be stale.
        let index = try SourceRegistry.load(root: root, now: now)
        let keys = Dictionary(index.sources.map { ($0.video, $0.identityKey) }, uniquingKeysWith: { a, _ in a })
        let admission = Dictionary(index.sources.map { ($0.video, $0.admission) }, uniquingKeysWith: { a, _ in a })
        let reasons = Dictionary(index.sources.compactMap { s in s.admissionReason.map { (s.video, $0) } }, uniquingKeysWith: { a, _ in a })
        return Inputs(sessions: sessions, withheld: withheld, events: events, net: net, netProblem: netProblem, identityKeys: keys, policy: policy, now: now,
                      admission: admission, admissionReason: reasons)
    }

    /// The Net labels tab's inventory, by session name: the same rules it applies (NetInventory from the split
    /// manifest, NetLabels.skip, NetLabels.status, NetLabels.isOffered), no video file read. `cuts`: each
    /// recording's cut ranges by session name (D-030) — a label or a proposal on a frame inside one counts for nothing.
    static func netObservations(root: URL, cuts: [String: [CutRange]]) throws -> [String: NetObservation] {
        let inventory = try NetInventory.load(projectDir: root)
        let labels = try NetLabelStore(projectDir: root).load()
        let proposals = try NetAIProposalStore(projectDir: root).load()
        let exclusions = try NetExclusionStore(projectDir: root).load()
        // The cards strictly: a project.json that can't be read leaves the net state unknown, not empty.
        _ = try EventReview.projectSourcesStrict(in: root)
        var items: [(video: String, camera: String)] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let projectURL = root.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            let p = try decoder.decode(Project.self, from: Data(contentsOf: projectURL))
            for clip in p.clips { for v in clip.videos { items.append((clip.videoId(of: v), clip.camera)) } }
        }
        let fingerprints = Dictionary(items.map { ($0.video, inventory.fingerprint[$0.video] ?? inventory.fingerprint[DatasetStore.safeName($0.video)]) }, uniquingKeysWith: { a, _ in a })
        let excluded = NetExclusionStore.excluded(exclusions) { fingerprints[$0] ?? nil }
        var out: [String: NetObservation] = [:]
        for item in items {
            let fingerprint = fingerprints[item.video] ?? nil
            // nil: no session over the recording — unknown cuts, skipped by the rule.
            let ranges = cuts[DatasetStore.safeName(item.video)] ?? cuts[item.video]
            let skip = NetLabels.skip(video: item.video, camera: item.camera, withheld: inventory.withheld, fingerprint: fingerprint, excluded: excluded, cuts: ranges)
            let status = NetLabels.status(of: labels[item.video], fingerprint: fingerprint, cuts: ranges ?? [])
            let offered = NetLabels.isOffered(proposals[item.video], skip: skip, fingerprint: fingerprint, status: status, cuts: ranges ?? [])
            out[DatasetStore.safeName(item.video)] = NetObservation(skip: skip, status: status, proposalPending: offered)
        }
        return out
    }

    /// Load (or start) the queue, reconcile it and write it back. Returns the file and the summary.
    static func run(root: URL, project: String, now: Date = Date()) throws -> (file: WorkQueue.File, summary: Summary) {
        let store = WorkQueue.Store(root: root)
        var file = try store.load() ?? WorkQueue.File(project: project, updatedAt: WorkQueue.stamp(now))
        let inputs = try gather(root: root, policy: file.policy, now: now)
        let summary = apply(inputs, to: &file)
        try store.save(file)
        return (file, summary)
    }

    /// Lines for the terminal: counts per kind and state, then the problems.
    static func statusLines(_ file: WorkQueue.File, summary: Summary?) -> [String] {
        var out: [String] = []
        for kind in WorkQueue.Kind.allCases where !file.tasks(kind).isEmpty {
            let counts = WorkQueue.State.allCases.compactMap { s -> String? in
                let n = file.count(s, kind: kind)
                return n > 0 ? "\(s.rawValue) \(n)" : nil
            }
            out.append("\(kind.title): " + counts.joined(separator: " · "))
        }
        if let summary {
            out.append("Reconciled: \(summary.created) created · \(summary.changed) changed · \(summary.unchanged) unchanged")
            for (kind, why) in summary.skipped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { out.append("⚠️ \(kind.title) left as they were: \(why)") }
        }
        return out
    }
}
