//
//  BallDetectionLog.swift
//  BumpSetCut
//
//  Every processed frame of a run and the balls found in it, kept with the video (D-044). Where the ball is
//  does not depend on the net, the court or where the camera stood, so a later run can decide the rallies
//  again from this file — through the same RallyDecisionStage — without finding the ball again.
//
//  The values are kept exactly as the run had them (a frame's time as its CMTime value and timescale, a box
//  as four doubles), so that what is read back is what the stage was given. One small header in JSON, then
//  the frames packed and compressed. Compiled into RallyLab too.
//

import CoreGraphics
import CoreMedia
import Foundation

struct BallDetectionLog: Equatable {
    static let formatVersion: UInt32 = 2
    private static let magic = Array("BSCD".utf8)

    struct Detection: Equatable {
        let bbox: CGRect
        let confidence: Float
    }

    struct Frame: Equatable {
        let time: CMTime
        /// The frame's balls in the order the stage took them: the first `singleFrameCount` from a
        /// single-frame detector, the rest from the multi-frame model.
        let detections: [Detection]
        let singleFrameCount: Int
    }

    struct Header: Codable, Equatable {
        /// The video the frames were read from (FileFingerprint), nil if it could not be read.
        var sourceFingerprint: String?
        var durationSec: Double
        /// Boxes are in the upright frame (the video's rotation was applied).
        var upright: Bool
        /// What found the ball, as the run's timing line names it.
        var finder: String
        /// The frames the run decoded and, of those, the ones it did not process (its stride, or frames the
        /// multi-frame model was not fed): a run's counts that the frames here alone don't give.
        var decodedFrameCount: Int
        var skippedFrameCount: Int
        /// Where an interrupted run took the frames up again; empty for a run made in one go.
        var resumedAtSec: [Double]
        /// Only in the file an unfinished run keeps beside its checkpoint: the checkpoint's time.
        var checkpointTimeSec: Double?
    }

    var header: Header
    var frames: [Frame]

    enum ReadError: Error, Equatable {
        case notADetectionLog
        case unsupportedVersion(UInt32)
        case malformed(String)
    }

    /// Adds a processed frame to a run's frames. A resumed run reads the frame at its resume point again only
    /// when its stride lands on it: then that frame takes the place of the one kept from the interrupted run, and
    /// otherwise the kept one stays — a processed frame is never lost and never there twice.
    static func record(_ frame: Frame, in frames: inout [Frame]) {
        if let last = frames.last, CMTimeCompare(last.time, frame.time) == 0 {
            frames[frames.count - 1] = frame
        } else {
            frames.append(frame)
        }
    }

    // MARK: Bytes

    func encoded() throws -> Data {
        var payload = Data()
        payload.append(UInt32(frames.count))
        for frame in frames {
            payload.append(frame.time.value)
            payload.append(frame.time.timescale)
            payload.append(UInt16(clamping: frame.singleFrameCount))
            payload.append(UInt16(clamping: frame.detections.count))
            for detection in frame.detections.prefix(Int(UInt16.max)) {
                for value in [detection.bbox.origin.x, detection.bbox.origin.y, detection.bbox.width, detection.bbox.height] {
                    payload.append(Double(value).bitPattern)
                }
                payload.append(detection.confidence.bitPattern)
            }
        }
        let head = try JSONEncoder().encode(header)
        var data = Data(Self.magic)
        data.append(Self.formatVersion)
        data.append(UInt32(head.count))
        data.append(head)
        data.append(UInt64(payload.count))
        data.append(try (payload as NSData).compressed(using: .lzfse) as Data)
        return data
    }

    init(header: Header, frames: [Frame]) {
        self.header = header
        self.frames = frames
    }

    init(data: Data) throws {
        var file = Reader(data)
        guard try file.bytes(Self.magic.count) == Data(Self.magic) else { throw ReadError.notADetectionLog }
        let version: UInt32 = try file.number()
        guard version == Self.formatVersion else { throw ReadError.unsupportedVersion(version) }
        let headLength: UInt32 = try file.number()
        do { header = try JSONDecoder().decode(Header.self, from: try file.bytes(Int(headLength))) } catch let error as ReadError { throw error } catch {
            throw ReadError.malformed("the header can't be read")
        }
        let payloadLength: UInt64 = try file.number()
        guard let unpacked = try? (file.rest() as NSData).decompressed(using: .lzfse) as Data, UInt64(unpacked.count) == payloadLength else {
            throw ReadError.malformed("the frames can't be unpacked")
        }
        var payload = Reader(unpacked)
        let frameCount: UInt32 = try payload.number()
        var frames: [Frame] = []
        frames.reserveCapacity(Int(frameCount))
        for _ in 0..<frameCount {
            let value: Int64 = try payload.number()
            let timescale: Int32 = try payload.number()
            let singleFrameCount: UInt16 = try payload.number()
            let count: UInt16 = try payload.number()
            var detections: [Detection] = []
            detections.reserveCapacity(Int(count))
            for _ in 0..<count {
                let x = Double(bitPattern: try payload.number()), y = Double(bitPattern: try payload.number())
                let width = Double(bitPattern: try payload.number()), height = Double(bitPattern: try payload.number())
                detections.append(Detection(bbox: CGRect(x: x, y: y, width: width, height: height), confidence: Float(bitPattern: try payload.number())))
            }
            frames.append(Frame(time: CMTime(value: value, timescale: timescale), detections: detections, singleFrameCount: Int(singleFrameCount)))
        }
        guard payload.isAtEnd else { throw ReadError.malformed("bytes are left after the last frame") }
        self.frames = frames
    }

    /// Reads fixed-width little-endian numbers off the front of some bytes; short bytes are an error.
    private struct Reader {
        private let data: Data
        private var offset: Int
        init(_ data: Data) { self.data = data; offset = data.startIndex }
        var isAtEnd: Bool { offset == data.endIndex }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - offset >= count else { throw ReadError.malformed("the file is cut short") }
            defer { offset += count }
            return data.subdata(in: offset..<offset + count)
        }

        mutating func number<T: FixedWidthInteger>() throws -> T {
            T(littleEndian: try bytes(MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as: T.self) })
        }

        mutating func rest() -> Data {
            defer { offset = data.endIndex }
            return data.subdata(in: offset..<data.endIndex)
        }
    }

    // MARK: Files

    /// nil when there is no file or it can't be read: a run that wanted it then goes on without.
    static func load(from url: URL) -> BallDetectionLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? BallDetectionLog(data: data)
    }

    /// Whether the file was written. A failure is reported and leaves any earlier file as it was.
    @discardableResult
    func write(to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded().write(to: url, options: .atomic)
            // Made again by processing the video, and megabytes for a long one: not for iCloud backups.
            StorageManager.excludeFromBackup(url)
            return true
        } catch {
            print("⚠️ BallDetectionLog: write failed — \(error.localizedDescription)")
            return false
        }
    }

    static func delete(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(_ number: T) {
        Swift.withUnsafeBytes(of: number.littleEndian) { append(contentsOf: $0) }
    }
}
