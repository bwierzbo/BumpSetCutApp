//
//  LifetimeStatsStoreTests.swift
//  BumpSetCutTests
//
//  Account-linked lifetime stats: idempotent recording, the pending delta
//  that waits for a sign-in, one-time legacy claim, and flush semantics.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class LifetimeStatsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LifetimeStatsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(client: MockStatsClient) -> LifetimeStatsStore {
        LifetimeStatsStore(defaults: defaults, apiClient: client)
    }

    // MARK: - Signed out

    func testRecordAccumulatesPendingWhileSignedOutAndIsIdempotent() {
        let client = MockStatsClient()
        let store = makeStore(client: client)
        let video = UUID()

        store.record(videoId: video, timeCutSeconds: 120, rallyCount: 5)
        store.record(videoId: video, timeCutSeconds: 120, rallyCount: 5) // re-process: ignored
        store.record(videoId: UUID(), timeCutSeconds: 30, rallyCount: 2)

        XCTAssertEqual(store.totalRallies, 7)
        XCTAssertEqual(store.totalTimeCutSeconds, 150, accuracy: 0.001)
        XCTAssertTrue(client.addCalls.isEmpty, "Nothing should be sent without an account")
    }

    // MARK: - Sign in

    func testSignInFlushesPendingAndShowsServerTotals() async {
        let client = MockStatsClient()
        client.serverStats = UserStats(userId: "u1", ralliesFound: 100, timeCutSeconds: 3600)
        let store = makeStore(client: client)
        store.record(videoId: UUID(), timeCutSeconds: 60, rallyCount: 3)

        await store.signIn(userId: "u1")

        XCTAssertEqual(client.addCalls.count, 1)
        XCTAssertEqual(client.addCalls.first?.rallies, 3)
        XCTAssertEqual(client.addCalls.first?.timeCut ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(store.pendingRallies, 0)
        XCTAssertEqual(store.totalRallies, 103)
        XCTAssertEqual(store.totalTimeCutSeconds, 3660, accuracy: 0.001)
    }

    func testLegacyDeviceTotalsAreClaimedExactlyOnce() async {
        defaults.set(40, forKey: "lifetime_rallyCount")
        defaults.set(900.0, forKey: "lifetime_timeCutSeconds")
        let client = MockStatsClient()
        let store = makeStore(client: client)

        await store.signIn(userId: "u1")
        store.signOut()
        await store.signIn(userId: "u1")

        XCTAssertEqual(client.addCalls.count, 1, "Legacy totals must be credited once, not on every sign-in")
        XCTAssertEqual(client.addCalls.first?.rallies, 40)
        XCTAssertEqual(store.totalRallies, 40)
    }

    func testFlushFailureKeepsPendingForRetry() async {
        let client = MockStatsClient()
        client.shouldFail = true
        let store = makeStore(client: client)
        store.record(videoId: UUID(), timeCutSeconds: 10, rallyCount: 1)

        await store.signIn(userId: "u1")
        XCTAssertEqual(store.pendingRallies, 1, "Pending must survive a failed flush")
        XCTAssertEqual(store.totalRallies, 1, "Card still shows the unsynced increment")

        client.shouldFail = false
        await store.flush()
        XCTAssertEqual(store.pendingRallies, 0)
        XCTAssertEqual(client.serverStats.ralliesFound, 1)
    }

    func testSignOutHidesAccountTotalsButKeepsPending() async {
        let client = MockStatsClient()
        client.serverStats = UserStats(userId: "u1", ralliesFound: 10, timeCutSeconds: 100)
        let store = makeStore(client: client)
        await store.signIn(userId: "u1")
        XCTAssertEqual(store.totalRallies, 10)

        store.signOut()
        store.record(videoId: UUID(), timeCutSeconds: 5, rallyCount: 2)

        XCTAssertEqual(store.totalRallies, 2, "Only unsynced increments show while signed out")
    }

    // MARK: - Exactly-once delivery

    func testConfirmedSendIsSubtractedEvenIfAccountChangedMidFlight() async {
        let client = MockStatsClient()
        let store = makeStore(client: client)
        store.record(videoId: UUID(), timeCutSeconds: 30, rallyCount: 3)
        // The user signs out while the increment is in flight; the server
        // still applied it to u1.
        client.beforeResponding = { store.signOut() }

        await store.signIn(userId: "u1")

        XCTAssertEqual(store.pendingRallies, 0, "A confirmed increment must leave pending")
        XCTAssertEqual(store.totalRallies, 0, "u1's totals aren't shown once signed out")

        await store.signIn(userId: "u2")
        XCTAssertEqual(client.addCalls.count, 1, "The confirmed increment must not be credited again to the next account")
    }

    func testLostResponseResendsSameBatchWithoutDoubleCredit() async {
        let client = MockStatsClient()
        let store = makeStore(client: client)
        store.record(videoId: UUID(), timeCutSeconds: 30, rallyCount: 3)
        client.loseResponses = true

        await store.signIn(userId: "u1")
        XCTAssertEqual(client.serverStats.ralliesFound, 3, "The server applied it...")
        XCTAssertEqual(store.pendingRallies, 3, "...but without a response it's still pending")

        client.loseResponses = false
        await store.flush()

        XCTAssertTrue(client.addCalls.allSatisfy { $0.rallies == 3 }, "Resends carry the same batch")
        XCTAssertEqual(client.serverStats.ralliesFound, 3, "A resent batch is applied once")
        XCTAssertEqual(store.pendingRallies, 0)
        XCTAssertEqual(store.totalRallies, 3)
    }

    func testUnconfirmedBatchSurvivesRelaunch() async {
        let client = MockStatsClient()
        let store = makeStore(client: client)
        store.record(videoId: UUID(), timeCutSeconds: 30, rallyCount: 3)
        client.loseResponses = true
        await store.signIn(userId: "u1")

        client.loseResponses = false
        let relaunched = makeStore(client: client)
        XCTAssertEqual(relaunched.pendingRallies, 3)
        await relaunched.signIn(userId: "u1")
        XCTAssertEqual(client.serverStats.ralliesFound, 3)
        XCTAssertEqual(relaunched.pendingRallies, 0)
    }

    // MARK: - Seeding

    func testSeedAddsToPendingOnce() {
        let client = MockStatsClient()
        let store = makeStore(client: client)
        let a = UUID(), b = UUID()

        store.seedIfNeeded(from: [(a, 100, 4), (b, 50, 2)])
        store.seedIfNeeded(from: [(UUID(), 999, 99)]) // second call ignored

        XCTAssertTrue(store.hasSeeded)
        XCTAssertEqual(store.totalRallies, 6)
        XCTAssertEqual(store.totalTimeCutSeconds, 150, accuracy: 0.001)
        // Seeded videos are counted: re-recording one is a no-op.
        store.record(videoId: a, timeCutSeconds: 100, rallyCount: 4)
        XCTAssertEqual(store.totalRallies, 6)
    }
}

