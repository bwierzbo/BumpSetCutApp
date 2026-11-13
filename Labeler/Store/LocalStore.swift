//
//  LocalStore.swift
//  RallyLab (iPhone)
//
//  What lets the phone work without signal: the last data loaded from
//  Supabase (so the app opens offline), an outbox of edits not saved yet
//  (sent when there's a connection), clips kept on the phone, the found
//  rallies you've said aren't rallies, and a rally being tracked — its
//  frames, what the detectors found and the frame you were on — so leaving
//  and coming back carries on where you were, without finding the ball again.
//

import Foundation

/// Everything the app shows, as last loaded.
struct LabelSnapshot: Codable, Sendable {
    var videos: [LabelVideo] = []
    var times: [LabelRallyTimes] = []
    var tracks: [LabelTrack] = []
    var states: [LabelProjectState] = []
    /// Stage 1 rally-boundary records, by recording (migration 048).
    var events: [LabelRallyEvents] = []
    /// The project's withheld recordings as published; nil = no list published for that project (nothing reviewable).
    var withheld: [String: [String]] = [:]
    /// Footage-type claims (migration 052; D-033): this phone's and others', with their state.
    var claims: [RecordingTypeClaim] = []
    /// The signed-in account is a lead (public.labelers.lead), as last loaded; false until it has been (a snapshot
    /// from an older build): then a withheld recording is closed here, as it is for an ordinary labeler.
    var lead = false

    init(videos: [LabelVideo] = [], times: [LabelRallyTimes] = [], tracks: [LabelTrack] = [], states: [LabelProjectState] = [],
         events: [LabelRallyEvents] = [], withheld: [String: [String]] = [:], claims: [RecordingTypeClaim] = [], lead: Bool = false) {
        self.videos = videos; self.times = times; self.tracks = tracks; self.states = states; self.events = events; self.withheld = withheld
        self.claims = claims; self.lead = lead
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videos = try c.decodeIfPresent([LabelVideo].self, forKey: .videos) ?? []
        times = try c.decodeIfPresent([LabelRallyTimes].self, forKey: .times) ?? []
        tracks = try c.decodeIfPresent([LabelTrack].self, forKey: .tracks) ?? []
        states = try c.decodeIfPresent([LabelProjectState].self, forKey: .states) ?? []
        events = try c.decodeIfPresent([LabelRallyEvents].self, forKey: .events) ?? []
        withheld = try c.decodeIfPresent([String: [String]].self, forKey: .withheld) ?? [:]
        claims = try c.decodeIfPresent([RecordingTypeClaim].self, forKey: .claims) ?? []
        lead = try c.decodeIfPresent(Bool.self, forKey: .lead) ?? false
    }
}

/// A Stage 1 record edited on the phone and not saved yet: the record and the server revision it was loaded from.
/// A recording set aside (reason, when) or put back (both nil), waiting to be sent; who, the server learns from
/// the account that sends it.
struct BacklogChange: Codable, Equatable, Sendable {
    var reason: String?
    var at: Date?
}

struct PendingRallyEvents: Codable, Equatable {
    var videoId: UUID
    var expected: Int
    var record: EventReview.File
}

/// Edits waiting to be saved: the latest version of each, by id.
struct Outbox: Codable {
    var times: [UUID: LabelRallyTimes] = [:]
    var tracks: [UUID: LabelTrack] = [:]
    /// Review decisions, sent frame by frame (see LabelingClient.reviewFrames).
    var frames: [LabelingClient.FrameEdit] = []
    /// Rally checks of pre-tracked rallies (see LabelingClient.reviewRally).
    var rallies: [LabelingClient.RallyVerdict] = []

    /// Stage 1 records waiting to be saved, by recording (the latest edit of each).
    var events: [UUID: PendingRallyEvents] = [:]
    /// Footage-type choices waiting to be sent, by claim id (D-033): durable until the server has them.
    var claims: [UUID: RecordingTypeClaims.Pending] = [:]
    /// Recordings set aside or put back (the backlog), by video: the latest change, sent as it is.
    var backlog: [UUID: BacklogChange] = [:]
    var isEmpty: Bool { times.isEmpty && tracks.isEmpty && frames.isEmpty && rallies.isEmpty && events.isEmpty && claims.isEmpty && backlog.isEmpty }
    var count: Int { times.count + tracks.count + frames.count + rallies.count + events.count + claims.count + backlog.count }

