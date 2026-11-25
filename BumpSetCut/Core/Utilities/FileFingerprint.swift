//
//  FileFingerprint.swift
//  BumpSetCut
//
//  A file's identity wherever it is copied: its size plus a hash of its first and last
//  4 MB, as `"file:<sha256>"`. The identity RallyLab gives a recording
//  (ProjectsModel.fileFingerprint) and the one a court and net calibration is bound to.
//  Compiled into RallyLab too (membershipExceptions).
//

import CryptoKit
import Foundation

enum FileFingerprint {
    /// The fingerprint read from the file's bytes.
    /// nil when any seek or read fails or comes back short (a stalled share): a hash of
    /// part of the bytes would be a wrong identity, never a missing one.
    static func read(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let chunk: UInt64 = 4 << 20
        var hasher = SHA256()
        do {
            let size = try handle.seekToEnd()
            withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: Int(chunk)) ?? Data()
            guard UInt64(head.count) == min(chunk, size) else { return nil }
            hasher.update(data: head)
            if size > chunk {
                let tailStart = size - min(chunk, size - chunk)
                try handle.seek(toOffset: tailStart)
                let tail = try handle.readToEnd() ?? Data()
                guard UInt64(tail.count) == size - tailStart else { return nil }
                hasher.update(data: tail)
            }
        } catch { return nil }
        return "file:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
