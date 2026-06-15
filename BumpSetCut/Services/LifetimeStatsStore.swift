//
//  LifetimeStatsStore.swift
//  BumpSetCut
//
//  Persistent, monotonic lifetime processing stats (time cut + rally count).
//

import Foundation

/// Lifetime cumulative stats shown on Home. Unlike a live sum over the current library,
/// these only ever grow: deleting processed videos does NOT reduce them. Backed by
/// UserDefaults and made idempotent per source video so re-processing or re-saving the
/// same video can't double-count.
@MainActor
final class LifetimeStatsStore {
    static let shared = LifetimeStatsStore()

    private let defaults: UserDefaults
    private let timeCutKey = "lifetime_timeCutSeconds"
    private let ralliesKey = "lifetime_rallyCount"
    private let countedKey = "lifetime_countedVideoIds"
    private let seededKey = "lifetime_statsSeeded"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var totalTimeCutSeconds: Double { defaults.double(forKey: timeCutKey) }
    var totalRallies: Int { defaults.integer(forKey: ralliesKey) }

    private var countedIds: Set<String> {
        get { Set(defaults.stringArray(forKey: countedKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: countedKey) }
    }

    /// Add one processed video's contribution. No-op if this video was already counted,
    /// so re-processing or repeated calls are safe.
    func record(videoId: UUID, timeCutSeconds: Double, rallyCount: Int) {
        var ids = countedIds
        guard ids.insert(videoId.uuidString).inserted else { return }
        countedIds = ids
        defaults.set(totalTimeCutSeconds + max(0, timeCutSeconds), forKey: timeCutKey)
        defaults.set(totalRallies + max(0, rallyCount), forKey: ralliesKey)
    }

    /// One-time backfill so users upgrading from the live-sum version keep their existing
    /// total. Seeds from whatever processed videos are currently on the device, marks them
    /// counted, and never runs again — so a later deletion can't re-trigger a lower seed.
    func seedIfNeeded(from contributions: [(videoId: UUID, timeCutSeconds: Double, rallyCount: Int)]) {
        guard !defaults.bool(forKey: seededKey) else { return }
        var ids = countedIds
        var time = totalTimeCutSeconds
        var rallies = totalRallies
        for c in contributions where ids.insert(c.videoId.uuidString).inserted {
            time += max(0, c.timeCutSeconds)
            rallies += max(0, c.rallyCount)
        }
        countedIds = ids
        defaults.set(time, forKey: timeCutKey)
        defaults.set(rallies, forKey: ralliesKey)
        defaults.set(true, forKey: seededKey)
    }
}
