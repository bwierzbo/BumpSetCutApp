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
///
/// Sending is exactly-once per increment: pending amounts are moved into a
/// persisted batch with a UUID before they're sent, and that same batch (same
/// id, same amounts) is resent until the server confirms it. A lost response
/// therefore can't double-credit (the server dedupes on the id), and a
/// confirmed batch is always retired — even if the account changed while it
/// was in flight.
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
    private let batchesKey = "lifetime_unconfirmedBatches"

    private func accountTimeCutKey(_ userId: String) -> String { "lifetime_account_\(userId)_timeCutSeconds" }
    private func accountRalliesKey(_ userId: String) -> String { "lifetime_account_\(userId)_rallyCount" }

    /// Pending amounts already sent (or being sent) to one account whose
    /// confirmation hasn't arrived. Resent unchanged until confirmed.
    private struct StatsBatch: Codable {
        let id: UUID
        let accountId: String
        let rallies: Int
        let timeCutSeconds: Double
    }

    /// Signed-in account whose totals are shown; nil while signed out.
    private(set) var accountId: String?
    // Observable mirrors of the persisted values (UserDefaults isn't observable).
    private(set) var accountRallies = 0
    private(set) var accountTimeCutSeconds: Double = 0
    /// Recorded but not yet assigned to a batch.
    private var unbatchedRallies: Int
    private var unbatchedTimeCutSeconds: Double
    /// Unconfirmed batches, at most one per account.
    private var batches: [String: StatsBatch]
    /// A flush in progress — later callers wait for it, then re-check pending,
    /// so nothing is skipped and nothing is sent twice.
    @ObservationIgnored private var inFlightFlush: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, apiClient: (any APIClient)? = nil) {
        self.defaults = defaults
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
        unbatchedRallies = defaults.integer(forKey: pendingRalliesKey)
        unbatchedTimeCutSeconds = defaults.double(forKey: pendingTimeCutKey)
        batches = defaults.data(forKey: batchesKey)
            .flatMap { try? JSONDecoder().decode([String: StatsBatch].self, from: $0) } ?? [:]
    }

    /// Increments the server hasn't confirmed yet: unbatched ones plus the
    /// unconfirmed batch of the signed-in account (every batch while signed out).
    var pendingRallies: Int {
        unbatchedRallies + visibleBatches.reduce(0) { $0 + $1.rallies }
    }
    var pendingTimeCutSeconds: Double {
        unbatchedTimeCutSeconds + visibleBatches.reduce(0) { $0 + $1.timeCutSeconds }
    }

    private var visibleBatches: [StatsBatch] {
        guard let accountId else { return Array(batches.values) }
        return batches[accountId].map { [$0] } ?? []
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
        addUnbatched(rallies: max(0, rallyCount), timeCut: max(0, timeCutSeconds))
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
        addUnbatched(rallies: rallies, timeCut: timeCut)
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

    /// Push pending increments to the signed-in account: its unconfirmed
    /// batch if it has one (resent unchanged), otherwise a new batch of
    /// everything unbatched. A failure leaves the batch for the next attempt.
    func flush() async {
        if let inFlight = inFlightFlush {
            await inFlight.value
        }
        guard let accountId else { return }

        let batch: StatsBatch
        if let unconfirmed = batches[accountId] {
            batch = unconfirmed
        } else {
            guard unbatchedRallies > 0 || unbatchedTimeCutSeconds > 0 else { return }
            batch = StatsBatch(id: UUID(), accountId: accountId,
                               rallies: unbatchedRallies, timeCutSeconds: unbatchedTimeCutSeconds)
            // Persist the batch before moving its amounts out of the unbatched pool.
            batches[accountId] = batch
            persistBatches()
            addUnbatched(rallies: -batch.rallies, timeCut: -batch.timeCutSeconds)
        }

        let task = Task { await self.send(batch) }
        inFlightFlush = task
        await task.value
        if inFlightFlush == task {
            inFlightFlush = nil
        }
    }

    private func send(_ batch: StatsBatch) async {
        guard let stats: UserStats = try? await apiClient.request(
            .addMyStats(rallies: batch.rallies, timeCutSeconds: batch.timeCutSeconds, batchId: batch.id)
        ) else { return }

        // Confirmed: retire the batch whoever is signed in now — keeping it
        // would credit the same increments again.
        batches[batch.accountId] = nil
        persistBatches()
        // Only show the totals if they're still the visible account's.
        guard accountId == batch.accountId else { return }
        apply(stats, for: batch.accountId)
    }

    // MARK: - Private

    private func apply(_ stats: UserStats, for userId: String) {
        accountRallies = stats.ralliesFound
        accountTimeCutSeconds = stats.timeCutSeconds
        defaults.set(stats.ralliesFound, forKey: accountRalliesKey(userId))
        defaults.set(stats.timeCutSeconds, forKey: accountTimeCutKey(userId))
    }

    private func addUnbatched(rallies: Int, timeCut: Double) {
        unbatchedRallies = max(0, unbatchedRallies + rallies)
        unbatchedTimeCutSeconds = max(0, unbatchedTimeCutSeconds + timeCut)
        defaults.set(unbatchedRallies, forKey: pendingRalliesKey)
        defaults.set(unbatchedTimeCutSeconds, forKey: pendingTimeCutKey)
    }

    private func persistBatches() {
        defaults.set(try? JSONEncoder().encode(batches), forKey: batchesKey)
    }

    /// Totals accumulated before stats were account-linked belong to whoever
    /// signs in first on this device — move them into pending exactly once.
    private func claimLegacyTotalsIfNeeded() {
        guard !defaults.bool(forKey: legacyClaimedKey) else { return }
        addUnbatched(
            rallies: defaults.integer(forKey: legacyRalliesKey),
            timeCut: defaults.double(forKey: legacyTimeCutKey)
        )
        defaults.set(true, forKey: legacyClaimedKey)
    }
}
