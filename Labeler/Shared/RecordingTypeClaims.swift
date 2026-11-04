//
//  RecordingTypeClaims.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  A recording's type claimed on the phone, confirmed on the Mac (D-033;
//  migration 052). The phone submits a claim — continuous, edited, or
//  unknown — as a request for confirmation; the Mac validates it against
//  the project and writes the authoritative footage-properties record
//  through its one writer, then settles the claim accepted, or rejected
//  with a reason in plain words. The server keeps the claims and their
//  history; nothing on the phone or the server is the type itself.
//
//  What both sides decide the same way lives here: what the phone shows for
//  a recording (the newest choice's state), and what the Mac does with a
//  submitted claim (accept, already applied, reject with a reason, or leave
//  it for the next round) from the project as it is.
//

import Foundation

/// A `label_recording_type_claims` row.
struct RecordingTypeClaim: Codable, Equatable, Identifiable {
    enum Status: String, Codable, Equatable { case submitted, accepted, rejected, superseded }

    var id: UUID
    var videoId: UUID
    var project: String
    var sessionName: String
    /// The published original the claim is about (`label_videos.source_fingerprint` when it was made).
    var sourceFingerprint: String
    /// `RecordingTypeClaims.Kind.rawValue` — kept as text so a row with a value this build doesn't know still decodes.
    var recordingType: String
    /// 1, 2, 3… per recording, in submission order.
    var revision: Int
    var status: Status
    /// Why it was rejected or superseded, in plain words.
    var reason: String?
    var submittedBy: UUID?
    var submittedAt: Date
    var settledBy: UUID?
    var settledAt: Date?
    var updatedAt: Date?

    var kind: RecordingTypeClaims.Kind? { RecordingTypeClaims.Kind(rawValue: recordingType) }
}

enum RecordingTypeClaims {
    /// The choice, as the record's `recordingType` spells it (FootageProperties.RecordingType on the Mac).
    enum Kind: String, Codable, CaseIterable, Equatable {
        case continuous, edited, unknown

        var title: String {
            switch self {
            case .continuous: return "Continuous recording"
            case .edited: return "Edited recording"
            case .unknown: return "Unknown"
            }
        }

        var detail: String {
            switch self {
            case .continuous: return "No known timeline editing: the footage runs as it was recorded. Intervals you excluded for a partial rally or a replay don't change that."
            case .edited: return "Contains removed time, replays, artificial speed changes or other edits."
            case .unknown: return "Not yet verified: the recording is not treated as footage for training until someone says what it is."
            }
        }
    }

    /// A choice made on this phone, kept in its durable outbox until the server has it — or, refused by the server
    /// for what it is (withheld, identity, input), kept there with the refusal, shown and never sent again as it is.
    struct Pending: Codable, Equatable {
        /// Minted here: the claim's id on the server too (an upload repeated after a lost reply is the same claim).
        var id: UUID
        var videoId: UUID
        var sourceFingerprint: String
        var kind: Kind
        var madeAt: Date
        /// The server's reason the claim itself was refused: permanent for this claim (a new choice is a new claim);
        /// nil while it is still to be sent. Part of the durable outbox, so a restart does not send it again.
        var refusal: String? = nil

        init(id: UUID, videoId: UUID, sourceFingerprint: String, kind: Kind, madeAt: Date, refusal: String? = nil) {
            self.id = id; self.videoId = videoId; self.sourceFingerprint = sourceFingerprint; self.kind = kind; self.madeAt = madeAt; self.refusal = refusal
        }
    }

    /// The choices to send, oldest first: the ones not refused. A transient failure (offline) leaves a choice here
    /// without a refusal, so it is sent next time; a refusal keeps it out until a new choice replaces it.
    static func toSend(_ outbox: [UUID: Pending]) -> [Pending] {
        outbox.values.filter { $0.refusal == nil }.sorted { $0.madeAt < $1.madeAt }
    }

    /// The outbox with a new choice for its recording in place of every earlier one for that recording — refused
    /// or still to be sent — under a fresh id (a corrected choice is a new claim, never a retry of the refused one).
    static func replacing(_ outbox: [UUID: Pending], with new: Pending) -> [UUID: Pending] {
        var out = outbox.filter { $0.value.videoId != new.videoId }
        out[new.id] = new
        return out
    }

    /// What the recording is said to be: not yet reviewed (no confirmation by anyone), reviewed and found unknown
    /// (a person confirmed the type could not be established — `recordingType` unknown with who and when), or the
    /// confirmed type. The policy is the same for both unknowns (not assessed); the words are not.
    static func reviewed(kind: Kind?, at: Date?) -> String {
        guard let kind, at != nil else { return "not yet reviewed" }
        return kind == .unknown ? "reviewed — unknown" : kind.title.lowercased()
    }

    /// What the phone shows for a recording: the newest choice and where it stands.
    enum Display: Equatable {
        case none
        /// Saved on this phone, not on the server yet (offline, or not sent yet).
        case pending(Pending)
        /// On the server, waiting for the Mac.
        case submitted(RecordingTypeClaim)
        case accepted(RecordingTypeClaim)
        case rejected(RecordingTypeClaim, reason: String)
        /// A newer choice replaced it.
        case superseded(RecordingTypeClaim)

        var kind: Kind? {
            switch self {
            case .none: return nil
            case .pending(let p): return p.kind
            case .submitted(let c), .accepted(let c), .rejected(let c, _), .superseded(let c): return c.kind
            }
        }

