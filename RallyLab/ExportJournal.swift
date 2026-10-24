//
//  ExportJournal.swift
//  RallyLab
//
//  The journal of a multi-frame export: what run this is (its frozen identity
//  — settings, sources, planned moments) and which frames have been written
//  whole, one line each, appended as they land. It lives beside the package
//  folder (`<package>.journal.jsonl`), never inside it, so the package holds
//  only what the preflight expects. A run that stops leaves the journal
//  without a closing state; a resumed run reads it, refuses to continue a
//  run whose identity differs from what it would export now, and trusts a
//  frame the journal names only after the file's bytes hash to what was
//  written. A torn last line (the write that was cut short) is ignored.
//
//  A frame the decoder could not produce and the export left out (an HEVC
//  leading picture, MultiFramePackage.Undecodable; D-025) is a line too,
//  with the error, the attempts and the reason: the omission is on record
//  where the frames are. The line type is new to this exporter build; a
//  journal that holds one is refused by an older build (unknown line type),
//  never resumed half-understood. The version stays 1: no existing line
//  changed, and a frame that decodes is written exactly as before.
//

import CryptoKit
import Foundation

enum ExportJournal {

    static let version = 1
    static func url(forPackage dir: URL) -> URL { URL(fileURLWithPath: dir.path + ".journal.jsonl") }

    /// Everything that decides which frame files an export produces. Two runs with the same
    /// identity write the same files; a run whose identity differs is another export.
    struct Identity: Codable, Equatable {
        struct Clip: Codable, Equatable {
            var name: String
            var split: String
            var sourcePath: String
            /// ProjectsModel.fileFingerprint of the video (size + head + tail), plus its exact size and modification date.
            var sourceFingerprint: String
            var sourceBytes: Int64
            var sourceModified: String
            /// SHA-256 of the rally-mark sidecar, when it affects the frames (dead-time windows); nil otherwise.
            var sidecarSha256: String?
            /// SHA-256 over the planned frame moments (sorted keys, one per line) and how many.
            var plannedKeysSha256: String
            var plannedKeys: Int
        }
        var exporter: String
        var longSide: Double
        var quality: Double
        var span: Int
        var frameRate: Double
        var trackStride: Int
        var deadStep: Double
        var deadMargin: Double
        var unreviewed: Bool
        var valOnly: Bool
        /// Whether pre-tracked rallies' sure frames were labels (MultiFramePackage `machineLabels`);
        /// false for a lineage package. Journals from before the field (every one was written
        /// with the model's labels allowed) read as true.
        var machineLabels: Bool
        /// The caller's own identity (a lineage package: manifest hashes, eligible and withheld closure).
        var extra: [String: String]
        var clips: [String: Clip]

        init(exporter: String, longSide: Double, quality: Double, span: Int, frameRate: Double, trackStride: Int, deadStep: Double,
             deadMargin: Double, unreviewed: Bool, valOnly: Bool, machineLabels: Bool = true, extra: [String: String], clips: [String: Clip]) {
            self.exporter = exporter; self.longSide = longSide; self.quality = quality; self.span = span; self.frameRate = frameRate
            self.trackStride = trackStride; self.deadStep = deadStep; self.deadMargin = deadMargin; self.unreviewed = unreviewed
            self.valOnly = valOnly; self.machineLabels = machineLabels; self.extra = extra; self.clips = clips
        }

        private enum CodingKeys: String, CodingKey {
            case exporter, longSide, quality, span, frameRate, trackStride, deadStep, deadMargin, unreviewed, valOnly, machineLabels, extra, clips
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exporter = try c.decode(String.self, forKey: .exporter); longSide = try c.decode(Double.self, forKey: .longSide)
            quality = try c.decode(Double.self, forKey: .quality); span = try c.decode(Int.self, forKey: .span)
            frameRate = try c.decode(Double.self, forKey: .frameRate); trackStride = try c.decode(Int.self, forKey: .trackStride)
            deadStep = try c.decode(Double.self, forKey: .deadStep); deadMargin = try c.decode(Double.self, forKey: .deadMargin)
            unreviewed = try c.decode(Bool.self, forKey: .unreviewed); valOnly = try c.decode(Bool.self, forKey: .valOnly)
            machineLabels = try c.decodeIfPresent(Bool.self, forKey: .machineLabels) ?? true
            extra = try c.decode([String: String].self, forKey: .extra); clips = try c.decode([String: Clip].self, forKey: .clips)
        }