    /// This outbox with `settling`'s rows behind it: a live edit of the same thing wins, and the settled checks and
    /// decisions come first, as they were made.
    func carrying(_ settling: Outbox) -> Outbox {
        var all = self
        all.times.merge(settling.times) { mine, _ in mine }
        all.tracks.merge(settling.tracks) { mine, _ in mine }
        all.events.merge(settling.events) { mine, _ in mine }
        all.claims.merge(settling.claims) { mine, _ in mine }
        all.backlog.merge(settling.backlog) { mine, _ in mine }
        all.frames = settling.frames + frames
        all.rallies = settling.rallies + rallies
        return all
    }

    /// Takes `carried`'s rows out, each only where it is still the same row.
    mutating func drop(_ carried: Outbox) {
        for (id, row) in carried.times where times[id] == row { times[id] = nil }
        for (id, row) in carried.tracks where tracks[id] == row { tracks[id] = nil }
        for (id, row) in carried.events where events[id] == row { events[id] = nil }
        for (id, row) in carried.claims where claims[id] == row { claims[id] = nil }
        for (id, row) in carried.backlog where backlog[id] == row { backlog[id] = nil }
        for edit in carried.frames { if let i = frames.firstIndex(of: edit) { frames.remove(at: i) } }
        for verdict in carried.rallies { if let i = rallies.firstIndex(of: verdict) { rallies.remove(at: i) } }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        times = try c.decodeIfPresent([UUID: LabelRallyTimes].self, forKey: .times) ?? [:]
        tracks = try c.decodeIfPresent([UUID: LabelTrack].self, forKey: .tracks) ?? [:]
        frames = try c.decodeIfPresent([LabelingClient.FrameEdit].self, forKey: .frames) ?? []
        rallies = try c.decodeIfPresent([LabelingClient.RallyVerdict].self, forKey: .rallies) ?? []
        events = try c.decodeIfPresent([UUID: PendingRallyEvents].self, forKey: .events) ?? [:]
        claims = try c.decodeIfPresent([UUID: RecordingTypeClaims.Pending].self, forKey: .claims) ?? [:]
        backlog = try c.decodeIfPresent([UUID: BacklogChange].self, forKey: .backlog) ?? [:]
    }
}

enum LocalStore {

