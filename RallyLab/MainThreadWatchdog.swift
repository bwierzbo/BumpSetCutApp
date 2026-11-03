//
//  MainThreadWatchdog.swift
//  RallyLab
//
//  RallyLab beachballs for up to a minute during labeling (owner, 2026-11-02),
//  and nothing records it: there is no crash report for a stall, and the app
//  usually runs under Xcode, where `sample` cannot read its stacks. This
//  watchdog pings the main run loop ten times a second from its own thread
//  and, when a ping comes back late, records how long the main thread was
//  blocked and what it had said it was doing (`note`), to the unified log
//  (subsystem app.BumpSetCut.RallyLab, category stalls) and to
//  ~/Library/Logs/RallyLab/stalls.log. It measures; it changes nothing.
//
//  Reading it back: `log show --last 1d --predicate 'subsystem == "app.BumpSetCut.RallyLab"'`,
//  or the file.
//

import Foundation
import os

final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    struct Stall: Equatable, Sendable {
        let began: Date
        let seconds: Double
        /// What the main actor had noted it was doing when the stall began, if anything.
        let activity: String?
    }

    static let logFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/RallyLab/stalls.log")

    /// A ping later than this is a stall. Half a second is where the beachball appears.
    let threshold: TimeInterval
    private let logger = Logger(subsystem: "app.BumpSetCut.RallyLab", category: "stalls")
    private let lock = NSLock()
    private var thread: Thread?
    private var pingSent: Date?
    private var pingOutstanding = false
    private var activity: String?
    private var stallsStorage: [Stall] = []
    private let onStall: (@Sendable (Stall) -> Void)?

    /// `onStall` runs on a utility queue after each recorded stall (tests; a diagnostics view).
    init(threshold: TimeInterval = 0.5, onStall: (@Sendable (Stall) -> Void)? = nil) {
        self.threshold = threshold
        self.onStall = onStall
    }

    /// The stalls recorded so far this process, oldest first (at most 500 kept).
    var stalls: [Stall] {
        lock.lock(); defer { lock.unlock() }
        return stallsStorage
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "RallyLab main-thread watchdog"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        thread?.cancel()
        thread = nil
    }

    /// What the main actor is about to do synchronously, so a stall can say so; nil when done.
    func note(_ activity: String?) {
        lock.lock(); defer { lock.unlock() }
        self.activity = activity
    }

    private func run() {
        var warned = false
        while !Thread.current.isCancelled {
            lock.lock()
            let outstanding = pingOutstanding
            let sent = pingSent
            let noted = activity
            lock.unlock()
            if !outstanding {
                let now = Date()
                lock.lock()
                pingOutstanding = true
                pingSent = now
                lock.unlock()
                warned = false
                DispatchQueue.main.async { [weak self] in self?.pingReturned(sentAt: now) }
            } else if let sent, !warned, Date().timeIntervalSince(sent) >= threshold {
                // Said while it is still blocked, so a stall that never ends is in the log too.
                warned = true
                logger.warning("main thread has not run for \(Date().timeIntervalSince(sent), format: .fixed(precision: 1), privacy: .public) s and counting; activity: \(noted ?? "none noted", privacy: .public)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// On the main thread: the ping sent at `sentAt` has run.
    private func pingReturned(sentAt: Date) {
        let waited = Date().timeIntervalSince(sentAt)
        lock.lock()
        pingOutstanding = false
        let noted = activity
        lock.unlock()
        guard waited >= threshold else { return }
        record(Stall(began: sentAt, seconds: waited, activity: noted))
    }

    private func record(_ stall: Stall) {
        lock.lock()
        stallsStorage.append(stall)
        if stallsStorage.count > 500 { stallsStorage.removeFirst(stallsStorage.count - 500) }
        lock.unlock()
        logger.error("main thread was blocked for \(stall.seconds, format: .fixed(precision: 2), privacy: .public) s from \(stall.began.ISO8601Format(), privacy: .public); activity: \(stall.activity ?? "none noted", privacy: .public)")
        let line = "\(stall.began.ISO8601Format()) blocked \(String(format: "%.2f", stall.seconds)) s; activity: \(stall.activity ?? "none noted")\n"
        let file = Self.logFile
        let onStall = self.onStall
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: file)
            }
            onStall?(stall)
        }
    }
}
