//
//  CourtReview.swift
//  RallyLab
//
//  A person's review of court membership (research P2): a fresh sample of a run's
//  frames, each with every detected person's box and track number drawn — and no
//  zones, lanes or courts, so nothing suggests an answer — and two sheets the person
//  fills in: what each detected person is (persons.csv) and how many players the
//  detector missed on each half (frames.csv). `--player-lab-court … --review <dir>`
//  then scores every court source (the net lane, each unconfirmed proposal, the
//  person-confirmed court) against those labels. Only rows a person filled count, and
//  the sheet's `reviewer` column says who; nothing here fills a label.
//
//  Writes only `<experiment>/court-reviews/<name>/`.
//

import AVFoundation
import CoreGraphics
import Foundation

enum CourtReview {
    /// What a reviewer may say a detected person is.
    enum Label: String, CaseIterable, Sendable {
        case nearCourt = "near_court", farCourt = "far_court"
        case nearServer = "near_serving_area", farServer = "far_serving_area"
        /// A player of this game outside the court and serving areas (chasing a ball, between rallies at the side).
        case playerOffCourt = "player_off_court"
        case spectator, adjacentCourt = "adjacent_court", other = "referee_or_other"
        /// An extra piece of a player already boxed (a tile seam), or not a person.
        case duplicate = "duplicate_or_not_a_person"
        case unsure

        var isPlayer: Bool { [.nearCourt, .farCourt, .nearServer, .farServer, .playerOffCourt].contains(self) }
        var isNotPlaying: Bool { [.spectator, .adjacentCourt, .other].contains(self) }
        /// The zone a correct court gives this person, when one is defined.
        var zone: CourtZone? {
            switch self {
            case .nearCourt: return .nearCourt
            case .farCourt: return .farCourt
            case .nearServer: return .nearServingArea
            case .farServer: return .farServingArea
            case .playerOffCourt, .spectator, .adjacentCourt, .other: return .outsideCourt
            case .duplicate, .unsure: return nil
            }
        }
    }

    static let personsHeader = "recording,interval,tick,t,image,track,box_x,box_y,box_w,box_h,label,reviewer,notes"
    static let framesHeader = "recording,interval,tick,t,image,missed_near_players,missed_far_players,reviewer,notes"

    /// `count` analysed frames spread evenly over the recording's frames, none within 2 s of an `avoid` tick.
    static func sample(_ frames: [PlayerFeatures.Frame], count: Int, avoid: Set<Int>) -> [PlayerFeatures.Frame] {
        let pool = frames.filter { f in f.masks.ran && !f.persons.isEmpty && !avoid.contains { abs($0 - f.tick) < 2 * PlayerFeatures.timescale } }
        guard count > 0, !pool.isEmpty else { return [] }
        let n = min(count, pool.count)
        return (0..<n).map { pool[(2 * $0 + 1) * pool.count / (2 * n)] }
    }