        /// Whether the choice shown may still be acted on by the Mac.
        var isOpen: Bool {
            switch self { case .pending, .submitted: return true; default: return false }
        }

        /// The state in plain words, for the phone. A refused choice says why and that a new choice is the way on.
        func statusText() -> String {
            switch self {
            case .none: return "No choice sent from this phone yet."
            case .pending(let p):
                if let refusal = p.refusal { return "\(p.kind.title): couldn't be sent — \(refusal). Choose again to try afresh." }
                return "\(p.kind.title): saved on this phone, sends when online."
            case .submitted(let c): return "\(c.kind?.title ?? c.recordingType): sent — waiting for the Mac to confirm."
            case .accepted(let c): return "\(c.kind?.title ?? c.recordingType): accepted on the Mac" + (c.settledAt.map { " \(Self.day($0))" } ?? "") + "."
            case .rejected(let c, let reason): return "\(c.kind?.title ?? c.recordingType): not accepted — \(reason). You can choose again."
            case .superseded(let c): return "\(c.kind?.title ?? c.recordingType): replaced by a newer choice."
            }
        }

        private static func day(_ date: Date) -> String {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return "on " + f.string(from: date)
        }
    }

    /// The newest choice for `video`: a choice still on this phone first (it is newer than anything the server has
    /// from this phone), else the server's claim of the highest revision — whatever its state, so a rejection or a
    /// replacement is seen, never dropped.
    static func display(video: UUID, pending: [UUID: Pending], rows: [RecordingTypeClaim]) -> Display {
        if let p = pending.values.filter({ $0.videoId == video }).max(by: { $0.madeAt < $1.madeAt }) { return .pending(p) }
        guard let newest = rows.filter({ $0.videoId == video }).max(by: { ($0.revision, $0.submittedAt) < ($1.revision, $1.submittedAt) }) else { return .none }
        switch newest.status {
        case .submitted: return .submitted(newest)
        case .accepted: return .accepted(newest)
        case .rejected: return .rejected(newest, reason: newest.reason ?? "not accepted on the Mac")
        case .superseded: return .superseded(newest)
        }
    }

    // MARK: - The Mac's decision

    /// The footage-properties record on the Mac, as far as a claim is concerned.
    enum RecordState: Equatable {
        case none
        /// The type on file, and who confirmed it when (`recordingTypeBy`, `recordingTypeAt`).
        case record(type: String, by: String?, at: String?)
        /// The record exists but can't be read: nothing is written over it.
        case unreadable(String)
    }

    enum Decision: Equatable {
        /// Write the type through the one writer, read it back, then settle accepted.
        case accept
        /// The record already carries this very claim (its acknowledgement was lost): settle accepted, write nothing.
        case alreadyApplied
        /// Settle rejected with this reason; nothing is written.
        case reject(String)
        /// Leave the claim submitted and say why: the Mac's state, not the claim's, is the problem — retried next round.
        case `defer`(String)
    }

    /// How the Mac attributes a claim it writes: the record's `recordingTypeBy` names the labeler and the claim, so
    /// the same claim is recognised on file later.
    static func attribution(of claim: RecordingTypeClaim) -> String {
        "labeler \(claim.submittedBy.map { String($0.uuidString.lowercased().prefix(8)) } ?? "unknown") via iPhone · claim \(claim.id.uuidString.lowercased())"
    }

    static func isAttributed(_ by: String?, to claim: RecordingTypeClaim) -> Bool {
        by?.hasSuffix("claim \(claim.id.uuidString.lowercased())") == true
    }

    /// The Mac's decision on a submitted claim, from the project as it is: `cardFingerprint` is the recording's
    /// current identity on its project card (nil: none), `withheld` whether it is in the withheld closure, `record`
    /// the footage-properties record on file. Order: what is wrong with the claim is rejected before anything is
    /// written; what is wrong on the Mac is deferred; a newer decision on the Mac wins over the claim; the claim
    /// already on file is acknowledged without a second write.
    static func decide(claim: RecordingTypeClaim, cardFingerprint: String?, withheld: Bool, record: RecordState) -> Decision {
        guard claim.kind != nil else { return .reject("the choice \"\(claim.recordingType)\" is not one this Mac knows") }
        if withheld { return .reject("this recording is withheld from labeling on the Mac") }
        guard let card = cardFingerprint else { return .reject("the recording has no file identity on the Mac") }
        if card != claim.sourceFingerprint { return .reject("the recording's file changed since this was sent — confirm again") }
        switch record {
        case .unreadable(let why):
            return .defer("the recording's footage record can't be read on the Mac: \(why)")
        case .none:
            return .accept
        case .record(let type, let by, let at):
            if isAttributed(by, to: claim), type == claim.recordingType { return .alreadyApplied }
            if let at = at.flatMap(parse), at > claim.submittedAt {
                return .reject("confirmed on the Mac as \(Kind(rawValue: type)?.title.lowercased() ?? type) after this was sent — confirm again if that is wrong")
            }
            return .accept
        }
    }

    /// An ISO 8601 stamp as the records carry them, with or without fractional seconds.
    static func parse(_ stamp: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    }

    /// Whether a server message is a refusal of the claim itself (identity, withheld, or input): the claim is kept on
    /// the phone with the reason and not sent again as it is.
    static func isRefusal(_ message: String) -> Bool {
        message.hasPrefix("identity:") || message.hasPrefix("withheld:") || message.contains("recording_type_claim_submit:")
    }
}
