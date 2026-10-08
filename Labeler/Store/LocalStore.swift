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
struct LabelSnapshot: Codable {
    var videos: [LabelVideo] = []
    var times: [LabelRallyTimes] = []
    var tracks: [LabelTrack] = []
    var states: [LabelProjectState] = []
}

/// Edits waiting to be saved: the latest version of each, by id.
struct Outbox: Codable {
    var times: [UUID: LabelRallyTimes] = [:]
    var tracks: [UUID: LabelTrack] = [:]

    var isEmpty: Bool { times.isEmpty && tracks.isEmpty }
    var count: Int { times.count + tracks.count }
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

    static func clip(for video: LabelVideo) -> URL { clips.appendingPathComponent("\(video.id.uuidString).mp4") }

    static func hasClip(_ video: LabelVideo) -> Bool { FileManager.default.fileExists(atPath: clip(for: video).path) }

    static func removeClip(_ video: LabelVideo) { try? FileManager.default.removeItem(at: clip(for: video)) }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        (try? Data(contentsOf: support.appendingPathComponent(name))).flatMap { try? decoder.decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? encoder.encode(value) { try? data.write(to: support.appendingPathComponent(name), options: .atomic) }
    }

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

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
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