    /// Writes the review folder for a run: pictures, the two sheets (labels blank), and how to fill them.
    static func make(experiment: URL, runName: String, name: String, perRecording: Int, avoid: [String: Set<Int>],
                     log: @escaping (String) -> Void) async throws -> URL {
        guard RallyClassifierExporter.isSafeName(name) else { throw CourtPilot.Failure.badName(name) }
        let runDir = experiment.appendingPathComponent("runs/\(runName)", isDirectory: true)
        guard let data = try? Data(contentsOf: runDir.appendingPathComponent("features/player-features-manifest.json")) else { throw CourtPilot.Failure.noRun(runDir.path) }
        let manifest = try JSONDecoder().decode(PlayerFeatures.Manifest.self, from: data)
        let out = experiment.appendingPathComponent("court-reviews/\(name)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: out.path) else { throw CourtPilot.Failure.exists(out.path) }
        try FileManager.default.createDirectory(at: out.appendingPathComponent("frames"), withIntermediateDirectories: true)
        var persons = [personsHeader], frameRows = [framesHeader]
        for rec in manifest.recordings {
            guard let footage = PlayerFeaturesRun.decodedFootage(experiment, rec.recordingId, fingerprint: rec.decoded.fingerprint) else {
                log("⚠️ \(rec.recordingId): the run's footage copy isn't in the experiment — skipped"); continue
            }
            let lines = try Data(contentsOf: runDir.appendingPathComponent("features").appendingPathComponent(rec.framesFile))
            let frames = try lines.split(separator: 0x0A).map { try JSONDecoder().decode(PlayerFeatures.Frame.self, from: Data($0)) }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: footage))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            for f in sample(frames, count: perRecording, avoid: avoid[rec.recordingId] ?? []) {
                guard let image = try? await gen.image(at: CMTime(seconds: f.t, preferredTimescale: 600)).image else { continue }
                // Boxes and track numbers only: no court, lane, zone or membership on the picture.
                var o = PlayerOverlay.Options()
                o.skeletons = false; o.unmatchedPoses = false; o.net = false; o.lane = false; o.court = false; o.courtLabels = false
                guard let composed = PlayerOverlay.compose(image, frame: f, recording: rec.recordingId, net: nil, lane: nil, options: o,
                                                           zones: f.persons.map { _ in nil }),
                      let jpeg = PlayerOverlay.jpeg(composed) else { continue }
                let path = "frames/\(rec.recordingId)_\(f.tick).jpg"
                try jpeg.write(to: out.appendingPathComponent(path))
                let t = String(format: "%.3f", f.t)
                frameRows.append([rec.recordingId, f.interval, "\(f.tick)", t, path, "", "", "", ""].joined(separator: ","))
                for p in f.persons {
                    persons.append([rec.recordingId, f.interval, "\(f.tick)", t, path, "\(p.track)", String(format: "%.4f", p.box.x), String(format: "%.4f", p.box.y),
                                    String(format: "%.4f", p.box.w), String(format: "%.4f", p.box.h), "", "", ""].joined(separator: ","))
                }
            }
            log("   \(rec.recordingId): review frames written")
        }
        try Data((persons.joined(separator: "\n") + "\n").utf8).write(to: out.appendingPathComponent("persons.csv"))
        try Data((frameRows.joined(separator: "\n") + "\n").utf8).write(to: out.appendingPathComponent("frames.csv"))
        let readme = """
        Court-membership review — run \(runName)

        Each picture shows every person the detector found, boxed and numbered (#track). No court or zone is drawn.

        persons.csv — one row per numbered box. Fill `label` with one of:
          \(Label.allCases.map(\.rawValue).joined(separator: ", "))
          near_court / far_court: a player of this game standing on that half (the half nearer / farther than the net)
          near_serving_area / far_serving_area: a player behind that end line (serving or about to)
          player_off_court: a player of this game outside the court and serving areas
          spectator, adjacent_court, referee_or_other: not a player of this game
          duplicate_or_not_a_person: a second box on a player already boxed, or not a person
          unsure: can't tell
        and `reviewer` with your name. Leave a row blank to skip it.

        frames.csv — one row per picture: how many players of this game on the near / far half have no box at all.

        Then: RallyLab --player-lab-court <experiment> --run \(runName) --report <name> --review <this folder>
        """
        try Data(readme.utf8).write(to: out.appendingPathComponent("README.txt"))
        return out
    }

    // MARK: - Scoring

    struct PersonLabel: Equatable { var label: Label; var reviewer: String }

    /// The filled rows of a review folder: (recording, tick, track) → label; (recording, tick) → missed near/far.
    static func read(_ dir: URL) throws -> (persons: [String: PersonLabel], missed: [String: (near: Int, far: Int, reviewer: String)]) {
        func rows(_ file: String) throws -> [[String: String]] {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let lines = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            guard let head = lines.first else { return [] }
            return lines.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(head, $0 + Array(repeating: "", count: max(0, head.count - $0.count)))) }
        }
        var persons: [String: PersonLabel] = [:]
        for r in try rows("persons.csv") {
            let raw = (r["label"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            guard let l = Label(rawValue: raw) else { throw CourtCalibrationError.invalid(["persons.csv: unknown label \(raw)"]) }
            persons["\(r["recording"] ?? "")|\(r["tick"] ?? "")|\(r["track"] ?? "")"] = PersonLabel(label: l, reviewer: r["reviewer"] ?? "")
        }
        var missed: [String: (near: Int, far: Int, reviewer: String)] = [:]
        for r in try rows("frames.csv") {
            guard let n = Int(r["missed_near_players"] ?? ""), let f = Int(r["missed_far_players"] ?? "") else { continue }
            missed["\(r["recording"] ?? "")|\(r["tick"] ?? "")"] = (n, f, r["reviewer"] ?? "")
        }
        return (persons, missed)
    }

    struct Score: Codable, Equatable {
        var source: String
        var confirmed: Bool
        var labelled: Int
        /// Players on a court half: the zone is the right half.
        var halfCorrect: Int, halfTotal: Int
        /// Players on a court half or serving area: the exact zone is right.
        var zoneCorrect: Int, zoneTotal: Int
        /// Not players of this game (spectators, next court, referees) counted in play.
        var falseIn: Int, notPlayingTotal: Int
        /// Players on the court or in a serving area counted out, and counted unknown.
        var playersOut: Int, playersUnknown: Int, playersTotal: Int
        /// Servers (serving-area labels) counted outside.
        var serversOut: Int, serversTotal: Int
        /// Extra boxes (duplicates) counted in play.
        var duplicatesIn: Int, duplicatesTotal: Int
        /// Labelled persons whose zone was uncertain.
        var uncertain: Int
    }

    /// Scores one source over labelled persons. `zone(i, j)`: the source's zone for frame i, person j (nil: none), and
    /// `membership(i, j)`: its in/out/unknown.
    static func score(source: String, confirmed: Bool, frames: [PlayerFeatures.Frame], recording: String, labels: [String: PersonLabel],
                      zone: (Int, Int) -> PersonZone?, membership: (Int, Int) -> PlayerFeatures.CourtMembership) -> Score {
        var s = Score(source: source, confirmed: confirmed, labelled: 0, halfCorrect: 0, halfTotal: 0, zoneCorrect: 0, zoneTotal: 0, falseIn: 0, notPlayingTotal: 0,
                      playersOut: 0, playersUnknown: 0, playersTotal: 0, serversOut: 0, serversTotal: 0, duplicatesIn: 0, duplicatesTotal: 0, uncertain: 0)
        for (i, f) in frames.enumerated() {
            for (j, p) in f.persons.enumerated() {
                guard let l = labels["\(recording)|\(f.tick)|\(p.track)"]?.label, l != .unsure else { continue }
                s.labelled += 1
                let z = zone(i, j), m = membership(i, j)
                if z?.uncertain == true { s.uncertain += 1 }
                if l == .duplicate { s.duplicatesTotal += 1; if m == .inside { s.duplicatesIn += 1 }; continue }
                if l.isNotPlaying { s.notPlayingTotal += 1; if m == .inside { s.falseIn += 1 } }
                if [.nearCourt, .farCourt, .nearServer, .farServer].contains(l) {
                    s.playersTotal += 1
                    if m == .outside { s.playersOut += 1 } else if m == .unknown { s.playersUnknown += 1 }
                    if let z, let want = l.zone { s.zoneTotal += 1; if z.zone == want { s.zoneCorrect += 1 } }
                }
                if [.nearCourt, .farCourt].contains(l), let z {
                    s.halfTotal += 1
                    let near = z.zone == .nearCourt || z.zone == .nearServingArea, far = z.zone == .farCourt || z.zone == .farServingArea
                    if (l == .nearCourt && near) || (l == .farCourt && far) { s.halfCorrect += 1 }
                }
                if [.nearServer, .farServer].contains(l) { s.serversTotal += 1; if m == .outside { s.serversOut += 1 } }
            }
        }
        return s
    }

    /// Near/far detection over the reviewed frames: boxed players (labelled on a half or serving area, not duplicates)
    /// and the players the reviewer counted as missed.
    struct Detection: Codable, Equatable { var frames: Int; var nearFound: Int; var nearMissed: Int; var farFound: Int; var farMissed: Int }

    static func detection(frames: [PlayerFeatures.Frame], recording: String, labels: [String: PersonLabel],
                          missed: [String: (near: Int, far: Int, reviewer: String)]) -> Detection {
        var d = Detection(frames: 0, nearFound: 0, nearMissed: 0, farFound: 0, farMissed: 0)
        for f in frames {
            guard let m = missed["\(recording)|\(f.tick)"] else { continue }
            d.frames += 1
            d.nearMissed += m.near; d.farMissed += m.far
            for p in f.persons {
                switch labels["\(recording)|\(f.tick)|\(p.track)"]?.label {
                case .nearCourt?, .nearServer?: d.nearFound += 1
                case .farCourt?, .farServer?: d.farFound += 1
                default: break
                }
            }
        }
        return d
    }
}
