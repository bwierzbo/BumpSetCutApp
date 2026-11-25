//
//  FileFingerprintCache.swift
//  RallyLab
//
//  A video's content fingerprint (ProjectsModel.fileFingerprint: its size plus
//  a hash of its first and last 4 MB) is read from the file every time it is
//  asked for, and the footage sits on the SMB share: one 4 MB read took 48 s
//  on 2026-11-02 while the app was also reading the share, and the Review
//  tab's inventory asks for every recording's fingerprint on every refresh
//  (EventInventory → EventReview.refusal), on the main actor. The identity
//  itself does not change unless the file does, so it is kept here per
//  process, keyed by the file's resolved path and valid while the file's
//  size, modification time and inode are what they were: a stat (tens of
//  milliseconds over the share) instead of an 8 MB read. A file that cannot
//  be stat'ed or read is never cached, so a missing or unreadable file is
//  asked again next time. The fingerprint's meaning and every refusal that
//  reads it are unchanged.
//

import Foundation

final class FileFingerprintCache: @unchecked Sendable {
    static let shared = FileFingerprintCache()

    struct Stamp: Equatable {
        let size: UInt64
        let modifiedNanoseconds: Int64
        let inode: UInt64
        let device: Int32
    }

    private let lock = NSLock()
    private var entries: [String: (stamp: Stamp, fingerprint: String)] = [:]
    /// How many times the fingerprint was read from a file (tests; diagnostics).
    private(set) var computations = 0

    /// The file's fingerprint: cached while the file is unchanged, else `compute` is asked
    /// and its answer kept (only when it is one). `path` may be a symlink: the key is the
    /// file it resolves to, so two links to one file share one entry.
    func fingerprint(atPath path: String, compute: () -> String?) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let stamp = Self.stamp(ofResolvedPath: resolved) else { return compute() }
        lock.lock()
        if let hit = entries[resolved], hit.stamp == stamp {
            lock.unlock()
            return hit.fingerprint
        }
        lock.unlock()
        let fingerprint = compute()
        lock.lock()
        computations += 1
        if let fingerprint { entries[resolved] = (stamp, fingerprint) } else { entries.removeValue(forKey: resolved) }
        lock.unlock()
        return fingerprint
    }

    /// Forget everything (tests; a diagnostics "re-read" action).
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// What identifies the file's current contents without reading them; nil when it can't be stat'ed.
    static func stamp(ofResolvedPath path: String) -> Stamp? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return Stamp(size: UInt64(st.st_size), modifiedNanoseconds: modified, inode: UInt64(st.st_ino), device: st.st_dev)
    }
}
