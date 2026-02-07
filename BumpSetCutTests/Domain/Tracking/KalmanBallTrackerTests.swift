//
//  KalmanBallTrackerTests.swift
//  BumpSetCutTests
//
//  Tests for KalmanBallTracker sorted-distance track association.
//  Verifies correct assignment when multiple detections compete for tracks.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

final class KalmanBallTrackerTests: XCTestCase {

    private var config: ProcessorConfig!

    override func setUp() {
        super.setUp()
        config = ProcessorConfig()
    }

    override func tearDown() {
        config = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func time(_ seconds: Double) -> CMTime {
        CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
    }

    /// Create a DetectionResult with a small bbox centered at `center`.
    private func detection(at center: CGPoint, time t: CMTime) -> DetectionResult {
        let size: CGFloat = 0.02
        let bbox = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        return DetectionResult(bbox: bbox, confidence: 0.9, timestamp: t)
    }

    /// Seed a tracker with existing tracks by feeding detections at known positions.
    /// Each position gets its own frame time (0.0, 0.033, 0.066, ...) to build up
    /// a short track history so the Kalman filter has meaningful state.
    private func seededTracker(positions: [CGPoint], framesPerTrack: Int = 3) -> KalmanBallTracker {
        let tracker = KalmanBallTracker(config: config)
        let dt = 1.0 / 30.0

        for frameIdx in 0..<framesPerTrack {
            let t = time(Double(frameIdx) * dt)
            // Feed all positions as simultaneous detections each frame
            // so that each position becomes a separate track
            let dets = positions.map { detection(at: $0, time: t) }
            tracker.update(with: dets)
        }
        return tracker
    }

    // MARK: - 1. Single detection, no existing tracks -> creates new track

    func testSingleDetectionNoTrack_CreatesNewTrack() {
        let tracker = KalmanBallTracker(config: config)
        let det = detection(at: CGPoint(x: 0.5, y: 0.5), time: time(0.0))

        tracker.update(with: [det])

        XCTAssertEqual(tracker.tracks.count, 1, "Should create exactly one track")
        let track = tracker.tracks[0]
        XCTAssertEqual(track.age, 1, "New track should have age 1")
    }

    // MARK: - 2. Single detection, single track -> updates existing (regression safety)

    func testSingleDetectionSingleTrack_UpdatesExisting() {
        let tracker = seededTracker(positions: [CGPoint(x: 0.5, y: 0.5)])
        let initialTrackCount = tracker.tracks.count
        XCTAssertEqual(initialTrackCount, 1, "Should start with 1 track")

        let initialAge = tracker.tracks[0].age

        // Feed a detection near the existing track
        let det = detection(at: CGPoint(x: 0.51, y: 0.51), time: time(0.2))
        tracker.update(with: [det])

        XCTAssertEqual(tracker.tracks.count, 1, "Should still have exactly 1 track (no new track created)")
        XCTAssertEqual(tracker.tracks[0].age, initialAge + 1, "Existing track should be updated")
    }

    // MARK: - 3. Two detections, two tracks -> correct assignment regardless of order

    func testTwoDetectionsTwoTracks_CorrectAssignment() {
        // Create two tracks far apart: A at left, B at right
        let posA = CGPoint(x: 0.2, y: 0.5)
        let posB = CGPoint(x: 0.8, y: 0.5)
        let tracker = seededTracker(positions: [posA, posB])
        XCTAssertEqual(tracker.tracks.count, 2, "Should have 2 tracks")

        let ageA = tracker.tracks[0].age
        let ageB = tracker.tracks[1].age

        // Key test: det0 is listed first but is closer to track B (right side).
        // det1 is listed second but is closer to track A (left side).
        // With old greedy code iterating det0 first, det0 could steal track A.
        // Sorted assignment should assign det0->B and det1->A correctly.
        let det0 = detection(at: CGPoint(x: 0.78, y: 0.5), time: time(0.2)) // near B
        let det1 = detection(at: CGPoint(x: 0.22, y: 0.5), time: time(0.2)) // near A

        tracker.update(with: [det0, det1])

        XCTAssertEqual(tracker.tracks.count, 2, "Should still have exactly 2 tracks")
        XCTAssertEqual(tracker.tracks[0].age, ageA + 1, "Track A should be updated")
        XCTAssertEqual(tracker.tracks[1].age, ageB + 1, "Track B should be updated")

        // Verify correct assignment: track A's last position should be near det1, not det0
        if let lastA = tracker.tracks[0].positions.last?.0 {
            let distToDet1 = hypot(lastA.x - 0.22, lastA.y - 0.5)
            let distToDet0 = hypot(lastA.x - 0.78, lastA.y - 0.5)
            XCTAssertLessThan(distToDet1, distToDet0,
                              "Track A should have been updated with det1 (the closer one), not det0")
        }

        if let lastB = tracker.tracks[1].positions.last?.0 {
            let distToDet0 = hypot(lastB.x - 0.78, lastB.y - 0.5)
            let distToDet1 = hypot(lastB.x - 0.22, lastB.y - 0.5)
            XCTAssertLessThan(distToDet0, distToDet1,
                              "Track B should have been updated with det0 (the closer one), not det1")
        }
    }

    // MARK: - 4. Two detections, one track -> closer claims track, farther starts new

    func testTwoDetectionsOneTrack_CloserClaimsTrack() {
        let tracker = seededTracker(positions: [CGPoint(x: 0.5, y: 0.5)])
        XCTAssertEqual(tracker.tracks.count, 1)
        let initialAge = tracker.tracks[0].age

        // Two detections: one close, one far
        let closeDet = detection(at: CGPoint(x: 0.51, y: 0.51), time: time(0.2))
        let farDet = detection(at: CGPoint(x: 0.9, y: 0.9), time: time(0.2))

        // Put far detection first in array to test ordering independence
        tracker.update(with: [farDet, closeDet])

        // The close detection should claim the existing track
        XCTAssertGreaterThanOrEqual(tracker.tracks.count, 2,
                                     "Far detection should start a new track")
        XCTAssertEqual(tracker.tracks[0].age, initialAge + 1,
                       "Original track should be updated by the closer detection")
    }

    // MARK: - 5. Two tracks, two equidistant detections -> both get assigned

    func testEquidistantDetections_BothAssigned() {
        // Two tracks symmetrically placed
        let tracker = seededTracker(positions: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        XCTAssertEqual(tracker.tracks.count, 2)

        let ageA = tracker.tracks[0].age
        let ageB = tracker.tracks[1].age

        // Two detections, each clearly closest to one track
        let detNearA = detection(at: CGPoint(x: 0.31, y: 0.5), time: time(0.2))
        let detNearB = detection(at: CGPoint(x: 0.71, y: 0.5), time: time(0.2))

        tracker.update(with: [detNearA, detNearB])

        XCTAssertEqual(tracker.tracks.count, 2, "No new tracks should be created")
        XCTAssertEqual(tracker.tracks[0].age, ageA + 1, "Track A should be updated")
        XCTAssertEqual(tracker.tracks[1].age, ageB + 1, "Track B should be updated")
    }
}