// MARK: - Mock client

private final class MockStatsClient: APIClient, @unchecked Sendable {
    nonisolated(unsafe) var serverStats = UserStats(userId: "u1", ralliesFound: 0, timeCutSeconds: 0)
    nonisolated(unsafe) var addCalls: [(rallies: Int, timeCut: Double)] = []
    nonisolated(unsafe) var shouldFail = false
    nonisolated(unsafe) var appliedBatches: Set<UUID> = []
    /// Apply increments, then fail as if the response never arrived.
    nonisolated(unsafe) var loseResponses = false
    /// Runs after the increment is applied, before the response returns.
    nonisolated(unsafe) var beforeResponding: (@MainActor () async -> Void)?

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        if shouldFail { throw APIError.networkUnavailable }
        switch endpoint {
        case .getMyStats:
            guard let cast = serverStats as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        case .addMyStats(let rallies, let timeCut, let batchId):
            addCalls.append((rallies, timeCut))
            // Like the server: a resent batch is applied once.
            if appliedBatches.insert(batchId).inserted {
                serverStats = UserStats(
                    userId: serverStats.userId,
                    ralliesFound: serverStats.ralliesFound + rallies,
                    timeCutSeconds: serverStats.timeCutSeconds + timeCut
                )
            }
            if loseResponses {
                throw APIError.networkUnavailable
            }
            if let beforeResponding {
                self.beforeResponding = nil
                await beforeResponding()
            }
            guard let cast = serverStats as? T else { throw APIError.serverError(statusCode: 500, message: "cast") }
            return cast
        default:
            throw APIError.serverError(statusCode: 501, message: "not used")
        }
    }

    func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }

    func submitFlywheelContribution(_ contribution: FlywheelContribution, frameURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }
}
