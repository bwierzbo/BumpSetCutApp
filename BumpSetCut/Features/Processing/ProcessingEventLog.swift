//
//  ProcessingEventLog.swift
//  BumpSetCut
//
//  Lightweight structured event logger for the processing pipeline.
//  Each processing run produces a chronological event trail answering
//  "what happened, when, and why?"
//

import Foundation
import CoreMedia

// MARK: - Processing Event

/// A single structured event emitted during video processing.
struct ProcessingEvent: Codable, Sendable {
    let timestamp: Double          // Seconds since processing started
    let videoTime: Double?         // Current position in video (seconds), if applicable
    let type: EventType
    let detail: String?

    enum EventType: String, Codable, Sendable {
        case processingStarted
        case sportDetected
        case frameLoopStarted
        case rallyStarted
        case rallyEnded
        case segmentFinalized
        case processingCompleted
        case processingFailed
        case saveStarted
        case saveCompleted
        case saveFailed
    }
}

// MARK: - Processing Event Log

/// Append-only event collector for a single processing run.
/// Not thread-safe — intended to be used from a single async context.
final class ProcessingEventLog: @unchecked Sendable {
    private(set) var events: [ProcessingEvent] = []
    private let startTime: CFAbsoluteTime

    init() {
        self.startTime = CFAbsoluteTimeGetCurrent()
    }

    /// Elapsed seconds since the log was created.
    private var elapsed: Double {
        CFAbsoluteTimeGetCurrent() - startTime
    }

    func log(_ type: ProcessingEvent.EventType, videoTime: Double? = nil, detail: String? = nil) {
        events.append(ProcessingEvent(
            timestamp: elapsed,
            videoTime: videoTime,
            type: type,
            detail: detail
        ))
    }

    /// Convenience: log with CMTime video position.
    func log(_ type: ProcessingEvent.EventType, at cmTime: CMTime, detail: String? = nil) {
        log(type, videoTime: CMTimeGetSeconds(cmTime), detail: detail)
    }

    /// Returns the events array (for embedding in ProcessingMetadata).
    var allEvents: [ProcessingEvent] { events }
}
