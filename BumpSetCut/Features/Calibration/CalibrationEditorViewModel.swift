//
//  CalibrationEditorViewModel.swift
//  BumpSetCut
//
//  The Court & Net editor's state: the video's frame at a time, the camera view that time
//  falls in, the court and net as the person is placing them, and the calibration file
//  they are saved to. Everything a person does goes through the file's own rules
//  (CourtNetCalibrationFile) and is written by the store; nothing here needs a model or a
//  proposal.
//

import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CalibrationEditorViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// The page failed to open because the calibration on file can't be read, which `startFresh` gets past.
    private(set) var canStartFresh = false
    private(set) var file: CourtNetCalibrationFile?
    private(set) var video: CalibrationVideo?
    /// A calibration on file for another video or frame: shown as the reason, offered as a starting point, never used.
    private(set) var staleFile: CourtNetCalibrationFile?
    private(set) var staleReason: String?
    private(set) var frame: CGImage?
    private(set) var time: Double = 0
    /// The shapes of the camera view at `time`, as the person is placing them.
    private(set) var shapes = CalibrationWorkingShapes()
    private(set) var hasUnsavedChanges = false
    var target: CalibrationTarget = .court { didSet { if selected?.target != target { selected = nil } } }
    var showCourt = true
    var showNet = true
    var selected: CalibrationHandle?
    /// One line said back to the person: what was saved, or why something wasn't.
    var notice: String?

    private let videoId: UUID
    private let url: URL
    private let store: CourtNetCalibrationStore
    private let reviewer: String
    private let generator: AVAssetImageGenerator
    private var frameTask: Task<Void, Never>?

    /// What a part of a segment's working shape started from.
    private struct Origin<G: CalibrationGeometry> {
        var startedFrom: String
        var baseline: G?
    }
    private struct Working {
        var shapes: CalibrationWorkingShapes
        var court: Origin<CourtLayout>
        var net: Origin<NetQuad>
        var courtEdited = false
        var netEdited = false
        /// The court on screen is the outline the page offered, which the person has not moved yet: it is
        /// nobody's court, and nothing of it is saved or confirmed.
        var courtIsOfferedOutline = false
    }
    /// Working shapes by segment id, for the views the person has touched or looked at.
    private var working: [Int: Working] = [:]
    private var segmentId: Int?

    static let tool = "bumpsetcut_ios \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"

    init(videoId: UUID, url: URL, store: CourtNetCalibrationStore, reviewer: String, target: CalibrationTarget = .court) {
        self.target = target
        self.videoId = videoId
        self.url = url
        self.store = store
        self.reviewer = reviewer
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
    }

    // MARK: Opening and closing

    func load() async {
        do {
            let video = try await CalibrationVideo.load(recordingId: videoId.uuidString, url: url)
            self.video = video
            switch store.lookup(for: video.binding) {
            case .none:
                file = .new(for: video.binding)
            case .usable(let onFile):
                file = onFile
            case .stale(let old, let reason):
                file = .new(for: video.binding)
                (staleFile, staleReason) = (old, reason)
            case .unreadable(let why):
                canStartFresh = true
                phase = .failed(why)
                return
            }
            let start = file?.segments.first?.frameTimeSec ?? min(1, video.binding.durationSec / 2)
            phase = .ready
            seek(to: start)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The calibration on file can't be read: it is set aside (kept, under another name) and the page opens
    /// with nothing marked.
    func startFresh() async {
        do {
            try store.setAsideUnreadable(videoId.uuidString)
            canStartFresh = false
            phase = .loading
            await load()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func close() {
        frameTask?.cancel()
        generator.cancelAllCGImageGeneration()
    }

    // MARK: The frame

    var durationSec: Double { video?.binding.durationSec ?? 0 }
    var frameAspect: CGFloat { video.map { CGFloat($0.binding.frameWidth) / CGFloat(max(1, $0.binding.frameHeight)) } ?? 16 / 9 }

    func seek(to t: Double) {
        guard let video else { return }
        time = min(max(0, t), max(0, video.binding.durationSec - video.frameDurationSec))
        syncSegment()
        frameTask?.cancel()
        let at = CMTime(seconds: time, preferredTimescale: 600)
        frameTask = Task { [generator] in
            guard let image = try? await generator.image(at: at).image, !Task.isCancelled else { return }
            frame = image
        }
    }

    func step(frames: Int) { seek(to: time + Double(frames) * (video?.frameDurationSec ?? 0)) }
    func step(seconds: Double) { seek(to: time + seconds) }

    // MARK: The camera view at the current time

    var segment: CalibrationSegment? { file?.segments.first { $0.contains(time) } ?? file?.segments.last }
    var segmentNumber: Int { (file?.segments.firstIndex { $0.id == segment?.id } ?? 0) + 1 }
    var segmentCount: Int { file?.segments.count ?? 0 }
    var isStableView: Bool { segment?.view == .stable }

    var status: CalibrationStatus {
        guard let file, let video else { return .notCalibrated }
        return staleFile != nil && !hasUnsavedChanges && file == .new(for: video.binding) ? .needsReview : file.status(for: video.binding)
    }

    /// What stands for the part being edited in this camera view.
    enum PartState { case nothing, placing, confirmed, editedSinceConfirmed }

    func partState(_ target: CalibrationTarget) -> PartState {
        guard let segment, let w = working[segment.id] else { return .nothing }
        if target == .court, w.courtIsOfferedOutline { return .nothing }
        let (confirmed, edited, any): (Bool, Bool, Bool)
        switch target {
        case .court: (confirmed, edited, any) = (segment.court.confirmation != nil, w.courtEdited || segment.court.draft != nil, w.shapes.hasCourtPoints)
        case .net: (confirmed, edited, any) = (segment.net.confirmation != nil, w.netEdited || segment.net.draft != nil, w.shapes.hasNetCorners)
        }
        if confirmed { return edited ? .editedSinceConfirmed : .confirmed }
        return any ? .placing : .nothing
    }

    /// Loads the working shapes of the segment `time` is in, keeping the one being left.
    private func syncSegment() {
        guard let segment, segment.id != segmentId else { return }
        segmentId = segment.id
        if working[segment.id] == nil {
            let (court, net) = (segment.court.startingPoint, segment.net.startingPoint)
            working[segment.id] = Working(shapes: CalibrationWorkingShapes(court: court.geometry, net: net.geometry),
                                          court: Origin(startedFrom: court.startedFrom, baseline: court.baseline),
                                          net: Origin(startedFrom: net.startedFrom, baseline: net.baseline))
        }
        shapes = working[segment.id]!.shapes
        selected = nil
    }

    // MARK: Placing and moving

    /// The shapes change under the person's hand.
    private func edit(_ target: CalibrationTarget, _ change: (inout CalibrationWorkingShapes) -> Void) {
        guard let id = segmentId, isStableView else { return }
        change(&shapes)
        guard shapes != working[id]?.shapes else { return }
        working[id]?.shapes = shapes
        switch target {
        case .court: working[id]?.courtEdited = true; working[id]?.courtIsOfferedOutline = false
        case .net: working[id]?.netEdited = true
        }
        hasUnsavedChanges = true
        notice = nil
    }

    // MARK: The court's outline

    /// The court page of a camera view with no court at all has nothing to drag: it wants the outline.
    var wantsCourtOutline: Bool {
        phase == .ready && target == .court && isStableView && !shapes.hasCourtPoints && shapes.skipped.isEmpty
    }

    /// The court on screen is the offered outline, not moved yet.
    var courtIsOfferedOutline: Bool { segmentId.flatMap { working[$0]?.courtIsOfferedOutline } ?? false }

    /// Puts the outline on the court page for the person to drag onto the court. It is not theirs until they
    /// move it: until then it is not saved, not a draft, and can't be confirmed.
    func offerCourtOutline() {
        guard wantsCourtOutline, let id = segmentId else { return }
        shapes.court = CalibrationWorkingShapes.courtOutline.court
        working[id]?.shapes = shapes
        working[id]?.courtIsOfferedOutline = true
    }

    // MARK: The net, corner by corner

    /// A net corner not placed yet, under the finger: it follows until the finger lifts.
    func place(_ handle: CalibrationHandle, x: Double, y: Double) {
        edit(handle.target) { $0.set(handle, x: x, y: y) }
    }

    /// Back: the net corner placed last is taken away, to be tapped again.
    func removeLastNetCorner() {
        guard let last = shapes.net.lastIndex(where: { $0 != nil }) else { return }
        edit(.net) { $0.removeNetCorner(last) }
        selected = nil
    }

    /// A tap: on a point selects it; elsewhere it places the selected point if that is not placed yet, else the
    /// next point still to place.
    func tap(x: Double, y: Double, on hit: CalibrationHandle?) {
        if let hit { selected = hit; return }
        let unplacedSelection = selected.flatMap { shapes.position($0) == nil ? $0 : nil }
        guard let handle = unplacedSelection ?? shapes.nextToPlace(target) else { selected = nil; return }
        edit(target) { $0.set(handle, x: x, y: y) }
        selected = handle
    }

    /// A drag in progress: the points `action` moves, by a frame-fraction delta from where `start` had them.
    func drag(_ action: CalibrationDragAction, from start: CalibrationWorkingShapes, dx: Double, dy: Double) {
        if case .handle(let h) = action { selected = h }
        edit(target) {
            $0 = start
            if target == .court, start.isWholeCourt {
                $0.moveOutline(action, from: start, dx: dx, dy: dy)
            } else {
                $0.translate(CalibrationWorkingShapes.handles(moved: action, target: target), from: start, dx: dx, dy: dy)
            }
        }
    }

    /// The camera view's marks and whose they are, as a touch finds them: taken when a drag begins, put back if
    /// the drag turns out to be the first finger of a pinch.
    struct Snapshot {
        fileprivate let segmentId: Int?
        let shapes: CalibrationWorkingShapes
        fileprivate let courtEdited: Bool
        fileprivate let netEdited: Bool
        fileprivate let courtIsOfferedOutline: Bool
        fileprivate let hasUnsavedChanges: Bool
    }

    func snapshot() -> Snapshot {
        let w = segmentId.flatMap { working[$0] }
        return Snapshot(segmentId: segmentId, shapes: shapes, courtEdited: w?.courtEdited ?? false, netEdited: w?.netEdited ?? false,
                        courtIsOfferedOutline: w?.courtIsOfferedOutline ?? false, hasUnsavedChanges: hasUnsavedChanges)
    }

    /// Undoes what a drag did since `before` was taken — the marks, and with them whether they count as edited:
    /// an offered outline a cancelled drag moved is the offered outline again, not somebody's court.
    func restore(_ before: Snapshot) {
        guard let id = segmentId, id == before.segmentId else { return }
        shapes = before.shapes
        working[id]?.shapes = before.shapes
        working[id]?.courtEdited = before.courtEdited
        working[id]?.netEdited = before.netEdited
        working[id]?.courtIsOfferedOutline = before.courtIsOfferedOutline
        hasUnsavedChanges = before.hasUnsavedChanges
    }

    func setSelectedEstimated(_ estimated: Bool) {
        guard case .court(let role) = selected else { return }
        edit(.court) { $0.setEstimated(estimated, role) }
    }

    // MARK: Saving

    /// Writes one segment's edited shapes into `next` as drafts. An edited net with fewer than four corners can't
    /// be a draft: it stays in the editor and is named in the return.
    private func stash(_ id: Int, into next: inout CourtNetCalibrationFile) throws -> Bool {
        guard let w = working[id] else { return true }
        if w.courtEdited {
            if w.shapes.hasCourtPoints {
                try next.saveDraft(w.shapes.court, of: \.court, segment: id, startedFrom: w.court.startedFrom, baseline: w.court.baseline)
            } else {
                try next.discardDraft(of: \.court, segment: id)
            }
        }
        guard w.netEdited else { return true }
        if let quad = w.shapes.netQuad {
            try next.saveDraft(quad, of: \.net, segment: id, startedFrom: w.net.startedFrom, baseline: w.net.baseline)
        } else if !w.shapes.hasNetCorners {
            try next.discardDraft(of: \.net, segment: id)
        } else {
            return false
        }
        return true
    }

    /// Stashes every edited segment, applies `change`, saves, and only then takes the result as the file.
    @discardableResult
    private func commit(_ said: String, _ change: (inout CourtNetCalibrationFile) throws -> Void = { _ in }) -> Bool {
        guard var next = file else { return false }
        do {
            var partialNet = false
            for id in working.keys.sorted() where next.segments.contains(where: { $0.id == id }) {
                if try !stash(id, into: &next) { partialNet = true }
            }
            try change(&next)
            next.segments = next.segments.map { g in
                var g = g
                if g.id == segmentId { g.frameTimeSec = time }
                return g
            }
            try store.save(next)
            file = next
            (staleFile, staleReason) = (nil, nil)
            for id in working.keys {
                working[id]?.courtEdited = false
                if working[id]?.shapes.netQuad != nil || working[id]?.shapes.hasNetCorners == false { working[id]?.netEdited = false }
            }
            hasUnsavedChanges = working.values.contains { $0.netEdited }
            notice = partialNet ? String(localized: "Saved. The net needs all four corners before it can be saved.") : said
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func saveDraft() { commit(String(localized: "Draft saved.")) }

    /// The person's Confirm for the part being edited, in the camera view at the current time. False when it
    /// could not be confirmed (the reason is the notice).
    @discardableResult
    func confirm() -> Bool {
        guard let id = segmentId else { return false }
        let target = target
        if target == .net, shapes.netQuad == nil {
            notice = String(localized: "Place all four corners of the net first.")
            return false
        }
        if target == .court, !shapes.hasCourtPoints {
            notice = String(localized: "Place the court's corners first.")
            return false
        }
        if target == .court, courtIsOfferedOutline {
            notice = String(localized: "Drag the outline onto the court first.")
            return false
        }
        // A court with only one half placed is judged on that half. An outline has both: one that crosses
        // itself or folds over is not a court, though one of its halves alone would pass.
        if target == .court, shapes.isWholeCourt, shapes.court.map(near: true) == nil || shapes.court.map(near: false) == nil {
            let why = String(localized: "The outline crosses itself or folds over. Each half of the court has to be a four-sided shape.")
            commit("")
            notice = why
            return false
        }
        let done = commit(target == .court ? String(localized: "Court confirmed.") : String(localized: "Net confirmed.")) { next in
            let segment = next.segments.first { $0.id == id }
            // Confirming what is already confirmed and untouched changes nothing.
            switch target {
            case .court where segment?.court.draft == nil && segment?.court.confirmation != nil: return
            case .net where segment?.net.draft == nil && segment?.net.confirmation != nil: return
            case .court: try next.confirm(\.court, segment: id, by: self.reviewer, tool: Self.tool, now: Date())
            case .net: try next.confirm(\.net, segment: id, by: self.reviewer, tool: Self.tool, now: Date())
            }
        }
        guard done else {
            // What was placed is kept as a draft; the reason it couldn't be confirmed stays on screen.
            let why = notice
            if commit("") { notice = why }
            return false
        }
        guard let segment = file?.segments.first(where: { $0.id == id }) else { return true }
        // The confirmation is now what the next edit starts from.
        switch target {
        case .court: working[id]?.court = Origin(startedFrom: CourtNetCalibrationV1.confirmation, baseline: segment.court.confirmation?.geometry)
        case .net: working[id]?.net = Origin(startedFrom: CourtNetCalibrationV1.confirmation, baseline: segment.net.confirmation?.geometry)
        }
        return true
    }

    /// Start over on the part being edited: every point goes and so does its draft. A confirmation stays in force
    /// until another is confirmed.
    func startOver() {
        guard let id = segmentId else { return }
        let target = target
        var cleared = shapes
        switch target {
        case .court: cleared = CalibrationWorkingShapes(court: nil, net: shapes.netQuad); cleared.net = shapes.net
        case .net: cleared.net = [nil, nil, nil, nil]
        }
        shapes = cleared
        working[id]?.shapes = cleared
        switch target {
        case .court: working[id]?.court = Origin(startedFrom: CourtNetCalibrationV1.manual, baseline: nil); working[id]?.courtEdited = true
        case .net: working[id]?.net = Origin(startedFrom: CourtNetCalibrationV1.manual, baseline: nil); working[id]?.netEdited = true
        }
        selected = nil
        commit(target == .court ? String(localized: "Cleared. Drag the outline onto the court again.")
                                : String(localized: "Cleared. Tap the net's corners again."))
    }

    /// The camera moved at the current time: the view splits in two here. With `reuse` the new view starts from
    /// this one's court and net as drafts.
    func cameraChangedHere(reuse: Bool) {
        let t = time
        var didSplit = false
        let saved = commit(String(localized: "New camera view from here.")) { next in didSplit = next.split(at: t, reuse: reuse) }
        guard saved else { return }
        guard didSplit else {
            notice = String(localized: "Too close to the start or end of this camera view to split here.")
            return
        }
        segmentId = nil
        syncSegment()
    }

    func setView(_ view: CalibrationSegment.View) {
        guard let id = segmentId else { return }
        if view == .stable { restageWithdrawnMarks(id) }
        commit(view == .stable ? String(localized: "Marked as a stable court view.") : String(localized: "This part of the video won't be used.")) { next in
            try next.setView(view, segment: id, note: nil, at: Date())
        }
    }

    /// A view marked not stable gave up its confirmations (they are in history) but its marks are still on
    /// screen. Called stable again, those marks are the view's drafts — started from the confirmation that was
    /// withdrawn — so they can be confirmed as they stand, without moving a point first.
    private func restageWithdrawnMarks(_ id: Int) {
        guard let segment = file?.segments.first(where: { $0.id == id }), let shapes = working[id]?.shapes else { return }
        // The offered outline is nobody's marks: there is nothing of it to put back.
        if segment.court.confirmation == nil, segment.court.draft == nil, shapes.hasCourtPoints, working[id]?.courtIsOfferedOutline != true {
            working[id]?.court = Origin(startedFrom: CourtNetCalibrationV1.confirmation, baseline: segment.court.history.last?.geometry)
            working[id]?.courtEdited = true
        }
        if segment.net.confirmation == nil, segment.net.draft == nil, shapes.netQuad != nil {
            working[id]?.net = Origin(startedFrom: CourtNetCalibrationV1.confirmation, baseline: segment.net.history.last?.geometry)
            working[id]?.netEdited = true
        }
    }

    var setup: CourtSetup { file?.setup ?? CourtSetup() }

    func setSetup(surface: CourtSetup.Surface?, format: CourtSetup.Format?) {
        commit(String(localized: "Court type saved.")) { $0.setup = CourtSetup(surface: surface, format: format, answeredAt: Date()) }
    }

    /// Takes the court and net of a calibration made for another file as this view's starting drafts.
    func startFromStaleFile() {
        guard let id = segmentId, let old = staleFile?.segments.first else { return }
        let court = old.court.confirmation?.geometry ?? old.court.draft
        let net = old.net.confirmation?.geometry ?? old.net.draft
        let from = "earlier calibration"
        shapes = CalibrationWorkingShapes(court: court, net: net)
        working[id] = Working(shapes: shapes, court: Origin(startedFrom: from, baseline: court), net: Origin(startedFrom: from, baseline: net),
                              courtEdited: court != nil, netEdited: net != nil)
        hasUnsavedChanges = court != nil || net != nil
        notice = String(localized: "These are the earlier marks. Check them against this video, then confirm.")
    }
}
