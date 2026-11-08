//
//  PlayerFeaturesSummary.swift
//  RallyLab
//
//  One interval's numbers and its tracks' lifespans, computed from the frame lines only
//  (the model's own output; detection accuracy comes only from the filled audit sheet).
//  The run writes them to diagnostics/summary.json and the Player Lab window shows the same
//  values, so the report and the GUI never disagree.
//

import Foundation

enum PlayerFeaturesSummary {
    struct Stats: Codable, Equatable, Sendable {
        var recording = "", interval = "", kind = ""
        var frames = 0, analysed = 0, tracks = 0, confirmed = 0, tentativeOnly = 0
        var personsPerFrame: Double?, inCourtPerFrame: Double?, poseShare: Double?, jointsPerPose: Double?, jointConfMean: Double?
        var unmatchedPerFrame: Double?, ambiguousShare: Double?, confirmedLengthMean: Double?, boxHeightMedian: Double?
        var meanSpeedInCourt: Double?, movingShareInCourt: Double?, coherenceInCourt: Double?, armRaisedShare: Double?
        var frameDiffMedian: Double?, frameDiffP95: Double?
        var rectMsMedian: Double?, poseMsMedian: Double?
        var resets: [String: Int] = [:]
    }

    /// Where a track was seen in the interval, by frame index.
    struct TrackSpan: Identifiable, Equatable, Sendable {
        let id: Int
        var frames: [Int]
        var confirmedFrom: Int?
        var ambiguous: [Int]
    }

    static func quantile(_ v: [Double], _ q: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
    }

    private static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    static func stats(_ frames: [PlayerFeatures.Frame], laneKnown: Bool) -> Stats {
        var s = Stats()
        s.frames = frames.count
        let ran = frames.filter(\.masks.ran)
        s.analysed = ran.count
        for f in frames { if let r = f.reset { s.resets[r, default: 0] += 1 } }
        s.frameDiffMedian = quantile(frames.compactMap(\.frameDiff), 0.5)
        s.frameDiffP95 = quantile(frames.compactMap(\.frameDiff), 0.95)
        guard !ran.isEmpty else { return s }
        let persons = ran.flatMap(\.persons)
        s.personsPerFrame = Double(persons.count) / Double(ran.count)
        s.inCourtPerFrame = laneKnown ? Double(ran.map(\.scene.inCourt).reduce(0, +)) / Double(ran.count) : nil
        let poses = persons.compactMap(\.pose)
        s.poseShare = persons.isEmpty ? nil : Double(poses.count) / Double(persons.count)
        s.jointsPerPose = poses.isEmpty ? nil : Double(poses.map(\.reported).reduce(0, +)) / Double(poses.count)
        s.jointConfMean = mean(poses.flatMap { $0.joints.compactMap { $0?.c } })
        s.unmatchedPerFrame = Double(ran.map(\.unmatchedPoses.count).reduce(0, +)) / Double(ran.count)
        s.ambiguousShare = persons.isEmpty ? nil : Double(persons.filter(\.ambiguous).count) / Double(persons.count)
        s.boxHeightMedian = quantile(persons.map(\.box.h), 0.5)
        var seen: [Int: Int] = [:]
        var confirmed = Set<Int>()
        for p in persons {
            seen[p.track, default: 0] += 1
            if p.state == .confirmed { confirmed.insert(p.track) }
        }
        s.tracks = seen.count
        s.confirmed = confirmed.count
        s.tentativeOnly = seen.count - confirmed.count
        s.confirmedLengthMean = mean(confirmed.map { Double(seen[$0]!) })
        s.meanSpeedInCourt = mean(ran.compactMap(\.scene.meanSpeedInCourt))
        s.movingShareInCourt = mean(ran.compactMap(\.scene.movingShareInCourt))
        s.coherenceInCourt = mean(ran.compactMap(\.scene.coherenceInCourt))
        s.armRaisedShare = persons.isEmpty ? nil : Double(persons.filter { ($0.derived.armElevation ?? -1) > 0 }.count) / Double(persons.count)
        s.rectMsMedian = quantile(ran.compactMap { $0.ms["rect"] }, 0.5)
        s.poseMsMedian = quantile(ran.compactMap { $0.ms["pose"] }, 0.5)
        return s
    }

    static func tracks(_ frames: [PlayerFeatures.Frame]) -> [TrackSpan] {
        var byId: [Int: TrackSpan] = [:]
        for (i, f) in frames.enumerated() {
            for p in f.persons {
                var t = byId[p.track] ?? TrackSpan(id: p.track, frames: [], confirmedFrom: nil, ambiguous: [])
                t.frames.append(i)
                if p.state == .confirmed, t.confirmedFrom == nil { t.confirmedFrom = i }
                if p.ambiguous { t.ambiguous.append(i) }
                byId[p.track] = t
            }
        }
        return byId.values.sorted { $0.id < $1.id }
    }

    /// Every interval of a recording, in order.
    static func recording(_ rec: PlayerFeatures.Recording, frames: [PlayerFeatures.Frame]) -> [Stats] {
        rec.intervals.map { iv in
            var s = stats(frames.filter { $0.interval == iv.name }, laneKnown: rec.courtUnknownReason == nil)
            s.recording = rec.recordingId
            s.interval = iv.name
            s.kind = iv.kind.rawValue
            return s
        }
    }
}
