//
//  ExportIO.swift
//  RallyLab
//
//  What a long export over a network volume needs to survive, or to fail
//  honestly: knowing when the volume under a path has gone (an SMB mount
//  that drops leaves a plain local folder behind at the same path, which
//  would otherwise be written into without a word), retrying an I/O error
//  a bounded number of times while the volume is still there, and telling
//  a complete frame file from a torn or foreign one before it is reused.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportIO {

    /// An error that retrying cannot help: a lost volume, a refused folder, a plan violation.
    /// `retrying` rethrows these at once; only other errors (I/O) are tried again.
    protocol Final: Error {}

    enum Failure: LocalizedError, Equatable, Final {
        /// The path no longer leads to the object it did when the export started.
        case volumeLost(path: String, detail: String)
        /// The operation kept failing after every allowed attempt.
        case gaveUp(what: String, attempts: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .volumeLost(let path, let detail):
                return "The volume under \(path) is gone (\(detail)). The export stops here; remount it and resume with --resume."
            case .gaveUp(let what, let attempts, let detail):
                return "\(what) failed \(attempts) times: \(detail). The export stops here; resume with --resume once the cause is fixed."
            }
        }
    }

    /// A file or folder as it was when the export started: its device and inode. A vanished
    /// mount, a replaced folder or a swapped file no longer matches.
    struct Anchor: Equatable {
        let path: String
        let device: dev_t
        let inode: ino_t

        /// Follows symlinks, so a dataset's per-file link to a mounted video anchors the video itself.
        init(path: String) throws {
            var st = stat()
            guard stat(path, &st) == 0 else {
                throw Failure.volumeLost(path: path, detail: String(cString: strerror(errno)))
            }
            self.path = path
            device = st.st_dev
            inode = st.st_ino
        }

        func verify() throws {
            var st = stat()
            guard stat(path, &st) == 0 else {
                throw Failure.volumeLost(path: path, detail: String(cString: strerror(errno)))
            }
            guard st.st_dev == device, st.st_ino == inode else {
                throw Failure.volumeLost(path: path, detail: "a different file system object is there now")
            }
        }
    }

    /// Bounded retries with growing pauses. Four tries about 17 s apart in all: enough for an
    /// SMB hiccup, not enough to mask an outage.
    struct Retry: Equatable {
        var delays: [TimeInterval] = [2, 5, 10]
        var attempts: Int { delays.count + 1 }
    }

    /// Runs `body`; on an error, checks the anchors first — a lost volume is final, never
    /// retried — then waits and tries again, up to the policy's attempts. `sleep` is
    /// injectable for tests.
    static func retrying<T>(_ what: String, anchors: [Anchor], policy: Retry = Retry(),
                            sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                            _ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await body() } catch let error as Final {
                throw error
            } catch {
                attempt += 1
                for anchor in anchors { try anchor.verify() }
                guard attempt < policy.attempts else {
                    throw Failure.gaveUp(what: what, attempts: attempt, detail: error.localizedDescription)
                }
                try await sleep(policy.delays[attempt - 1])
            }
        }
    }

    // MARK: - Frame files

    enum FrameVerdict: Equatable {
        case valid(width: Int, height: Int)
        case invalid(String)
    }

    /// Whether `data` is one complete JPEG that decodes: start and end markers, a complete
    /// image source of exactly one JPEG image, and a successful full decode. Anything else —
    /// a torn write, another format, a file that is not an image — is named, never trusted.
    static func inspectFrame(_ data: Data) -> FrameVerdict {
        guard data.count > 4, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8, data[data.startIndex + 2] == 0xFF
        else { return .invalid("not a JPEG (no start marker)") }
        guard data[data.endIndex - 2] == 0xFF, data[data.endIndex - 1] == 0xD9 else { return .invalid("incomplete (no end marker)") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .jpeg)
        else { return .invalid("not a complete JPEG image") }
        guard let image = decode(source), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return .invalid("does not decode") }
        return .valid(width: image.width, height: image.height)
    }

    static func decode(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func decodeFrame(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(decode)
    }

    /// Writes `data` next to its destination first and moves it into place, so a file at the
    /// final name is either whole or absent. A leftover `.part` is never a frame.
    static let partialSuffix = ".part"
    static func writeWhole(_ data: Data, to url: URL) throws {
        let part = URL(fileURLWithPath: url.path + partialSuffix)
        try data.write(to: part)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: part, to: url)
    }
}