        /// Each field that differs, named — for the refusal message and the record.
        func differences(from other: Identity) -> [String] {
            var out: [String] = []
            func cmp<T: Equatable>(_ name: String, _ a: T, _ b: T) { if a != b { out.append("\(name): journal \(b), now \(a)") } }
            cmp("exporter", exporter, other.exporter); cmp("longSide", longSide, other.longSide); cmp("quality", quality, other.quality)
            cmp("span", span, other.span); cmp("frameRate", frameRate, other.frameRate); cmp("trackStride", trackStride, other.trackStride)
            cmp("deadStep", deadStep, other.deadStep); cmp("deadMargin", deadMargin, other.deadMargin)
            cmp("unreviewed", unreviewed, other.unreviewed); cmp("valOnly", valOnly, other.valOnly); cmp("machineLabels", machineLabels, other.machineLabels)
            for key in Set(extra.keys).union(other.extra.keys).sorted() { cmp("extra.\(key)", extra[key] ?? "—", other.extra[key] ?? "—") }
            for key in Set(clips.keys).union(other.clips.keys).sorted() {
                guard let a = clips[key], let b = other.clips[key] else { out.append("clip \(key): \(clips[key] == nil ? "not planned now" : "not in the journal")"); continue }
                cmp("clip \(key).name", a.name, b.name); cmp("clip \(key).split", a.split, b.split); cmp("clip \(key).sourcePath", a.sourcePath, b.sourcePath)
                cmp("clip \(key).sourceFingerprint", a.sourceFingerprint, b.sourceFingerprint); cmp("clip \(key).sourceBytes", a.sourceBytes, b.sourceBytes)
                cmp("clip \(key).sourceModified", a.sourceModified, b.sourceModified); cmp("clip \(key).sidecarSha256", a.sidecarSha256 ?? "—", b.sidecarSha256 ?? "—")
                cmp("clip \(key).plannedKeysSha256", a.plannedKeysSha256, b.plannedKeysSha256); cmp("clip \(key).plannedKeys", a.plannedKeys, b.plannedKeys)
            }
            return out
        }
    }

    enum State: String, Codable {
        case inProgress = "in_progress"
        case interrupted
        case preflightFailed = "preflight_failed"
        case preflightPassed = "preflight_passed"
        case finalized
    }

    /// One line of the journal.
    enum Line: Codable, Equatable {
        case header(version: Int, package: String, startedAt: String, identity: Identity)
        case frame(clip: String, key: Int64, sha256: String, bytes: Int)
        /// A planned frame the decoder could not produce, left out with every window that needed it
        /// (MultiFramePackage.Undecodable): its moment in seconds, the decoder's error, how many
        /// times it was asked for before a fresh decoder was tried, how many consecutive frames the
        /// run of undecodable frames holds, and why that is accepted. `at`: when it was judged.
        case undecodable(clip: String, key: Int64, time: Double, error: String, attempts: Int, run: Int, reason: String, at: String)
        case clipComplete(clip: String, frames: Int)
        case state(State, at: String, note: String?)

