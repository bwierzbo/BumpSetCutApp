//
//  LabelerModel.swift
//  RallyLab (iPhone)
//
//  The app's state: who's signed in; the project's videos, rally times,
//  tracked rallies and training plan (last loaded copy kept on the phone,
//  so it opens offline); edits queued in an outbox until they're saved;
//  clips kept on the phone; and the next tasks, from the training plan.
//

import AuthenticationServices
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LabelerModel: ReviewStore {

    enum Phase { case starting, signedOut, notLabeler, ready }

    private(set) var phase = Phase.starting
    private(set) var snapshot = LabelSnapshot()
    private(set) var outbox = Outbox()
    /// Rows the server has accepted whose settlement the snapshot on the phone may not hold yet: they are written
    /// with the outbox until the snapshot write that carries them has completed, so a launch after a kill in between
    /// finds them still owed and sends them again (each send is a repeat the server takes as is) instead of loading
    /// the older marks with nothing left to restore the accepted ones — and sending that older list next.
    @ObservationIgnored private var settling = Outbox()
    private(set) var isLoading = false
    private(set) var isOffline = false
    /// Why the last load or send failed, while it keeps failing (the app
    /// carries on with what's on the phone, which can fall far behind).
    private(set) var syncProblem: String?
    private(set) var today = DayStats.today
    var error: String?
    /// The signed-in account, shown when it isn't a labeler yet (so its owner can say which one to add).
    private(set) var account: String?

    private let client = LabelingClient.shared
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// The flush in progress, so a pull, a reload and the debounced save never send the same pending record
    /// twice (the second save would conflict with this device's own first one).
    @ObservationIgnored private var flushInFlight: Task<Void, Never>?
    @ObservationIgnored private var flushAgain = false

    init() {
        snapshot = LocalStore.load(LabelSnapshot.self, "snapshot.json") ?? LabelSnapshot()
        outbox = LocalStore.load(Outbox.self, "outbox.json") ?? Outbox()
    }

    // MARK: - Session

    func start() async {
        guard await client.hasSession else { phase = .signedOut; return }
        if !snapshot.videos.isEmpty { phase = .ready }
        await reload()
    }

    func signIn(email: String, password: String) async {
        do {
            try await client.signIn(email: email, password: password)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sign in with Apple. `nonce` is the raw value whose hash went into the request.
    func signInWithApple(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let idToken = String(data: data, encoding: .utf8) else {
                self.error = "Apple didn't return a sign-in. Try again."
                return
            }
            try await client.signInWithApple(idToken: idToken, nonce: nonce)
            await reload()
        } catch let e as ASAuthorizationError where e.code == .canceled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sign in with Google in a browser sheet.
    func signInWithGoogle(_ web: WebAuthenticationSession) async {
        let (url, verifier) = client.webSignIn("google")
        do {
            let callback = try await web.authenticate(using: url, callbackURLScheme: LabelingClient.callbackScheme,
                                                      preferredBrowserSession: .ephemeral)
            try await client.finishWebSignIn(callback: callback, verifier: verifier)
            await reload()
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Forgot password: email a code.
    func sendPasswordReset(email: String) async -> Bool {
        do {
            try await client.sendPasswordReset(email: email)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Forgot password: the emailed code and a new password; signs in.
    func resetPassword(email: String, code: String, newPassword: String) async -> Bool {
        do {
            try await client.resetPassword(email: email, code: code, newPassword: newPassword)
            await reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        await client.signOut()
        snapshot = LabelSnapshot()
        LocalStore.saveInBackground(snapshot, "snapshot.json") {}
        phase = .signedOut
    }

    /// Send what's waiting, then load everything again.
    func reload() async {
        let started = Date()
        isLoading = true
        defer { isLoading = false }
        do {
            await flush()
            async let v = client.videos()
            async let t = client.rallyTimes()
            async let k = client.tracks()
            async let s = client.projectStates()
            async let e = client.rallyEvents()
            async let rc = client.recordingTypeClaims()
            var loaded = try await LabelSnapshot(videos: v, times: t, tracks: k, states: s, events: e, claims: rc)
            // A record is taken only for the recording and original footage it describes (identity checked first).
            eventIdentityProblems = [:]
            loaded.events = admit(loaded.events, videos: loaded.videos, keeping: snapshot.events)
            // The withheld list of every project seen: a project without one makes its recordings unreviewable here.
            for project in Set(loaded.videos.compactMap(\.project)) {
                let (listed, names) = try await client.withheld(project: project)
                if listed { loaded.withheld[project] = names.sorted() }
            }
            account = await client.email
            guard try await client.isLabeler() else { phase = .notLabeler; return }
            // The server's protection of withheld recordings exempts a lead: what a lead's phone may do with one is
            // this app's own rule (`access`).
            loaded.lead = try await client.isLead()
            snapshot = loaded
            quarantineUnreviewable()
            lastPull = started
            lastEventsPull = started
            lastClaimsPull = started
            lastVideosPull = started
            syncProblem = nil
            LocalStore.pruneClips(keeping: loaded.videos)
            LocalStore.saveInBackground(snapshot, "snapshot.json") {}
            isOffline = false
            phase = .ready
        } catch LabelingClient.Failure.notSignedIn {
            phase = .signedOut
        } catch {
            // No connection: keep working from what's on the phone.
            isOffline = true
            syncProblem = Self.describe("Couldn't load from the server", error)
            if phase == .starting { phase = snapshot.videos.isEmpty ? .signedOut : .ready }
        }
    }

    /// A failure as text for the screen; a decoding failure names where.
    private static func describe(_ what: String, _ error: Error) -> String {
        let why = error is DecodingError ? String(describing: error) : error.localizedDescription
        return "\(what): \(why.prefix(300))"
    }

    /// When changes were last pulled (see `pullChanges`).
    @ObservationIgnored private var lastPull: Date?
    /// Clocks differ a little between the Mac and the phone: look back this
    /// far past the last pull (taking a row again is harmless).
    private static let pullOverlap: TimeInterval = 120

    /// Send what's waiting and take what the Mac changed since the last look:
    /// rally times and tracked rallies only (new videos come with `reload`).
    func pullChanges() async {
        guard phase == .ready, let last = lastPull else { return await reload() }
        let started = Date()
        // The withheld lists first, every time: a recording the Mac withholds while the phone is open stops being
        // reviewable at the next pull — its cached record is dropped from what the phone shows and its pending edits
        // stay on the phone, unsent (quarantined), instead of waiting for a full reload. A list that cannot be read
        // now keeps the one known before.
        for project in Set(snapshot.videos.compactMap(\.project)) {
            if let (listed, names) = try? await client.withheld(project: project) {
                snapshot.withheld[project] = listed ? names.sorted() : nil
            }
        }
        quarantineUnreviewable()
        await flush()
        do {
            async let t = client.rallyTimes(since: last.addingTimeInterval(-Self.pullOverlap))
            async let k = client.tracks(since: last.addingTimeInterval(-Self.pullOverlap))
            let (times, tracks) = try await (t, k)
            for r in times {
                snapshot.times.removeAll { $0.videoId == r.videoId }
                snapshot.times.append(r)
            }
            // Stage 1 records have their own cursor: a failed fetch leaves it, so nothing is skipped past the overlap.
            do {
                let fetched = try await client.rallyEvents(since: (lastEventsPull ?? last).addingTimeInterval(-Self.pullOverlap))
                let events = admit(fetched, videos: snapshot.videos, keeping: [])
                for row in events where outbox.events[row.videoId] == nil {
                    snapshot.events.removeAll { $0.videoId == row.videoId }
                    snapshot.events.append(row)
                }
                if !events.isEmpty { LocalStore.saveInBackground(snapshot, "snapshot.json") {} }
                lastEventsPull = started
            } catch {
                syncProblem = Self.describe("Couldn't fetch the boundary records", error)
            }
            for r in tracks {
                snapshot.tracks.removeAll { $0.id == r.id }
                snapshot.tracks.append(r)
            }
            // Footage-type claims, with their own cursor like the Stage 1 records: the Mac's settlements arrive here.
            do {
                let claims = try await client.recordingTypeClaims(since: (lastClaimsPull ?? last).addingTimeInterval(-Self.pullOverlap))
                take(claims)
                lastClaimsPull = started
            } catch {
                syncProblem = Self.describe("Couldn't fetch the footage-type claims", error)
            }
            // The rows the Mac changed since (the published type among them): a settlement is shown beside the type
            // the Mac has now, never beside an older one, and the type itself is never inferred from a claim.
            do {
                let rows = try await client.videos(since: (lastVideosPull ?? last).addingTimeInterval(-Self.pullOverlap))
                for row in rows {
                    snapshot.videos.removeAll { $0.id == row.id }
                    snapshot.videos.append(row)
                }
                if !rows.isEmpty { LocalStore.saveInBackground(snapshot, "snapshot.json") {} }
                lastVideosPull = started
            } catch {
                syncProblem = Self.describe("Couldn't fetch the recordings", error)
            }
            if !times.isEmpty || !tracks.isEmpty { LocalStore.saveInBackground(snapshot, "snapshot.json") {} }
            lastPull = started
            isOffline = false
        } catch {
            isOffline = true
        }
    }

    // MARK: - Reading (local edits over what was loaded)

    /// The server's rows with this phone's unsent backlog changes on them: a skip or a put-back still in the
    /// outbox shows and rules the queue however the rows were loaded or pulled since. A recording closed to this
    /// account (`access`: withheld, or not known not to be, for an ordinary labeler) is not among them — the
    /// server stops serving its row at the next reload; the rows kept on the phone must not offer it until then.
    var videos: [LabelVideo] { snapshot.videos.filter { $0.clipPath != nil && access(for: $0).offersMarking }.map(shown) }

    func video(_ id: UUID) -> LabelVideo? { snapshot.videos.first { $0.id == id }.map(shown) }

    /// A row as the app shows it: this phone's unsent backlog change on it, and — for a recording no model may run
    /// over (`access`) — without the rallies the pipeline found in it. They are a model's output: the snapshot and
    /// the server keep them as they were; they are not offered to confirm, to track or on the timeline.
    private func shown(_ row: LabelVideo) -> LabelVideo {
        var r = withPendingBacklog(row)
        if access(for: row) != .open { r.ralliesFound = [] }
        return r
    }

    private func withPendingBacklog(_ row: LabelVideo) -> LabelVideo {
        guard let change = outbox.backlog[row.id] else { return row }
        var r = row
        r.backlogReason = change.reason
        r.backlogAt = change.at
        r.backlogBy = nil
        return r
    }

    func rallyTimes(for video: LabelVideo) -> LabelRallyTimes {
        outbox.times[video.id] ?? snapshot.times.first { $0.videoId == video.id }
            ?? LabelRallyTimes(videoId: video.id, rallies: [], complete: false)
    }

    // MARK: - Stage 1 rally-boundary records (shared with the Mac; migration 048)

    /// Conflicts the server reported for records edited here: the server's row, kept beside the local edit until
    /// the person decides (never merged over, never dropped).
    private(set) var eventConflicts: [UUID: LabelRallyEvents] = [:]
    /// Records refused because they do not describe this recording's original footage (from the server on a pull,
    /// or by the server on a save): the reason, shown to the person. Both records are kept; nothing is adopted or
    /// re-sent until a reload clears it.
    private(set) var eventIdentityProblems: [UUID: String] = [:]
    /// When the Stage 1 records were last fetched in full or incrementally (advances only on success).
    @ObservationIgnored private var lastEventsPull: Date?
    @ObservationIgnored private var lastClaimsPull: Date?
    @ObservationIgnored private var lastVideosPull: Date?

    // MARK: - Footage-type claims (D-033)

    /// The person's choice of the recording's type: a claim, saved on this phone first (durable) and sent when
    /// online. Nothing on the phone is the type itself. A newer choice replaces one still on this phone — refused
    /// or not yet sent — under a fresh id (the server does the same with one it holds). Returns why it cannot be
    /// made, if it cannot.
    func claimRecordingType(_ kind: RecordingTypeClaims.Kind, for video: LabelVideo) -> String? {
        guard let fingerprint = video.sourceFingerprint, !fingerprint.isEmpty else {
            return "The Mac hasn't published this recording's identity yet — sync from the Mac first."
        }
        guard isReviewable(video) else { return "This recording isn't open to labeling on this phone." }
        let pending = RecordingTypeClaims.Pending(id: UUID(), videoId: video.id, sourceFingerprint: fingerprint, kind: kind, madeAt: Date())
        outbox.claims = RecordingTypeClaims.replacing(outbox.claims, with: pending)
        queueFlush()
        return nil
    }

    /// The newest choice for the recording and where it stands.
    func footageType(for video: LabelVideo) -> RecordingTypeClaims.Display {
        RecordingTypeClaims.display(video: video.id, pending: outbox.claims, rows: snapshot.claims)
    }

    /// Server rows into the snapshot: by id; a row for a choice still in the outbox means the server has it
    /// (a reply lost on the way back), so the pending copy goes.
    private func take(_ claims: [RecordingTypeClaim]) {
        guard !claims.isEmpty else { return }
        for row in claims {
            snapshot.claims.removeAll { $0.id == row.id }
            snapshot.claims.append(row)
            if let pending = outbox.claims[row.id] { outbox.claims[row.id] = nil; settling.claims[row.id] = pending }
        }
        persist()
    }

    /// The outbox on the phone, at once, with the rows still settling behind it.
    private func saveOutbox() { LocalStore.save(outbox.carrying(settling), "outbox.json") }

    /// The outbox at once, then the snapshot off the main thread; the rows settling now leave the outbox file only
    /// once that snapshot — the first that holds their settlement — is on the phone.
    private func persist() {
        saveOutbox()
        let carried = settling
        LocalStore.saveInBackground(snapshot, "snapshot.json") { [weak self] in
            guard let self else { return }
            settling.drop(carried)
            saveOutbox()
        }
    }

    /// The record as last loaded from the server for this recording, or the pending local edit.
    func rallyEvents(for video: LabelVideo) -> (record: EventReview.File, revision: Int)? {
        guard isReviewable(video) else { return nil }
        if let pending = outbox.events[video.id] { return (pending.record, pending.expected) }
        guard let row = snapshot.events.first(where: { $0.videoId == video.id }) else { return nil }
        return (row.record, row.revision)
    }

    /// Records of recordings that are not reviewable here (withheld, or their project's list unknown) leave what the
    /// phone shows; their pending edits stay in the outbox but are never sent while that holds.
    private func quarantineUnreviewable() {
        let blocked = Set(snapshot.videos.filter { !isReviewable($0) }.map(\.id))
        let before = snapshot.events.count
        snapshot.events.removeAll { blocked.contains($0.videoId) }
        for id in blocked where outbox.events[id] != nil { eventIdentityProblems[id] = "withheld: this recording is not reviewable now; the edit is kept on this phone and not sent" }
        if snapshot.events.count != before { LocalStore.saveInBackground(snapshot, "snapshot.json") {} }
    }

    /// Whether the recording may be reviewed here: the project has a published withheld list and the recording is not on it.
    func isReviewable(_ video: LabelVideo) -> Bool {
        guard let project = video.project, let session = video.sessionName, let list = snapshot.withheld[project] else { return false }
        return !list.contains(session)
    }

    /// What may be done with the recording on this phone (LabelAccess; D-036 §5C/§5E), by the project's withheld
    /// list as last loaded. The phone has no validation.json: the list is what the server serves, published by the
    /// Mac's sync — a project without one, or one not loaded yet, is not known. Withheld or not known: no task
    /// that runs a model or shows what one found, for any account; marking by hand stays for a lead, nothing is
    /// offered to an ordinary labeler. A phone upload RallyLab has not pulled in is in no project and on no list
    /// (the server's rule, migration 049).
    func access(for video: LabelVideo) -> LabelAccess {
        guard let project = video.project else { return .open }
        let listed = video.sessionName.flatMap { session in snapshot.withheld[project].map { $0.contains(session) } }
        return LabelAccess(withheld: listed, byHand: snapshot.lead)
    }

    /// The recording's access as the server has it now, for an operation about to run a model over it
    /// (TrackSession: opening a rally, finding the ball on more frames): the project's withheld list is fetched
    /// again first, so a recording the Mac withheld since the last pull is known as withheld, and a list that
    /// cannot be fetched now is not known — no model runs then (fail closed).
    func modelAccess(for video: LabelVideo) async -> LabelAccess {
        guard let project = video.project else { return .open }
        do {
            let (listed, names) = try await client.withheld(project: project)
            let list = listed ? names.sorted() : nil
            if snapshot.withheld[project] != list {
                snapshot.withheld[project] = list
                quarantineUnreviewable()
                LocalStore.saveInBackground(snapshot, "snapshot.json") {}
            }
        } catch {
            return LabelAccess(withheld: nil, byHand: snapshot.lead)
        }
        return access(for: video)
    }

    /// The server rows that describe their recording's published original; every other row is left out (the
    /// snapshot keeps the previous one, `keeping`) and its reason recorded.
    private func admit(_ rows: [LabelRallyEvents], videos: [LabelVideo], keeping: [LabelRallyEvents]) -> [LabelRallyEvents] {
        var out: [LabelRallyEvents] = []
        for row in rows {
            guard let video = videos.first(where: { $0.id == row.videoId }), let project = video.project, let session = video.sessionName else {
                eventIdentityProblems[row.videoId] = "a boundary record for a recording this phone does not know"
                continue
            }
            if let why = RallyEventsSync.identityMismatch(of: row, project: project, session: session, originalFingerprint: video.sourceFingerprint) {
                eventIdentityProblems[row.videoId] = "server record not taken: " + why
                if let previous = keeping.first(where: { $0.videoId == row.videoId }) { out.append(previous) }
                continue
            }
            out.append(row)
        }
        return out
    }

    /// Why a Stage 1 record may not be saved for this recording here, or nil: not reviewable (withheld, or no
    /// published list), or not this recording's original footage.
    func saveRefusal(_ record: EventReview.File, for video: LabelVideo) -> String? {
        guard isReviewable(video), let session = video.sessionName else { return "this recording is not reviewable here (withheld, or the Mac has not published its list)" }
        return RallyEventsSync.identityMismatch(of: record, session: session, originalFingerprint: video.sourceFingerprint)
    }

    /// Queues a Stage 1 record for saving at the revision it was loaded from. Refused for a recording that is not
    /// reviewable here, or for a record that does not describe its original footage — nothing is even queued then.
    @discardableResult
    func saveRallyEvents(_ record: EventReview.File, for video: LabelVideo, expected: Int) -> Bool {
        guard saveRefusal(record, for: video) == nil else { return false }
        outbox.events[video.id] = PendingRallyEvents(videoId: video.id, expected: expected, record: record)
        queueFlush()
        return true
    }

    /// The person took the server's version: drop the local edit and the conflict.
    func resolveEventConflict(_ video: LabelVideo, takeServer: Bool) {
        guard let server = eventConflicts[video.id] else { return }
        if takeServer {
            outbox.events[video.id] = nil
            snapshot.events.removeAll { $0.videoId == video.id }
            snapshot.events.append(server)
        } else if var pending = outbox.events[video.id] {
            // Keep mine, on top of the server's revision: the next flush saves it as the newer version.
            pending.expected = server.revision
            pending.record.revision = server.revision
            outbox.events[video.id] = pending
        }
        eventConflicts[video.id] = nil
        persist()
        queueFlush()
    }

    /// The video's tracked rallies (not deleted), in time order.
    func tracks(for video: LabelVideo) -> [LabelTrack] { tracks(videoId: video.id) }

    private func tracks(videoId: UUID) -> [LabelTrack] {
        var byId = Dictionary(snapshot.tracks.filter { $0.videoId == videoId }.map { ($0.id, $0) }) { a, _ in a }
        for t in outbox.tracks.values where t.videoId == videoId { byId[t.id] = t }
        return byId.values.filter { !$0.deleted }.sorted { $0.start < $1.start }
    }

    /// The rallies the pipeline found in the recording, as it may be shown them now. A screen holds the row it
    /// was opened with; the list may have withheld the recording since — so what a model found is read through
    /// here, by the access known at the moment of use (`shown`), never off a row a view kept.
    func found(in video: LabelVideo) -> [[Double]] { self.video(video.id)?.ralliesFound ?? [] }

    /// The tracked rallies a marking pass may snap presses to: all of them for a recording no model is kept
    /// from; otherwise only the ones a person placed every frame of — a model's path over a withheld recording
    /// is not used.
    func snapTracks(for video: LabelVideo) -> [TrackedRally] {
        let all = tracks(for: video).map(\.rally)
        return access(for: video) == .open ? all : all.filter { !$0.carriesModelOutput }
    }

    /// Found rallies not marked, not said to be no rally, and touching no cut range (not footage; the found rally
    /// itself stays on the video for undo): what review asks about.
    func openFound(in video: LabelVideo) -> [[Double]] {
        let times = rallyTimes(for: video)
        let marked = times.rallies, cuts = times.cutRanges
        let rejected = LocalStore.rejected(video)
        return found(in: video).filter { f in
            !rejected.contains(LocalStore.key(f)) && !cuts.overlaps(f[0], f[1]) && !marked.contains { min($0.end, f[1]) - max($0.start, f[0]) > 0.3 }
        }
    }

    /// Rallies to track, in time order: your marked ones, then the found
    /// ones you haven't marked or turned down — none already tracked, none
    /// touching a cut range (the Mac's rule, PreTracker.openSpans; D-030).
    func untrackedRallies(in video: LabelVideo) -> [LabelRally] {
        let times = rallyTimes(for: video)
        let found = openFound(in: video).map { LabelRally(start: $0[0], end: $0[1]) }
        let tracked = tracks(for: video)
        return (times.rallies + found).outsideCuts(times.cutRanges)
            .filter { r in !tracked.contains { min($0.end, r.end) - max($0.start, r.start) > 0.5 * (r.end - r.start) } }
            .sorted { $0.start < $1.start }
    }

    /// A track of `rally` you started and didn't finish.
    func unfinishedTrack(of rally: LabelRally, in video: LabelVideo) -> LabelTrack? {
        tracks(for: video).first { $0.isOpen && $0.rally.bounds == rally }
    }

    /// The rally to track next in a video: one you started and left first,
    /// so it's picked up where you stopped — tracking begun, else trimmed —
    /// then the untracked ones.
    func nextRally(in video: LabelVideo) -> LabelRally? {
        let untracked = untrackedRallies(in: video)
        return tracks(for: video).first(where: \.isOpen)?.rally.bounds
            ?? untracked.first { LocalStore.trim(of: $0, in: video) != nil }
            ?? untracked.first
    }

    // MARK: - Annotation review

    /// Every rally, keyed for review by its video's id.
    /// Val videos first: their rallies are the test set.
    var reviewRallies: [(video: String, rally: TrackedRally)] {
        videos.sorted { ($0.split == "val" ? 0 : 1, $0.name) < ($1.split == "val" ? 0 : 1, $1.name) }
            .flatMap { v in tracks(for: v).map { (v.id.uuidString, $0.rally) } }
    }

    func reviewItems(_ kinds: Set<AnnotationReview.Kind>) -> [AnnotationReview.Item] {
        AnnotationReview.items(reviewRallies, kinds: kinds)
    }

    var reviewProgress: AnnotationReview.Progress { AnnotationReview.progress(reviewRallies.map(\.rally)) }

    func video(of item: AnnotationReview.Item) -> LabelVideo? { UUID(uuidString: item.video).flatMap(video) }

    func rally(of item: AnnotationReview.Item) -> TrackedRally? {
        video(of: item).flatMap { v in tracks(for: v).first { $0.id == item.track } }?.rally
    }

    func reviewItem(track: UUID, index: Int) -> AnnotationReview.Item? {
        snapshot.tracks.first { $0.id == track }.map { AnnotationReview.Item(video: $0.videoId.uuidString, track: track, index: index) }
    }

    /// A review decision: changed here at once, and sent as just that frame
    /// (another reviewer's frames of the rally are left alone).
    @discardableResult
    func review(_ item: AnnotationReview.Item, _ change: (inout TrackPoint) -> Void) -> TrackPoint? {
        guard var rally = rally(of: item), rally.points.indices.contains(item.index) else { return nil }
        let before = rally.points[item.index]
        change(&rally.points[item.index])
        apply(LabelingClient.FrameEdit(track: item.track, index: item.index, point: rally.points[item.index]))
        outbox.frames.append(LabelingClient.FrameEdit(track: item.track, index: item.index, point: rally.points[item.index]))
        queueFlush()
        return before
    }

    /// A frame decision onto the rally as it's held here.
    private func apply(_ edit: LabelingClient.FrameEdit) {
        func change(_ t: inout LabelTrack) {
            var rally = t.rally
            guard rally.points.indices.contains(edit.index) else { return }
            rally.points[edit.index] = edit.point
            let updated = LabelTrack(rally, videoId: t.videoId)
            t.points = updated.points
            t.reviewed = updated.reviewed
            t.unsure = updated.unsure
        }
        if let i = snapshot.tracks.firstIndex(where: { $0.id == edit.track }) { change(&snapshot.tracks[i]) }
        if outbox.tracks[edit.track] != nil { change(&outbox.tracks[edit.track]!) }
    }

    func claim(_ track: UUID) async -> Bool {
        // Offline: review on; the server refuses frames someone else claimed.
        (try? await client.reviewClaim(track)) ?? true
    }

    func videoFile(video key: String) async throws -> URL {
        guard let v = UUID(uuidString: key).flatMap(video) else { throw LabelingClient.Failure.unreadable }
        return try await localClip(for: v)
    }

    func videoName(video key: String) -> String { UUID(uuidString: key).flatMap(video)?.name ?? "" }

    func fetchAhead(video key: String) async {
        guard let v = UUID(uuidString: key).flatMap(video) else { return }
        await fetchAhead(v)
    }

    func playbackURL(video key: String) async throws -> URL {
        guard let v = UUID(uuidString: key).flatMap(video) else { throw LabelingClient.Failure.unreadable }
        return try await playbackURL(for: v)
    }

    func rallyChecks() -> [AnnotationReview.RallyCheck] { AnnotationReview.rallyChecks(reviewRallies) }

    func finishedRallies() -> [AnnotationReview.RallyCheck] { AnnotationReview.finished(reviewRallies) }

    func offTopGaps() -> [AnnotationReview.Gap] { AnnotationReview.offTop(reviewRallies) }

    /// Changed here at once, and sent as just that answer (the rally's frames
    /// are left as the server has them).
    func rally(of check: AnnotationReview.RallyCheck) -> TrackedRally? {
        UUID(uuidString: check.video).flatMap(video).flatMap { v in tracks(for: v).first { $0.id == check.track } }?.rally
    }

    func replace(_ check: AnnotationReview.RallyCheck, with rally: TrackedRally) {
        guard let v = UUID(uuidString: check.video).flatMap(video) else { return }
        save(LabelTrack(rally, videoId: v.id))
    }

    func setIsRally(_ isRally: Bool?, _ check: AnnotationReview.RallyCheck) {
        if let i = snapshot.tracks.firstIndex(where: { $0.id == check.track }) { snapshot.tracks[i].isRally = isRally }
        if outbox.tracks[check.track] != nil { outbox.tracks[check.track]!.isRally = isRally }
        outbox.rallies.append(LabelingClient.RallyVerdict(track: check.track, isRally: isRally))
        queueFlush()
    }

    // MARK: - Plan

    var project: String? { snapshot.videos.compactMap(\.project).first }

    var projectState: LabelProjectState? { snapshot.states.first { $0.project == project } }

    /// The first round not trained yet.
    var currentRound: TrainingPlan.Round? {
        let trained = Set(projectState?.plan.map(\.round) ?? [])
        return TrainingPlan.rounds.first { !trained.contains($0.number) }
    }

    func planVideo(_ v: LabelVideo) -> PlanVideo {
        let ready = tracks(for: v).filter(\.isReady).map(\.rally)
        return PlanVideo(name: v.name, surface: v.surface.rawValue, split: v.split, available: v.clipPath != nil,
                         rallies: ready.count,
                         labeledFrames: ready.reduce(0) { $0 + TrainingPlan.labels(labeled: $1.labeledFrames, checked: $1.checkedFrames, split: v.split) },
                         checkedFrames: ready.reduce(0) { $0 + $1.checkedFrames },
                         openRallies: untrackedRallies(in: v).count, ralliesMarked: rallyTimes(for: v).complete)
    }

    var progress: PlanProgress { PlanProgress(videos: videos.map(planVideo), round: currentRound) }

    /// Every video as the queue sees it (LabelQueue — the same rules as the Mac).
    private var queueVideos: [LabelQueue.Video] {
        videos.map { v in
            let times = rallyTimes(for: v)
            return LabelQueue.Video(plan: planVideo(v), nextRally: nextRally(in: v),
                                    found: found(in: v).count, marked: times.rallies.count, complete: times.complete, backlog: v.isBacklogged,
                                    access: access(for: v))
        }
    }

    /// How far marking the rallies has got, with each video's real length less
    /// its cut ranges (not footage, nothing to mark there; D-030).
    var marking: MarkingProgress {
        let duration = Dictionary(videos.map { ($0.name, $0.duration) }) { a, _ in a }
        let cuts = Dictionary(videos.map { ($0.name, rallyTimes(for: $0).cutRanges) }) { a, _ in a }
        return MarkingProgress(videos: queueVideos) { v in
            duration[v.plan.name].flatMap { $0 > 0 ? $0 - (cuts[v.plan.name] ?? []).seconds(within: $0) : nil }
        }
    }

    // MARK: - Next tasks

    enum LabelTask: Identifiable, Hashable {
        /// Confirm the rallies found in a video, find missed ones, finish it.
        case review(LabelVideo)
        /// Track one rally's ball, frame by frame.
        case track(LabelVideo, LabelRally)

        var id: String {
            switch self {
            case .review(let v): return "review-\(v.id)"
            case .track(let v, let r): return "track-\(v.id)-\(Int(r.start * 10))"
            }
        }

        var video: LabelVideo {
            switch self { case .review(let v), .track(let v, _): return v }
        }
    }

    /// What to do next (LabelQueue — the same rules as the Mac).
    var tasks: [LabelTask] {
        let byName = Dictionary(videos.map { ($0.name, $0) }) { a, _ in a }
        return LabelQueue.jobs(queueVideos, round: currentRound).compactMap { job in
            guard let v = byName[job.video] else { return nil }
            switch job {
            case .track(_, let r): return .track(v, r)
            case .review: return .review(v)
            }
        }
    }

    // MARK: - Editing

    func update(_ video: LabelVideo, _ change: (inout LabelRallyTimes) -> Void) {
        var t = rallyTimes(for: video)
        let wasComplete = t.complete
        change(&t)
        t.rallies.sort { $0.start < $1.start }
        t.cuts?.sort { $0.start < $1.start }
        t.updatedAt = Date()
        outbox.times[video.id] = t
        if t.complete && !wasComplete { count { $0.videos += 1 } }
        queueFlush()
    }

    /// A tracked rally's own start and end go into the video's rally times
    /// (replacing any marked rally it overlaps).
    func markRally(_ rally: LabelRally, in video: LabelVideo) {
        update(video) { t in
            t.rallies.removeAll { min($0.end, rally.end) - max($0.start, rally.start) > 0.3 }
            t.rallies.append(rally)
        }
    }

    /// Set a recording aside (the backlog; it leaves the queue until put back) or put it back (`reason` nil): shown
    /// at once, written to the outbox, sent on the next flush. The marks it has stay as they are.
    func setBacklog(_ video: LabelVideo, reason: String?) {
        // The outbox entry is what the rows show until it is sent (`withPendingBacklog`); the row itself takes
        // the value once the server has it, so a pull in between never hides an unsent choice.
        outbox.backlog[video.id] = BacklogChange(reason: reason, at: reason == nil ? nil : Date())
        queueFlush()
    }

    /// Marked all the way through, and nobody has said what the footage is: no type confirmed on the Mac, no
    /// choice waiting from this phone or on the server (a refused or replaced one asks again). Set-aside ones wait.
    var footageTypeToConfirm: [LabelVideo] {
        videos.filter { v in
            guard rallyTimes(for: v).complete, v.recordingTypeAt == nil, !v.isBacklogged else { return false }
            switch footageType(for: v) {
            case .none, .rejected, .superseded: return true
            case .pending(let p): return p.refusal != nil
            case .submitted, .accepted: return false
            }
        }.sorted { $0.name < $1.name }
    }

    /// The recordings set aside, newest first.
    var backlog: [LabelVideo] { videos.filter(\.isBacklogged).sorted { ($0.backlogAt ?? .distantPast) > ($1.backlogAt ?? .distantPast) } }

    func rejectFound(_ found: [Double], in video: LabelVideo) {
        LocalStore.reject(found, in: video)
        // Reading openFound again picks it up; nothing to sync.
        snapshot = snapshot
    }

    func save(_ track: LabelTrack) {
        var t = track
        let before = tracks(videoId: track.videoId).first { $0.id == track.id }
        t.updatedAt = Date()
        outbox.tracks[t.id] = t
        if t.done && before?.done != true { count { $0.rallies += 1; $0.frames += t.labeledFrames } }
        queueFlush()
    }

    func delete(_ track: LabelTrack) {
        var t = track
        t.deleted = true
        save(t)
        LocalStore.removeTracking(track.id)
    }

    private func count(_ change: (inout DayStats) -> Void) {
        if today.day != DayStats.today.day { today = DayStats.today }
        change(&today)
        LocalStore.save(today, "today.json")
    }

    // MARK: - Outbox

    private func queueFlush() {
        saveOutbox()
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Save everything waiting. What fails stays for next time. Flushes are serialised: a caller arriving while
    /// one runs waits for it, and the running flush goes round once more so nothing queued meanwhile is missed.
    func flush() async {
        if let running = flushInFlight {
            flushAgain = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.flushAgain = false
                await self.flushOnce()
            } while self.flushAgain
        }
        flushInFlight = task
        await task.value
        flushInFlight = nil
    }

    private func flushOnce() async {
        guard !outbox.isEmpty else { return }
        // Edits of a recording closed to this account since they were made (withheld, or its project's list gone)
        // stay on the phone, unsent: the server refuses them, and one refused row would hold back every other.
        let closed = Set(snapshot.videos.filter { !access(for: $0).offersMarking }.map(\.id))
        let heldBack = outbox.times.keys.filter(closed.contains).count + outbox.tracks.values.filter { closed.contains($0.videoId) }.count
        if heldBack > 0 { syncProblem = "\(heldBack) edit\(heldBack == 1 ? "" : "s") of a recording that is not open to labeling here now kept on this phone, not sent." }
        for (id, times) in outbox.times where !closed.contains(id) {
            do {
                let saved = try await client.save(times)
                if outbox.times[id] == times { outbox.times[id] = nil; settling.times[id] = times }
                snapshot.times.removeAll { $0.videoId == id }
                snapshot.times.append(saved)
            } catch { isOffline = true; break }
        }
        // Stage 1 records: each at the revision it was loaded from. A stale revision is a conflict the person
        // decides; a withheld refusal drops the edit (it should never have been possible) and says so.
        let reviewable = Set(snapshot.videos.filter { isReviewable($0) }.map(\.id))
        for (id, pending) in outbox.events where eventConflicts[id] == nil && eventIdentityProblems[id] == nil && reviewable.contains(id) {
            do {
                let saved = try await client.saveRallyEvents(videoId: id, expected: pending.expected, record: pending.record)
                // The person may have committed again while the save was in flight: the newer edit stays queued,
                // now on top of the revision the server just assigned (never dropped, never sent at a stale one).
                if let newer = outbox.events[id], newer != pending {
                    var carried = newer
                    carried.expected = saved.revision
                    carried.record.revision = saved.revision
                    outbox.events[id] = carried
                } else {
                    // Settles at the revision the server assigned: sent again after a kill, it is a repeat on top of
                    // the server's own copy, never a stale one.
                    var done = pending
                    done.expected = saved.revision
                    done.record.revision = saved.revision
                    outbox.events[id] = nil
                    settling.events[id] = done
                }
                snapshot.events.removeAll { $0.videoId == id }
                snapshot.events.append(saved)
            } catch let conflict as RallyEventsConflict {
                // The server's version is shown for a decision only when it describes this recording's original.
                if let server = try? await client.rallyEvents().first(where: { $0.videoId == id }) {
                    let checked = admit([server], videos: snapshot.videos, keeping: [])
                    if let ok = checked.first { eventConflicts[id] = ok }
                }
                syncProblem = conflict.errorDescription
            } catch LabelingClient.Failure.server(_, let message) where RallyEventsSync.isIdentityRefusal(message) {
                // The edit stays queued (nothing lost); it is not re-sent until a reload brings the identity back in line.
                eventIdentityProblems[id] = "refused by the server: " + message
                syncProblem = message
            } catch LabelingClient.Failure.server(let code, let message) where RallyEventsSync.isWithheld(message) || code == 403 {
                // Withheld on the server: the edit is kept on the phone, not sent again (quarantined).
                eventIdentityProblems[id] = "refused by the server: " + message
                syncProblem = message
            } catch { isOffline = true; break }
        }
        // Footage-type choices, oldest first, the refused ones left out: once the server has one, its copy here goes;
        // a refusal of the claim itself is written on the durable choice (shown, and never sent again as it is — a
        // new choice replaces it under a fresh id); a transient failure leaves the choice to be sent next time.
        for pending in RecordingTypeClaims.toSend(outbox.claims) {
            do {
                let row = try await client.submitRecordingTypeClaim(pending)
                outbox.claims[pending.id] = nil
                settling.claims[pending.id] = pending
                snapshot.claims.removeAll { $0.id == row.id }
                snapshot.claims.append(row)
            } catch LabelingClient.Failure.server(_, let message) where RecordingTypeClaims.isRefusal(message) {
                // Written to the outbox file at once, not at the end of the flush: a crash during the sends that follow
                // would otherwise leave the refusal in memory only, and the refused choice would be sent again.
                outbox.claims = RecordingTypeClaims.refusing(outbox.claims, id: pending.id, reason: message)
                saveOutbox()
                syncProblem = message
            } catch { isOffline = true; break }
        }
        // Recordings set aside or put back: the latest change per recording, as it is (the last writer wins on
        // the server, the same as the Mac's own change). A refusal (the recording not readable here any more)
        // drops the change and says so; a transient failure leaves it for the next flush.
        for (videoId, change) in outbox.backlog {
            do {
                try await client.setBacklog(videoId, reason: change.reason, at: change.at ?? Date())
                // The row takes what the server now has; a newer change made while this one was in flight stays
                // queued and goes next (the rally-times rule).
                if let i = snapshot.videos.firstIndex(where: { $0.id == videoId }) {
                    snapshot.videos[i].backlogReason = change.reason
                    snapshot.videos[i].backlogAt = change.at
                }
                if outbox.backlog[videoId] == change { outbox.backlog[videoId] = nil; settling.backlog[videoId] = change }
            } catch LabelingClient.Failure.server(let code, let message) where code == 403 || code == 400 {
                if outbox.backlog[videoId] == change { outbox.backlog[videoId] = nil }
                syncProblem = "Couldn't set \(video(videoId)?.name ?? "a recording") aside: \(message)"
            } catch { isOffline = true; break }
        }
        // Rally checks, in the order they were made (a taken-back one last).
        for verdict in outbox.rallies {
            do {
                try await client.reviewRally(verdict)
                if let i = outbox.rallies.firstIndex(of: verdict) { outbox.rallies.remove(at: i); settling.rallies.append(verdict) }
            } catch {
                isOffline = true
                break
            }
        }
        // Review decisions, rally by rally.
        let frames = outbox.frames
        for (track, edits) in Dictionary(grouping: frames, by: \.track) {
            do {
                try await client.reviewFrames(track, edits)
                outbox.frames.removeAll { edits.contains($0) }
                settling.frames += edits
            } catch LabelingClient.Failure.server(let code, _) where code == 400 {
                // Someone else is reviewing it: their decisions stand.
                outbox.frames.removeAll { edits.contains($0) }
            } catch {
                isOffline = true
                break
            }
        }
        let tracks = outbox.tracks.values.filter { !closed.contains($0.videoId) }
        if !tracks.isEmpty {
            do {
                try await client.save(tracks)
                for t in tracks where outbox.tracks[t.id] == t {
                    outbox.tracks[t.id] = nil
                    settling.tracks[t.id] = t
                    snapshot.tracks.removeAll { $0.id == t.id }
                    snapshot.tracks.append(t)
                }
                isOffline = false
            } catch {
                isOffline = true
                syncProblem = Self.describe("Couldn't send \(tracks.count) tracked rall\(tracks.count == 1 ? "y" : "ies")", error)
            }
        }
        persist()
    }

    // MARK: - Clips

    /// Clips downloading, and how far along (0–1).
    private(set) var downloads: [UUID: Double] = [:]
    @ObservationIgnored private var inFlight: [UUID: Task<URL, Error>] = [:]

    /// The clip on the phone, downloading it first if needed (one download
    /// per clip, however many ask).
    func localClip(for video: LabelVideo) async throws -> URL {
        let file = LocalStore.clip(for: video)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if let running = inFlight[video.id] { return try await running.value }
        guard let path = video.clipPath else { throw LabelingClient.Failure.unreadable }
        let id = video.id
        let partial = file.appendingPathExtension("part")
        let task = Task<URL, Error> { [client] in
            try await client.download(path, to: partial) { p in
                Task { @MainActor [weak self] in if self?.downloads[id] != nil { self?.downloads[id] = p } }
            }
            try FileManager.default.moveItem(at: partial, to: file)
            return file
        }
        inFlight[id] = task
        downloads[id] = 0
        defer { inFlight[id] = nil; downloads[id] = nil }
        return try await task.value
    }

    /// Fetch the next few tasks' clips in the background, one at a time,
    /// so tasks open with their clip already here.
    func prefetch(next n: Int = 3) {
        let wanted = tasks.prefix(n).map(\.video).filter { !LocalStore.hasClip($0) && inFlight[$0.id] == nil }
        guard !wanted.isEmpty, !isOffline else { return }
        Task {
            for v in wanted { await fetchAhead(v) }
        }
    }

    /// Clips to bring here ahead of need, downloaded one at a time in the
    /// order asked (two at once over cellular starve whatever is streaming).
    @ObservationIgnored private var aheadQueue: [LabelVideo] = []
    @ObservationIgnored private var aheadWorker: Task<Void, Never>?

    /// Queue `v`'s clip and wait for it (and the ones queued before it).
    func fetchAhead(_ v: LabelVideo) async {
        guard !LocalStore.hasClip(v), !isOffline else { return }
        if !aheadQueue.contains(where: { $0.id == v.id }) { aheadQueue.append(v) }
        if aheadWorker == nil {
            aheadWorker = Task { [weak self] in
                while let next = self?.aheadQueue.first {
                    self?.aheadQueue.removeFirst()
                    _ = try? await self?.localClip(for: next)
                }
                self?.aheadWorker = nil
            }
        }
        while !LocalStore.hasClip(v), inFlight[v.id] != nil || aheadQueue.contains(where: { $0.id == v.id }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The clip to play: on the phone if it's there, else streamed.
    /// Videos whose ball path isn't up yet (the Mac hasn't made or sent it);
    /// asked once per launch.
    @ObservationIgnored private var ballPathsMissing: Set<UUID> = []

    /// The pipeline's sightings of the ball over the video, made on the Mac
    /// and sent next to the clip; fetched once and kept.
    func ballPath(for video: LabelVideo) async -> [BallPath.Sample]? {
        // The path is the pipeline's output over the recording: not shown, and not fetched, for one no model may
        // run over — marking it goes on by hand, without snapping.
        guard access(for: video) == .open else { return nil }
        let local = LocalStore.ballPath(for: video)
        if let file = BallPathFile.load(local) { return file.samples }
        guard let clip = video.clipPath, !ballPathsMissing.contains(video.id) else { return nil }
        do {
            try await client.download(BallPathFile.remotePath(forClip: clip), to: local)
        } catch {
            ballPathsMissing.insert(video.id)
            return nil
        }
        return BallPathFile.load(local)?.samples
    }

    func playbackURL(for video: LabelVideo) async throws -> URL {
        if LocalStore.hasClip(video) { return LocalStore.clip(for: video) }
        guard let path = video.clipPath else { throw LabelingClient.Failure.unreadable }
        return try await client.signedURL(for: path)
    }

    /// Keep the clips for the next `n` tasks on the phone, for no signal.
    func makeOffline(next n: Int) async {
        for task in tasks.prefix(n) where !LocalStore.hasClip(task.video) {
            do { _ = try await localClip(for: task.video) } catch { self.error = "Couldn't download \(task.video.name): \(error.localizedDescription)"; return }
        }
    }

    /// Clips on the phone for videos that are finished (rally times done and
    /// no rally the plan still wants tracked) — safe to remove.
    func removeFinishedClips() {
        let wanted = Set(tasks.map(\.video.id))
        for v in videos where LocalStore.hasClip(v) && !wanted.contains(v.id) { LocalStore.removeClip(v) }
        snapshot = snapshot
    }

    // MARK: - Uploading from this phone

    struct UploadRequest {
        let source: URL
        let start: Double
        let length: Double
        let title: String
        let surface: LabelSurface
        let camera: LabelCamera
        let lighting: String
    }

    private(set) var uploadStage: String?
    private(set) var uploadProgress: Double = 0

    /// Re-encode the chosen stretch small, upload it, and list it for
    /// RallyLab on the Mac to pull into its project.
    func upload(_ request: UploadRequest) async -> Bool {
        let id = UUID()
        let encoded = FileManager.default.temporaryDirectory.appendingPathComponent("\(id.uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: encoded)
            uploadStage = nil
        }
        do {
            uploadStage = "Preparing the clip…"
            uploadProgress = 0
            let duration = try await ClipEncoder.encode(request.source, from: request.start, length: request.length, to: encoded) { p in
                Task { @MainActor [weak self] in self?.uploadProgress = p }
            }
            uploadStage = "Uploading…"
            uploadProgress = 0
            let path = "phone/\(id.uuidString.lowercased()).mp4"
            try await client.upload(encoded, to: path) { p in
                Task { @MainActor [weak self] in self?.uploadProgress = p }
            }
            let video = LabelVideo(id: id, project: nil, sessionName: nil, title: request.title, surface: request.surface,
                                   camera: request.camera, lighting: request.lighting, split: "train", clipPath: path,
                                   duration: duration, ralliesFound: [], status: .uploaded, updatedAt: nil)
            snapshot.videos.append(try await client.save(video))
            LocalStore.saveInBackground(snapshot, "snapshot.json") {}
            return true
        } catch {
            self.error = "Upload failed: \(error.localizedDescription)"
            return false
        }
    }
}
