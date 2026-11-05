//
//  RallyTruthLoading.swift
//  RallyLab
//
//  A project recording's truth as the Mac reads it: the sidecar's marks
//  (`<video>.rallylabels.json`, RallyMarkRecord) by kind — the rallies, the
//  excluded spans (missed serves, "not a rally") — outside the session's
//  cut ranges, complete when every rally is marked (session.ralliesMarked).
//  Every consumer that scores, tunes or trains on marks — RallyCutScore,
//  PipelineTuner, DeciderRetune, TrainingDataExporter, the Pipeline tab —
//  reads through here, so one projection (RallyTruth) decides what is a
//  rally, what is not-rally time and what is excluded.
//

import Foundation

extension RallyTruth {
    /// The marks in the sidecar beside `video`: nil when there is no sidecar; throws when it won't decode
    /// (unreadable marks are unknown marks, never none).
    static func marks(inSidecarOf video: URL) throws -> [Mark]? {
        let url = RallyMarkModel.labelsURL(for: video)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: url))
            .map { Mark(start: $0.startTime, end: $0.endTime, kind: $0.kind) }
    }

    /// A project session's truth; nil when the recording has no sidecar yet.
    static func of(_ session: VideoSession) throws -> RallyTruth? {
        guard let marks = try marks(inSidecarOf: URL(fileURLWithPath: session.sourcePath)) else { return nil }
        return RallyTruth(marks: marks, cuts: session.cuts ?? [], complete: session.ralliesMarked ?? false)
    }

    /// Why a recording cannot be scored for false clips or dead time, or trained on as not-rally time: nil when
    /// every rally is marked.
    static func incompleteReason(_ session: VideoSession) -> String? {
        session.ralliesMarked == true ? nil
            : "not every rally marked — what lies outside the marks is unknown, not dead (Label tab → That's every rally)"
    }

    var positiveIntervals: [Interval] { positives.map { Interval(start: $0.start, end: $0.end) } }
    var excludedIntervals: [Interval] { excluded.map { Interval(start: $0.start, end: $0.end) } }
}
