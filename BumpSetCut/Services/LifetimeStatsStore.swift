//
//  LifetimeStatsStore.swift
//  BumpSetCut
//
//  Persistent, monotonic lifetime processing stats (time cut + rally count),
//  linked to the signed-in account.
//

import Foundation
import Observation

/// Lifetime cumulative stats shown on Home. They only ever grow: deleting
/// processed videos does NOT reduce them, and re-processing the same video
/// can't double-count (idempotent per source video).
///
/// The account's `user_stats` row is the source of truth. Locally we keep a
/// per-account cache of the server totals plus a **pending delta** — increments
/// recorded offline, while signed out, or before the server confirmed — which
/// is credited to whichever account signs in next. The card shows
/// server + pending so it moves immediately.
@MainActor
@Observable
final class LifetimeStatsStore {
    static let shared = LifetimeStatsStore()

    private let defaults: UserDefaults
    private let apiClient: any APIClient

    // Device-wide totals from before stats were account-linked; claimed into
    // pending exactly once, on the first sign-in after upgrading.
    private let legacyTimeCutKey = "lifetime_timeCutSeconds"
    private let legacyRalliesKey = "lifetime_rallyCount"
    private let legacyClaimedKey = "lifetime_legacyClaimed"
    private let countedKey = "lifetime_countedVideoIds"
    private let seededKey = "lifetime_statsSeeded"
    private let pendingTimeCutKey = "lifetime_pendingTimeCutSeconds"
    private let pendingRalliesKey = "lifetime_pendingRallyCount"

    private func accountTimeCutKey(_ userId: String) -> String { "lifetime_account_\(userId)_timeCutSeconds" }
    private func accountRalliesKey(_ userId: String) -> String { "lifetime_account_\(userId)_rallyCount" }

    /// Signed-in account whose totals are shown; nil while signed out.
    private(set) var accountId: String?
    // Observable mirrors of the persisted values (UserDefaults isn't observable).
    private(set) var accountRallies = 0
    private(set) var accountTimeCutSeconds: Double = 0
    private(set) var pendingRallies: Int
    private(set) var pendingTimeCutSeconds: Double
    /// A flush in progress — later callers wait for it, then re-check pending,
    /// so nothing is skipped and nothing is sent twice.
    @ObservationIgnored private var inFlightFlush: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, apiClient: (any APIClient)? = nil) {
        self.defaults = defaults
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
        pendingRallies = defaults.integer(forKey: pendingRalliesKey)
        pendingTimeCutSeconds = defaults.double(forKey: pendingTimeCutKey)
    }

    /// Totals for the signed-in account, including increments the server
    /// hasn't confirmed yet (so the card updates instantly, even offline).
    var totalRallies: Int { accountRallies + pendingRallies }
    var totalTimeCutSeconds: Double { accountTimeCutSeconds + pendingTimeCutSeconds }

    /// True once the one-time upgrade backfill has run. Callers can use this to
    /// skip the (expensive) metadata scan that only feeds `seedIfNeeded`.
    var hasSeeded: Bool { defaults.bool(forKey: seededKey) }

    private var countedIds: Set<String> {
        get { Set(defaults.stringArray(forKey: countedKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: countedKey) }
    }

    // MARK: - Recording

    /// Add one processed video's contribution. No-op if this video was already counted,
    /// so re-processing or repeated calls are safe.
    func record(videoId: UUID, timeCutSeconds: Double, rallyCount: Int) {
        var ids = countedIds
        guard ids.insert(videoId.uuidString).inserted else { return }
        countedIds = ids
        addPending(rallies: max(0, rallyCount), timeCut: max(0, timeCutSeconds))
        Task { await flush() }
    }

    /// One-time backfill so users upgrading from the live-sum version keep their existing
    /// total. Seeds from whatever processed videos are currently on the device, marks them
    /// counted, and never runs again — so a later deletion can't re-trigger a lower seed.
    func seedIfNeeded(from contributions: [(videoId: UUID, timeCutSeconds: Double, rallyCount: Int)]) {
        guard !defaults.bool(forKey: seededKey) else { return }
        var ids = countedIds
        var rallies = 0
        var timeCut: Double = 0
        for c in contributions where ids.insert(c.videoId.uuidString).inserted {
            rallies += max(0, c.rallyCount)
            timeCut += max(0, c.timeCutSeconds)
        }
        countedIds = ids
        addPending(rallies: rallies, timeCut: timeCut)
        defaults.set(true, forKey: seededKey)
        Task { await flush() }
    }

    // MARK: - Account lifecycle

    /// Switch to `userId`'s totals (cached instantly), then pull the server
    /// row and push anything pending.
    func signIn(userId: String) async {
        accountId = userId
        accountRallies = defaults.integer(forKey: accountRalliesKey(userId))
        accountTimeCutSeconds = defaults.double(forKey: accountTimeCutKey(userId))
        claimLegacyTotalsIfNeeded()
        await refreshFromServer()
        await flush()
    }

    func signOut() {
        accountId = nil
        accountRallies = 0
        accountTimeCutSeconds = 0
    }

    func refreshFromServer() async {
        guard let accountId else { return }
        guard let stats: UserStats = try? await apiClient.request(.getMyStats) else { return }
        // Signed out (or switched) while the request was in flight.
        guard self.accountId == accountId else { return }
        apply(stats, for: accountId)
    }

    /// Push pending increments to the account. Pending is cleared only once the
    /// server confirms, so a failure simply retries on the next opportunity.
    func flush() async {
        if let inFlight = inFlightFlush {
            await inFlight.value
        }
        guard let accountId else { return }
        let rallies = pendingRallies
        let timeCut = pendingTimeCutSeconds
        guard rallies > 0 || timeCut > 0 else { return }

        let task = Task { await self.send(rallies: rallies, timeCut: timeCut, to: accountId) }
        inFlightFlush = task
        await task.value
        if inFlightFlush == task {
            inFlightFlush = nil
        }
    }

    private func send(rallies: Int, timeCut: Double, to accountId: String) async {
        guard let stats: UserStats = try? await apiClient.request(
            .addMyStats(rallies: rallies, timeCutSeconds: timeCut)
        ) else { return }
        guard self.accountId == accountId else { return }

        // Subtract exactly what was sent — anything recorded mid-flight stays pending.
        addPending(rallies: -rallies, timeCut: -timeCut)
        apply(stats, for: accountId)
    }

    // MARK: - Private

    private func apply(_ stats: UserStats, for userId: String) {
        accountRallies = stats.ralliesFound
        accountTimeCutSeconds = stats.timeCutSeconds
        defaults.set(stats.ralliesFound, forKey: accountRalliesKey(userId))
        defaults.set(stats.timeCutSeconds, forKey: accountTimeCutKey(userId))
    }

    private func addPending(rallies: Int, timeCut: Double) {
        pendingRallies = max(0, pendingRallies + rallies)
        pendingTimeCutSeconds = max(0, pendingTimeCutSeconds + timeCut)
        defaults.set(pendingRallies, forKey: pendingRalliesKey)
        defaults.set(pendingTimeCutSeconds, forKey: pendingTimeCutKey)
    }

    /// Totals accumulated before stats were account-linked belong to whoever
    /// signs in first on this device — move them into pending exactly once.
    private func claimLegacyTotalsIfNeeded() {
        guard !defaults.bool(forKey: legacyClaimedKey) else { return }
        addPending(
            rallies: defaults.integer(forKey: legacyRalliesKey),
            timeCut: defaults.double(forKey: legacyTimeCutKey)
        )
        defaults.set(true, forKey: legacyClaimedKey)
    }
}
