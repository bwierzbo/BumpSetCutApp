//
//  CourtCalibrationModel.swift
//  RallyLab
//
//  The Player Lab's court-calibration state for one recording (research P2): the
//  calibration file in the experiment folder, the segment being worked on, the person's
//  draft, the automatic proposals, and the zones the players would get against the court
//  on screen. It writes only `<experiment>/court-calibrations/<recording>.json` (and, to
//  start over on a stale file, renames that file aside — nothing is deleted). It never
//  writes a net label: the person's net label arrives through the run manifest and is
//  only read.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CourtCalibrationModel {
    enum Style { case proposal, adjusted, confirmed, stale }

    let experiment: URL
    let binding: CourtCalibrationFile.Binding
    let net: PlayerFeatures.NetGeometry?
    let footage: URL
    let excluded: [PlayerFeatures.TickSpan]
    private let store: CourtCalibrationStore

    private(set) var file: CourtCalibrationFile?
    private(set) var stale: String?
    private(set) var segmentId = 0
    private(set) var draft: CourtLayout?
    private(set) var startedFrom: String?
    private(set) var baseline: CourtLayout?
    var selected: CourtLayout.Role?
    private(set) var spec: CourtSpec
    private(set) var proposing = false
    private(set) var notes: [String] = []
    private(set) var message = ""
    /// Called after anything the picture shows changed.
    var onChange: (() -> Void)?

    init(experiment: URL, recording: PlayerFeatures.Recording, footage: URL) {
        self.experiment = experiment
        binding = CourtCalibrationFile.Binding(recording)
        net = recording.net
        self.footage = footage
        excluded = recording.cutRanges + recording.timeBreakingSpans
        store = CourtCalibrationStore(experiment: experiment)
        spec = CourtSpec.standard(surface: recording.surface)
        load()
    }

    var segment: CourtSegment? { file?.segments.first { $0.id == segmentId } }

    /// The court in force for the segment, and how it was reached; nil for a stale file (bound to other footage), whose
    /// geometry is only ever `staleGeometry` and never classifies anyone (Codex on #166).
    var shown: (geometry: CourtLayout, style: Style)? {
        guard stale == nil else { return nil }
        if let draft { return (draft, baseline.map { draft.changedRoles(from: $0).isEmpty } == true && startedFrom != "manual" ? .proposal : .adjusted) }
        if let c = segment?.confirmation, segment?.status == .confirmed { return (c.geometry, .confirmed) }
        return nil
    }

    /// A stale file's court for the segment (its confirmation, else its draft), for review only: drawn apart, in grey,
    /// with no handles and no zones.
    var staleGeometry: CourtLayout? {
        guard stale != nil, let seg = segment else { return nil }
        return seg.confirmation?.geometry ?? seg.draft ?? seg.latestProposals.first?.geometry
    }

    var problems: [String] { draft?.problems ?? [] }
    var canConfirm: Bool { stale == nil && draft != nil && problems.isEmpty }

    private func load() {
        do {
            if let f = try store.load(binding.recordingId) {
                if let why = f.staleReason(for: binding) {
                    stale = why
                    file = f
                    message = "This calibration was made for another file (\(why)): it is not used. Start over to calibrate this file."
                } else {
                    file = f
                }
            } else {
                file = CourtCalibrationFile.new(for: binding)
            }
        } catch {
            stale = "unreadable: \(error.localizedDescription)"
            message = "Can't read the court calibration: \(error.localizedDescription). Nothing will be written over it."
        }
        selectSegment(file?.segments.first?.id ?? 0)
    }

    func selectSegment(_ id: Int) {
        segmentId = id
        draft = stale == nil ? segment?.draft : nil
        startedFrom = segment?.draftStartedFrom
        baseline = startedFrom.flatMap { s in segment?.latestProposals.first { $0.method.rawValue == s }?.geometry }
        if let c = segment?.confirmation { spec = c.spec } else if let s = file?.setup?.spec { spec = s }
        // An unreviewed segment opens on its best proposal (a draft, nothing saved until the person moves or confirms it).
        if draft == nil, stale == nil, segment?.status == .unreviewed, let best = bestProposal {
            draft = best.geometry
            baseline = best.geometry
            startedFrom = best.method.rawValue
            notes = best.uncertainty
        }
        selected = nil
        changed()
    }

    /// The proposal a person starts from: combined, else court lines, else net-guided — a starting point only; the
    /// others stay one click away (Reset to).
    var bestProposal: CourtProposal? {
        [CourtProposal.Method.combined, .courtLines, .netGuided].lazy.compactMap { m in self.segment?.latestProposals.first { $0.method == m } }.first
    }

    func segment(at t: Double) -> CourtSegment? { file?.segments.first { $0.contains(t) } }

    private func changed() { onChange?() }

    private func persist() {
        guard stale == nil, var f = file, let i = f.segments.firstIndex(where: { $0.id == segmentId }) else { return }
        f.segments[i].draft = draft
        f.segments[i].draftStartedFrom = draft == nil ? nil : startedFrom
        do {
            try store.save(f)
            file = f
        } catch { message = "Couldn't save: \(error.localizedDescription)" }
    }

    // MARK: - The person's answers about the court

    /// The answers so far, the recording card's surface filled in until the person picks one.
    var setup: CourtSetup {
        file?.setup ?? CourtSetup(surface: binding.surface.flatMap { CourtSetup.Surface(rawValue: $0.lowercased()) }, format: nil, markings: nil, answeredAt: nil)
    }

    /// Proposing waits for the markings answer: it decides whether the line search runs.
    var needsAnswers: Bool { file?.setup?.markings == nil }

    func answer(surface: CourtSetup.Surface?? = nil, format: CourtSetup.Format?? = nil, markings: CourtSetup.Markings?? = nil) {
        guard stale == nil, var f = file else { return }
        var s = setup
        if let surface { s.surface = surface }
        if let format { s.format = format }
        if let markings { s.markings = markings }
        s.answeredAt = Date()
        f.setup = s
        file = f
        if segment?.confirmation == nil { spec = s.spec ?? CourtSpec.standard(surface: binding.surface) }
        persist()
        changed()
    }

    // MARK: - Proposals

    func propose() async {
        guard stale == nil, let seg = segment, !proposing else { return }
        proposing = true
        message = "Looking for the court…"
        defer { proposing = false }
        do {
            let outcome = try await CourtProposer.propose(footage: footage, net: net, binding: binding, from: seg.validFromSec, to: seg.validToSec,
                                                          excluded: excluded, spec: spec, markings: file?.setup?.markings, experiment: experiment,
                                                          ref: "--player-lab court proposal \(binding.recordingId) segment \(seg.id)",
                                                          codeSha: RallyClassifierExporter.buildRevision())
            guard var f = file, let i = f.segments.firstIndex(where: { $0.id == seg.id }) else { return }
            f.segments[i].proposals += outcome.proposals
            file = f
            notes = outcome.notes
            persist()
            if draft == nil, segment?.status != .confirmed, let best = bestProposal { use(best.method) }
            message = outcome.proposals.isEmpty ? "No automatic proposal: place the court by hand." :
                "Proposed: " + outcome.proposals.map { "\($0.method.label) \(String(format: "%.2f", $0.confidence))" }.joined(separator: " · ")
        } catch { message = "Proposal failed: \(error.localizedDescription)" }
        changed()
    }

    /// Starts the draft from the latest proposal of `method` (Reset to proposal).
    func use(_ method: CourtProposal.Method) {
        guard stale == nil, let p = segment?.latestProposals.first(where: { $0.method == method }) else { return }
        draft = p.geometry
        baseline = p.geometry
        startedFrom = method.rawValue
        notes = p.uncertainty
        persist()
        changed()
    }

    /// A court placed from nothing: a trapezoid under the net (or mid-frame without one) to drag into place.
    func placeManually() {
        guard stale == nil else { return }
        var g: CourtLayout
        if let n = net, n.corners.count == 4 {
            let l = n.corners[3][0], r = n.corners[2][0], y = min(n.corners[2][1], n.corners[3][1]) - 0.05
            let wd = r - l
            g = CourtLayout(nearLeft: CourtPoint(x: l - 0.3 * wd, y: max(0.02, y - 0.35), status: .seen),
                              nearRight: CourtPoint(x: r + 0.3 * wd, y: max(0.02, y - 0.35), status: .seen),
                              netRight: CourtPoint(x: r - 0.03 * wd, y: y, status: .seen), netLeft: CourtPoint(x: l + 0.03 * wd, y: y, status: .seen),
                              farLeft: CourtPoint(x: l + 0.15 * wd, y: y + 0.08, status: .seen), farRight: CourtPoint(x: r - 0.15 * wd, y: y + 0.08, status: .seen))
        } else {
            g = CourtLayout(nearLeft: CourtPoint(x: 0.1, y: 0.1, status: .seen), nearRight: CourtPoint(x: 0.9, y: 0.1, status: .seen),
                              netRight: CourtPoint(x: 0.75, y: 0.4, status: .seen), netLeft: CourtPoint(x: 0.25, y: 0.4, status: .seen),
                              farLeft: CourtPoint(x: 0.35, y: 0.55, status: .seen), farRight: CourtPoint(x: 0.65, y: 0.55, status: .seen))
        }
        draft = g
        baseline = nil
        startedFrom = "manual"
        notes = ["placed by hand: drag every point onto the court"]
        persist()
        changed()
    }

    /// Edit the segment's confirmed court again (the confirmation stays in force until a new Confirm replaces it).
    func editConfirmed() {
        guard stale == nil, let c = segment?.confirmation else { return }
        draft = c.geometry
        baseline = c.geometry
        startedFrom = "confirmation"
        persist()
        changed()
    }

    func discardDraft() {
        draft = nil
        baseline = nil
        startedFrom = nil
        persist()
        changed()
    }

    // MARK: - Editing (live, then `commit` on release)

    func move(_ role: CourtLayout.Role, to x: Double, _ y: Double) {
        guard let d = draft else { return }
        draft = d.moving(role, to: x, y)
        changed()
    }

    /// Moves several points by the same amount (an edge dragged by its middle).
    func shift(_ roles: [CourtLayout.Role], from start: CourtLayout, dx: Double, dy: Double) {
        var g = draft ?? start
        for r in roles { g = g.moving(r, to: start[r].x + dx, start[r].y + dy, status: start[r].status) }
        draft = g
        changed()
    }

    func setStatus(_ role: CourtLayout.Role, _ status: CourtPoint.Status) {
        guard var d = draft else { return }
        d[role].status = status
        draft = d
        commit()
    }

    /// Puts an unknown point where the person wants it (then it is `seen`).
    func place(_ role: CourtLayout.Role, at x: Double, _ y: Double) {
        guard let d = draft else { return }
        draft = d.moving(role, to: x, y, status: .seen)
        commit()
    }

    func commit() { persist(); changed() }

    // MARK: - Decisions

    func confirm(by person: String = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName(), method: String = CourtConfirmation.personMethod) {
        guard canConfirm, var f = file, let d = draft else { message = problems.isEmpty ? "Nothing to confirm." : problems.joined(separator: "; "); return }
        do {
            try f.confirm(segment: segmentId, geometry: d, startedFrom: startedFrom ?? "manual", baseline: baseline, by: person, net: net, spec: spec,
                          format: file?.setup?.format?.rawValue, now: Date(), method: method)
            try store.save(f)
            file = f
            draft = nil
            baseline = nil
            startedFrom = nil
            message = "Confirmed segment \(segmentId)\(method == CourtConfirmation.personMethod ? "" : " (scripted: not used as evidence)")."
        } catch { message = error.localizedDescription }
        changed()
    }

    func reject() { decide(.rejected, note: "proposals rejected in Player Lab") }

    func markUnknownView() { decide(.unknownView, note: "not one stable court view (camera moved, cut, zoom or replay)") }

    private func decide(_ status: CourtSegment.Status, note: String) {
        guard stale == nil, var f = file else { return }
        f.set(segment: segmentId, status: status, note: note)
        file = f
        draft = nil
        baseline = nil
        startedFrom = nil
        persist()
        message = "Segment \(segmentId): \(status.rawValue)."
        changed()
    }

    /// The camera changed at `t`: a new segment from there, starting from this one's court as a draft.
    func split(at t: Double) {
        guard stale == nil else { return }
        persist()
        guard var f = file else { return }
        guard f.split(at: t) else { message = "Can't split there (too close to a segment edge)."; return }
        do { try store.save(f) } catch { message = "Couldn't save: \(error.localizedDescription)"; return }
        file = f
        if let s = f.segments.first(where: { $0.contains(t) }) { selectSegment(s.id) }
        message = String(format: "New segment from %.1f s: check the court and confirm it.", t)
    }

    /// Puts a stale file aside (renamed, never deleted) and starts a new calibration for this file.
    func startOver() {
        let fm = FileManager.default
        let url = store.url(binding.recordingId)
        let aside = url.deletingLastPathComponent().appendingPathComponent("\(binding.recordingId).stale-\(Int(Date().timeIntervalSince1970)).json")
        do {
            if fm.fileExists(atPath: url.path) { try fm.moveItem(at: url, to: aside) }
            stale = nil
            file = CourtCalibrationFile.new(for: binding)
            try store.save(file!)
            message = "Started a new calibration; the old one is kept as \(aside.lastPathComponent)."
        } catch { message = "Couldn't start over: \(error.localizedDescription)" }
        selectSegment(file?.segments.first?.id ?? 0)
    }

    // MARK: - Zones

    /// The zones the players get against what is on screen for the current segment and the confirmed courts of the
    /// others, frame by frame (nil where no court covers the frame).
    func zones(for frames: [PlayerFeatures.Frame]) -> [[PersonZone?]?] {
        // A file bound to other footage classifies nobody.
        guard stale == nil else { return frames.map { _ in nil } }
        let current = shown?.geometry, segId = segmentId, spec = self.spec, file = self.file
        var pass = CourtMembershipPass { t in
            guard let seg = file?.segments.first(where: { $0.contains(t) }) else { return nil }
            if seg.id == segId, let current, current.isUsable { return (CourtZoneClassifier(geometry: current, spec: spec, settings: .init()), seg.id) }
            guard let c = file?.confirmed(at: t) else { return nil }
            return (CourtZoneClassifier(geometry: c.geometry, spec: c.spec, settings: .init()), seg.id)
        }
        var lastSeg: Int?
        return frames.map { f in
            if f.seg != lastSeg { pass.resetTracks(); lastSeg = f.seg }
            return pass.zones(f.persons, at: f.t).map { $0.map(Optional.some) }
        }
    }
}
