//
//  LocalStore.swift
//  RallyLab (iPhone)
//
//  What lets the phone work without signal: the last data loaded from
//  Supabase (so the app opens offline), an outbox of edits not saved yet
//  (sent when there's a connection), clips kept on the phone, and the
//  found rallies you've said aren't rallies.
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