        private enum CodingKeys: String, CodingKey {
            case type, version, package, startedAt, identity, clip, key, sha256, bytes, frames, state, at, note, time, error, attempts, run, reason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "header":
                self = .header(version: try c.decode(Int.self, forKey: .version), package: try c.decode(String.self, forKey: .package),
                               startedAt: try c.decode(String.self, forKey: .startedAt), identity: try c.decode(Identity.self, forKey: .identity))
            case "frame":
                self = .frame(clip: try c.decode(String.self, forKey: .clip), key: try c.decode(Int64.self, forKey: .key),
                              sha256: try c.decode(String.self, forKey: .sha256), bytes: try c.decode(Int.self, forKey: .bytes))
            case "undecodable":
                self = .undecodable(clip: try c.decode(String.self, forKey: .clip), key: try c.decode(Int64.self, forKey: .key),
                                    time: try c.decode(Double.self, forKey: .time), error: try c.decode(String.self, forKey: .error),
                                    attempts: try c.decode(Int.self, forKey: .attempts), run: try c.decode(Int.self, forKey: .run),
                                    reason: try c.decode(String.self, forKey: .reason), at: try c.decode(String.self, forKey: .at))
            case "clip":
                self = .clipComplete(clip: try c.decode(String.self, forKey: .clip), frames: try c.decode(Int.self, forKey: .frames))
            case "state":
                self = .state(try c.decode(State.self, forKey: .state), at: try c.decode(String.self, forKey: .at), note: try c.decodeIfPresent(String.self, forKey: .note))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown line type \(other)")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .header(let version, let package, let startedAt, let identity):
                try c.encode("header", forKey: .type); try c.encode(version, forKey: .version); try c.encode(package, forKey: .package)
                try c.encode(startedAt, forKey: .startedAt); try c.encode(identity, forKey: .identity)
            case .frame(let clip, let key, let sha256, let bytes):
                try c.encode("frame", forKey: .type); try c.encode(clip, forKey: .clip); try c.encode(key, forKey: .key)
                try c.encode(sha256, forKey: .sha256); try c.encode(bytes, forKey: .bytes)
            case .undecodable(let clip, let key, let time, let error, let attempts, let run, let reason, let at):
                try c.encode("undecodable", forKey: .type); try c.encode(clip, forKey: .clip); try c.encode(key, forKey: .key)
                try c.encode(time, forKey: .time); try c.encode(error, forKey: .error); try c.encode(attempts, forKey: .attempts)
                try c.encode(run, forKey: .run); try c.encode(reason, forKey: .reason); try c.encode(at, forKey: .at)
            case .clipComplete(let clip, let frames):
                try c.encode("clip", forKey: .type); try c.encode(clip, forKey: .clip); try c.encode(frames, forKey: .frames)
            case .state(let state, let at, let note):
                try c.encode("state", forKey: .type); try c.encode(state, forKey: .state); try c.encode(at, forKey: .at); try c.encodeIfPresent(note, forKey: .note)
            }
        }
    }

    /// What a journal on disk says, read back whole. `frames` holds every frame line that was
    /// written in full; `tornTail` says whether the last line was cut short.
    struct Contents: Equatable {
        var version: Int
        var package: String
        var startedAt: String
        var identity: Identity
        var frames: [String: [Int64: (sha256: String, bytes: Int)]]
        /// Frames a run judged undecodable and left out, by clip. On record; a resumed run asks the decoder again.
        var undecodable: [String: Set<Int64>] = [:]
        var completedClips: Set<String>
        var states: [State]
        var tornTail: Bool
        /// Bytes up to the end of the last whole line; what a resumed run appends after (the torn tail is cut off).
        var validLength: UInt64

        static func == (a: Contents, b: Contents) -> Bool {
            a.version == b.version && a.package == b.package && a.startedAt == b.startedAt && a.identity == b.identity
                && a.completedClips == b.completedClips && a.states == b.states && a.tornTail == b.tornTail && a.validLength == b.validLength
                && a.undecodable == b.undecodable
                && a.frames.keys == b.frames.keys && a.frames.allSatisfy { clip, map in
                    let o = b.frames[clip] ?? [:]
                    return map.keys == o.keys && map.allSatisfy { o[$0.key]?.sha256 == $0.value.sha256 && o[$0.key]?.bytes == $0.value.bytes }
                }
        }

        /// The last state written; a journal whose last word is `in_progress` (or nothing) was cut short.
        var state: State {
            let last = states.last ?? .inProgress
            return last == .inProgress ? .interrupted : last
        }
    }

    enum JournalError: LocalizedError, Equatable, ExportIO.Final {
        case unreadable(String, detail: String)
        case notAJournal(String, detail: String)
        case otherVersion(String, Int)
        case otherPackage(String, journal: String, folder: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let p, let d): return "The export journal \(p) can't be read (\(d))."
            case .notAJournal(let p, let d): return "\(p) is not an export journal (\(d)). Nothing is reused."
            case .otherVersion(let p, let v): return "\(p) is a version \(v) journal; this RallyLab writes version \(version). Nothing is reused."
            case .otherPackage(let p, let j, let f): return "\(p) belongs to package \(j), not \(f). Nothing is reused."
            }
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    static func encode(_ line: Line) throws -> Data {
        var data = try encoder.encode(line)
        data.append(0x0A)
        return data
    }

    /// Reads a journal. A trailing line without its newline, or one that does not parse, is the
    /// write that was cut short: it is dropped and reported, never trusted.
    static func read(_ url: URL, forPackage package: String) throws -> Contents {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw JournalError.unreadable(url.path, detail: error.localizedDescription) }
        var pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let tornTail = !(pieces.last?.isEmpty ?? true)   // data not ending in a newline
        if pieces.last?.isEmpty == true { pieces.removeLast() }
        let decoder = JSONDecoder()
        var lines: [Line] = []
        var torn = tornTail
        var validLength = UInt64(0)
        for (i, piece) in pieces.enumerated() {
            do {
                lines.append(try decoder.decode(Line.self, from: Data(piece)))
                if !(torn && i == pieces.count - 1) { validLength += UInt64(piece.count + 1) }
            } catch {
                // Only the last line may be torn; anything earlier is damage, not an interruption.
                guard i == pieces.count - 1 else { throw JournalError.notAJournal(url.path, detail: "line \(i + 1) does not parse") }
                torn = true
            }
        }
        guard case .header(let version, let name, let startedAt, let identity)? = lines.first else {
            throw JournalError.notAJournal(url.path, detail: "no header line")
        }
        guard version == Self.version else { throw JournalError.otherVersion(url.path, version) }
        guard name == package else { throw JournalError.otherPackage(url.path, journal: name, folder: package) }
        var contents = Contents(version: version, package: name, startedAt: startedAt, identity: identity, frames: [:], completedClips: [], states: [], tornTail: torn, validLength: validLength)
        for line in lines.dropFirst() {
            switch line {
            case .header: throw JournalError.notAJournal(url.path, detail: "a second header")
            case .frame(let clip, let key, let sha, let bytes): contents.frames[clip, default: [:]][key] = (sha, bytes)
            case .undecodable(let clip, let key, _, _, _, _, _, _): contents.undecodable[clip, default: []].insert(key)
            case .clipComplete(let clip, _): contents.completedClips.insert(clip)
            case .state(let s, _, _): contents.states.append(s)
            }
        }
        return contents
    }

    /// Appends lines as they come; `flush` syncs them to disk (after each clip, every state
    /// change, and every hundred frames). What is on disk is always a prefix of what was
    /// appended, so a crash loses at most the unflushed tail, whose frames are then proven by
    /// regeneration instead of by the journal.
    final class Writer {
        static let flushEvery = 100
        private var pending = 0
        let url: URL
        private var handle: FileHandle

        /// Starts a new journal (the file must not exist) with its header line, published whole:
        /// written beside the final name first and moved into place, so a header cut short never
        /// sits at the journal's path where a later resume would have to refuse it.
        init(creating url: URL, package: String, identity: Identity, now: Date) throws {
            self.url = url
            let fm = FileManager.default
            guard !fm.fileExists(atPath: url.path) else { throw JournalError.notAJournal(url.path, detail: "already exists") }
            let part = URL(fileURLWithPath: url.path + ExportIO.partialSuffix)
            try ExportJournal.encode(.header(version: ExportJournal.version, package: package, startedAt: Writer.stamp(now), identity: identity))
                .write(to: part, options: .atomic)
            do { try fm.moveItem(at: part, to: url) } catch {   // the move refuses an existing file: the no-overwrite rule holds
                try? fm.removeItem(at: part)
                throw error
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        }

        /// Continues an existing journal after its last whole line (`Contents.validLength`): a torn
        /// tail is cut off first, so the file stays one line per record.
        init(appendingTo url: URL, after validLength: UInt64) throws {
            self.url = url
            handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: validLength)
            try handle.seekToEnd()
        }

        func append(_ line: Line) throws {
            try handle.write(contentsOf: try ExportJournal.encode(line))
            pending += 1
            if pending >= Writer.flushEvery { try flush() }
        }

        func flush() throws {
            try handle.synchronize()
            pending = 0
        }

        func state(_ s: State, note: String? = nil, now: Date = Date()) throws {
            try append(.state(s, at: Writer.stamp(now), note: note))
            try flush()
        }

        func close() throws {
            try flush()
            try handle.close()
        }

        static func stamp(_ date: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: date)
        }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
