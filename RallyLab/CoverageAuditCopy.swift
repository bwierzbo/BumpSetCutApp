//
//  CoverageAuditCopy.swift
//  RallyLab
//
//  What the Audit tab plays for a recording too heavy for this Mac to play at the audit's speeds. A 4K original
//  at 60 frames a second decodes here at about 2.2× real time (measured on bch_extra_self_04, an M3 Pro): at 2×
//  it stutters and at 3× it drops frames. For such a recording the tab plays a small copy instead — the one the
//  phone gets, kept in this Mac's caches, and used only when its frames are the original's, time for time
//  (FrameIdentity, the check the phone makes before it plays a copy: D-039). The copy is taken from the labeling
//  bucket when the sync has published one (seconds), else made here (LabelingSync.encodeSmallCopy: about as long
//  as the recording lasts, on every core). The original is still what the audit admits and what its record
//  names; only the picture on screen is the copy.
//

import AVFoundation
import Foundation

struct CoverageAuditCopy: Sendable {
    /// Puts the copy the sync published for a recording at `out`; false when there is none to take.
    typealias Fetch = @Sendable (_ recordingId: String, _ project: String, _ out: URL) async -> Bool

    /// Where the copies are kept.
    var directory: URL
    var fetch: Fetch = CoverageAuditCopy.fetchPublished
    var encode: LabelingSync.SmallCopy = LabelingSync.encodeSmallCopy

    static let app = CoverageAuditCopy(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RallyLab/coverage-audit-copies", isDirectory: true))

    static let fetchPublished: Fetch = { recordingId, project, out in
        let client = LabelingClient.shared
        guard await client.hasSession,
              let link = try? await client.signedURL(for: LabelingSync.copyPath(of: recordingId, in: project)) else { return false }
        return (try? await client.downloadPublic(link, to: out)) != nil
    }

    /// More picture a second than 4K at 30 frames a second: at 3× that is past what the Mac measured above decodes.
    static func isHeavy(width: Double, height: Double, framesPerSecond: Double) -> Bool {
        width * height * framesPerSecond > 3840 * 2160 * 30 * 1.01
    }

    /// False when the file's picture cannot be read: it is then played as it is.
    static func isHeavy(_ url: URL) async -> Bool {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, rate) = try? await track.load(.naturalSize, .nominalFrameRate) else { return false }
        return isHeavy(width: size.width, height: size.height, framesPerSecond: Double(rate))
    }

    /// The copy of the original with this content fingerprint, and beside it the original's frame identity it was
    /// checked against when it was kept.
    func url(for fingerprint: String) -> URL {
        directory.appendingPathComponent("\(DatasetStore.safeName(fingerprint))-v\(LabelingSync.copyVersion).mp4")
    }

    private func identityURL(for fingerprint: String) -> URL { url(for: fingerprint).appendingPathExtension("frames") }

    /// The copy to play, if one is kept and its frames are still the ones it was checked for (a damaged or
    /// half-written file is not played).
    func ready(for fingerprint: String) async -> URL? {
        let copy = url(for: fingerprint)
        guard FileManager.default.fileExists(atPath: copy.path),
              let digest = try? String(contentsOf: identityURL(for: fingerprint), encoding: .utf8), !digest.isEmpty,
              await LabelingSync.copy(copy, reproduces: digest) else { return nil }
        return copy
    }

    enum Outcome: Equatable {
        /// The original plays well enough as it is.
        case notNeeded
        case made(URL)
        case failed(String)
    }

    /// What a copy is of.
    struct Source: Sendable {
        var original: URL
        var fingerprint: String
        var recordingId: String
        var project: String
    }

    /// Gets the copy of a heavy original and keeps it only if its frames are the original's. `started` is told
    /// once it is known a copy is wanted.
    func make(_ source: Source, started: @Sendable () async -> Void = {}) async -> Outcome {
        guard await Self.isHeavy(source.original) else { return .notNeeded }
        await started()
        return await makeCopy(source)
    }

    /// The published copy if its frames are the original's, else one made here, held to the same.
    func makeCopy(_ source: Source) async -> Outcome {
        let work = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let digest = FrameIdentity.digest(of: try await FrameIdentity.allFrameTimes(of: source.original))
            var published = await fetch(source.recordingId, source.project, work)
            if published { published = await LabelingSync.copy(work, reproduces: digest) }
            if !published {
                try? FileManager.default.removeItem(at: work)
                try await encode(source.original, work)
                guard await LabelingSync.copy(work, reproduces: digest) else {
                    return .failed("its small copy does not have the original's frames, so the original is played")
                }
            }
            let copy = url(for: source.fingerprint)
            try? FileManager.default.removeItem(at: identityURL(for: source.fingerprint))
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.moveItem(at: work, to: copy)
            try digest.write(to: identityURL(for: source.fingerprint), atomically: true, encoding: .utf8)
            return .made(copy)
        } catch {
            return .failed("no small copy could be made (\(error.localizedDescription)), so the original is played")
        }
    }
}