    private static var support: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RallyLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Clips are re-downloadable, but kept out of Caches so iOS doesn't
    /// clear the ones you made available offline.
    static var clips: URL {
        let dir = support.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Named for the copy it is (a re-encoded copy has a new path), so a
    /// replaced copy is fetched again.
    static func clip(for video: LabelVideo) -> URL {
        let copy = video.clipPath.map { ($0 as NSString).lastPathComponent } ?? "clip.mp4"
        return clips.appendingPathComponent("\(video.id.uuidString)-\(copy)")
    }

    /// Delete clips on the phone that aren't any of these videos' current copies.
    static func pruneClips(keeping videos: [LabelVideo]) {
        let keep = Set(videos.map { clip(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) && !file.lastPathComponent.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The pipeline's sightings of the ball in the video (BallPathFile),
    /// named for the copy they were made from.
    static func ballPath(for video: LabelVideo) -> URL {
        let copy = video.clipPath.map { ($0 as NSString).lastPathComponent } ?? "clip"
        return support.appendingPathComponent("\(video.id.uuidString)-\(copy).ballpath.json")
    }

    static func hasClip(_ video: LabelVideo) -> Bool { FileManager.default.fileExists(atPath: clip(for: video).path) }

    static func removeClip(_ video: LabelVideo) { try? FileManager.default.removeItem(at: clip(for: video)) }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        (try? Data(contentsOf: support.appendingPathComponent(name))).flatMap { try? decoder.decode(T.self, from: $0) }
    }

    /// Written before returning: the outbox (what this phone still owes the server) and the day's count are small,
    /// and an edit counts as kept only once this has returned.
    static func save<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? encoder.encode(value) { try? data.write(to: support.appendingPathComponent(name), options: .atomic) }
    }

    /// Encoded and written off the main thread, one write at a time in the order asked, then `done` on the main
    /// actor once the file holds this value. For the snapshot — the server's rows as last seen, with every tracked
    /// rally's points: ~12 MB of JSON on a phone that labels Scratch — whose encoding on the main thread took
    /// 370–410 ms on the owner's iPhone (2026-11-04), felt as a stutter about two seconds after every Dead ball.
    /// A write still queued when the process dies is lost, so nothing may depend on it until `done` has run.
    static func saveInBackground<T: Encodable & Sendable>(_ value: T, _ name: String, then done: @escaping @MainActor @Sendable () -> Void) {
        writer.async {
            if let data = try? makeEncoder().encode(value) { try? data.write(to: support.appendingPathComponent(name), options: .atomic) }
            Task { @MainActor in done() }
        }
    }

    private static let writer = DispatchQueue(label: "app.BumpSetCut.RallyLab.LocalStore.writer", qos: .userInitiated)

    // MARK: - A rally being tracked

    /// A rally's frames (JPEG) at their times, as read for tracking.
    private struct Frames: Codable {
        var times: [Double]
        var frames: [Data]
    }

    private static func work(_ id: UUID) -> URL {
        let dir = support.appendingPathComponent("Tracking/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveTracking(_ id: UUID, times: [Double], frames: [Data], candidates: [[TrackCandidate]]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(Frames(times: times, frames: frames)) {
            try? data.write(to: work(id).appendingPathComponent("frames.plist"), options: .atomic)
        }
        saveCandidates(id, candidates)
    }

    static func saveCandidates(_ id: UUID, _ candidates: [[TrackCandidate]]) {
        if let data = try? JSONEncoder().encode(candidates) {
            try? data.write(to: work(id).appendingPathComponent("candidates.json"), options: .atomic)
        }
    }

    /// The frames and candidates kept for this rally, if they're for these
    /// frame times.
    static func tracking(_ id: UUID, times: [Double]) -> (frames: [Data], candidates: [[TrackCandidate]])? {
        let dir = work(id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("frames.plist")),
              let kept = try? PropertyListDecoder().decode(Frames.self, from: data), kept.times == times,
              let c = try? Data(contentsOf: dir.appendingPathComponent("candidates.json")),
              let candidates = try? JSONDecoder().decode([[TrackCandidate]].self, from: c),
              candidates.count == times.count else { return nil }
        return (kept.frames, candidates)
    }

    static func removeTracking(_ id: UUID) {
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Tracking/\(id.uuidString)"))
        var all = UserDefaults.standard.dictionary(forKey: positionKey) ?? [:]
        all[id.uuidString] = nil
        UserDefaults.standard.set(all, forKey: positionKey)
    }

    private static let trimKey = "trimmedRallies"

    /// How you trimmed a rally (by its video and untrimmed start), kept from
    /// the moment you confirm the trim — the clip may still be downloading —
    /// until tracking saves the rally itself.
    static func trim(of rally: LabelRally, in video: LabelVideo) -> LabelRally? {
        guard let r = UserDefaults.standard.dictionary(forKey: trimKey)?["\(video.id.uuidString)/\(key([rally.start]))"] as? [Double],
              r.count == 2 else { return nil }
        return LabelRally(start: r[0], end: r[1])
    }

    static func setTrim(_ trimmed: LabelRally, of rally: LabelRally, in video: LabelVideo) {
        var all = UserDefaults.standard.dictionary(forKey: trimKey) ?? [:]
        all["\(video.id.uuidString)/\(key([rally.start]))"] = [trimmed.start, trimmed.end]
        UserDefaults.standard.set(all, forKey: trimKey)
    }

    private static let positionKey = "trackingPosition"

    /// The time of the frame you were on in a rally being tracked.
    static func position(_ id: UUID) -> Double? {
        UserDefaults.standard.dictionary(forKey: positionKey)?[id.uuidString] as? Double
    }

    static func setPosition(_ time: Double, for id: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: positionKey) ?? [:]
        all[id.uuidString] = time
        UserDefaults.standard.set(all, forKey: positionKey)
    }

    // MARK: - Found rallies you've said aren't rallies

    private static let rejectedKey = "rejectedFoundRallies"

    static func rejected(_ video: LabelVideo) -> Set<Int> {
        Set((UserDefaults.standard.dictionary(forKey: rejectedKey)?[video.id.uuidString] as? [Int]) ?? [])
    }

    static func reject(_ found: [Double], in video: LabelVideo) {
        var all = UserDefaults.standard.dictionary(forKey: rejectedKey) ?? [:]
        all[video.id.uuidString] = Array(rejected(video).union([key(found)]))
        UserDefaults.standard.set(all, forKey: rejectedKey)
    }

    /// A found rally by its start, to the tenth of a second.
    static func key(_ found: [Double]) -> Int { Int((found[0] * 10).rounded()) }

    private static let encoder: JSONEncoder = makeEncoder()

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// What you labeled today, for the Next tab.
struct DayStats: Codable {
    var day: String
    var rallies = 0
    var frames = 0
    var videos = 0

    static var today: DayStats {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        guard let saved = LocalStore.load(DayStats.self, "today.json"), saved.day == day else { return DayStats(day: day) }
        return saved
    }
}
