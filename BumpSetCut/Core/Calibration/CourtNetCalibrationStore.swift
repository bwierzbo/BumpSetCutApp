//
//  CourtNetCalibrationStore.swift
//  BumpSetCut
//
//  One calibration file per recording, "<recordingId>_calibration.json" in a directory the
//  caller names. Read whole, checked, written atomically. A file that exists but can't be
//  read or is malformed is an error, never an empty calibration, and is never written
//  over. A save that would lose a confirmation already on file is refused; a file made for
//  another video under the same id is set aside, not replaced.
//

import Foundation

struct CourtNetCalibrationStore {
    let directory: URL
    /// How the encoded file reaches the disk: atomically. A test puts a failing write here.
    var write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }

    func url(_ recordingId: String) -> URL { directory.appendingPathComponent("\(recordingId)_calibration.json") }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    /// The recording's file; nil when there is none. Throws when one exists that can't be read or is malformed.
    func load(_ recordingId: String) throws -> CourtNetCalibrationFile? {
        guard CourtNetCalibrationFile.isSafeId(recordingId) else { throw CourtNetCalibrationError.invalid(["the recording id can't name a file"]) }
        let u = url(recordingId)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let file: CourtNetCalibrationFile
        do { file = try Self.decoder.decode(CourtNetCalibrationFile.self, from: Data(contentsOf: u)) } catch {
            throw CourtNetCalibrationError.unreadable(error.localizedDescription)
        }
        guard file.recordingId == recordingId else { throw CourtNetCalibrationError.invalid(["the file is for \(file.recordingId)"]) }
        let problems = file.problems
        guard problems.isEmpty else { throw CourtNetCalibrationError.invalid(problems) }
        return file
    }

    func save(_ file: CourtNetCalibrationFile) throws {
        let problems = file.problems
        guard problems.isEmpty else { throw CourtNetCalibrationError.invalid(problems) }
        let live = url(file.recordingId)
        // Encoded before anything on disk moves: a file that can't be written leaves what is there untouched.
        let data = try Self.encoder.encode(file)
        var setAside: URL?
        if let onFile = try load(file.recordingId) {
            if onFile.staleReason(for: file.binding) != nil {
                let aside = supersededURL(file.recordingId)
                try FileManager.default.moveItem(at: live, to: aside)
                setAside = aside
            } else if !Self.keepsConfirmations(of: onFile, in: file) {
                throw CourtNetCalibrationError.wouldDropConfirmation
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(data, live)
        } catch {
            // The replacement didn't land: the file that was set aside is the recording's calibration again.
            if let setAside { try? FileManager.default.moveItem(at: setAside, to: live) }
            throw error
        }
    }

    /// Where a file made for another video is set aside: beside the live one, under the recording's id.
    private func supersededURL(_ recordingId: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        var n = 0
        while true {
            let u = directory.appendingPathComponent("\(recordingId)_calibration.superseded-\(stamp)\(n == 0 ? "" : "-\(n)").json")
            if !FileManager.default.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    /// Whether every confirmation old holds, in force or in history, is still somewhere in new.
    private static func keepsConfirmations(of old: CourtNetCalibrationFile, in new: CourtNetCalibrationFile) -> Bool {
        func all<G>(_ f: CourtNetCalibrationFile, _ part: KeyPath<CalibrationSegment, CalibrationPart<G>>) -> [CalibrationConfirmation<G>] {
            f.segments.flatMap { [$0[keyPath: part].confirmation].compactMap { $0 } + $0[keyPath: part].history }
        }
        func kept<G>(_ part: KeyPath<CalibrationSegment, CalibrationPart<G>>) -> Bool {
            var remaining = all(new, part)
            for c in all(old, part) {
                guard let i = remaining.firstIndex(of: c) else { return false }
                remaining.remove(at: i)
            }
            return true
        }
        return kept(\.court) && kept(\.net)
    }

    /// What a reader may use for the video as it is now.
    enum Lookup: Equatable {
        case none
        case usable(CourtNetCalibrationFile)
        /// On file, but for another file, frame or length: shown, never used.
        case stale(CourtNetCalibrationFile, reason: String)
        case unreadable(String)
    }

    func lookup(for b: CourtNetCalibrationFile.Binding) -> Lookup {
        do {
            guard let f = try load(b.recordingId) else { return .none }
            if let why = f.staleReason(for: b) { return .stale(f, reason: why) }
            return .usable(f)
        } catch { return .unreadable(error.localizedDescription) }
    }
}
