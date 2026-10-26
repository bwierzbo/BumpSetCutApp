//
//  RallyEventsSync.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  How a Stage 1 record moves between a device and the server, decided the same way
//  on both: a record carries the server revision it was loaded from; a save sends that
//  revision back and the server refuses a stale one (rally_events_save, migration 048).
//  Each device keeps a shadow of the last synchronised record, so it can tell "I
//  changed it" from "they changed it": only one side changed → that side wins; both
//  changed → a conflict, both versions kept, the person decides. Nothing is merged
//  over silently; last-write-wins is never used.
//

import Foundation

/// A `label_rally_events` row.
struct LabelRallyEvents: Codable, Equatable {
    var videoId: UUID
    var project: String
    var sessionName: String
    var annotationVersion: String
    var record: EventReview.File
    var revision: Int
    var updatedBy: UUID?
    var updatedAt: Date?
}

/// A save refused because the server's record moved on; the server's row comes with it.
struct RallyEventsConflict: LocalizedError, Equatable {
    var serverRevision: Int
    var message: String
    var errorDescription: String? { "The record changed elsewhere (server revision \(serverRevision)): \(message)" }
}

enum RallyEventsSync {
    enum Action: Equatable {
        /// Nothing to do: both sides hold the same record at the same revision.
        case upToDate
        /// Send the local record, expecting the server to be at `expected` (0 = no server record yet).
        case push(expected: Int)
        /// Take the server's record (the local one never changed since the last sync, or does not exist).
        case pull
        /// Both sides changed since the last sync: keep both, ask the person.
        case conflict(local: Int, server: Int)
    }

    /// The decision for one recording. `shadow` is the record as last synchronised (nil = never synced).
    /// A record's own `revision` is the server revision it was loaded from.
    static func decide(local: EventReview.File?, shadow: EventReview.File?, server: LabelRallyEvents?) -> Action {
        switch (local, server) {
        case (nil, nil): return .upToDate
        case (let mine?, nil):
            // Never on the server: push as new. (A shadow with no server row means the server row was deleted
            // — still a push, the server decides.)
            return .push(expected: mine.revision == 0 ? 0 : mine.revision)
        case (nil, _?): return .pull
        case (let mine?, let theirs?):
            let localChanged = shadow.map { !Self.sameContent($0, mine) } ?? (mine.revision == 0 || !Self.sameContent(theirs.record, mine))
            let serverChanged = theirs.revision != mine.revision
            switch (localChanged, serverChanged) {
            case (false, false): return Self.sameContent(theirs.record, mine) ? .upToDate : .pull
            case (true, false): return .push(expected: mine.revision)
            case (false, true): return .pull
            case (true, true): return .conflict(local: mine.revision, server: theirs.revision)
            }
        }
    }

    /// A record file as found on disk: absent, readable, or present but unreadable (which is never treated as
    /// absent — nothing is written over it).
    enum LocalState: Equatable {
        case absent
        case record(EventReview.File)
        case unreadable(String)

        var record: EventReview.File? { if case .record(let f) = self { return f } else { return nil } }
    }

    static func localState(at url: URL) -> LocalState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do { return .record(try EventReview.read(url)) } catch { return .unreadable(error.localizedDescription) }
    }

    /// After a push came back: what to write locally and as the shadow. If the local file changed while the save
    /// was in flight (`current` differs from `sent`), the newer content is kept with the server's revision as its
    /// bookkeeping — the next sync pushes it; the shadow is always the server's state.
    static func afterPush(sent: EventReview.File, current: EventReview.File?, saved: EventReview.File) -> (local: EventReview.File, shadow: EventReview.File) {
        guard let current, !sameContent(current, sent) else { return (saved, saved) }
        var newer = current
        newer.revision = saved.revision
        return (newer, saved)
    }

    /// Equal but for the revision and the digest bookkeeping, which the server and the open set.
    static func sameContent(_ a: EventReview.File, _ b: EventReview.File) -> Bool {
        var x = a, y = b
        x.revision = 0; y.revision = 0
        return x == y
    }

    /// The shadow beside a record: `<video>.rallyevents.synced.json`.
    static func shadowURL(for recordURL: URL) -> URL {
        recordURL.deletingPathExtension().appendingPathExtension("synced.json")
    }

    /// Where a conflicting server version is kept, beside the local record, never over it:
    /// `<video>.rallyevents.conflict-r<revision>.json`.
    static func conflictURL(for recordURL: URL, serverRevision: Int) -> URL {
        recordURL.deletingPathExtension().appendingPathExtension("conflict-r\(serverRevision).json")
    }

    /// Whether a server message is the save RPC's stale-revision refusal, and the revision it names.
    static func conflict(in message: String) -> RallyEventsConflict? {
        guard message.hasPrefix("conflict:") else { return nil }
        let revision = message.components(separatedBy: "revision ").last?.prefix { $0.isNumber }
        return RallyEventsConflict(serverRevision: Int(revision ?? "") ?? -1, message: message)
    }

    /// Whether a server message is the withheld refusal.
    static func isWithheld(_ message: String) -> Bool { message.hasPrefix("withheld:") }

    /// The record encoded as the apps write it (camelCase keys): what travels inside the RPC and what the
    /// server stores. Never the client's snake-case encoder.
    static func encodeRecord(_ file: EventReview.File) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }
}
