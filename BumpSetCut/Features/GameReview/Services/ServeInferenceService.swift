//
//  ServeInferenceService.swift
//  BumpSetCut
//
//  Infers which court side served each rally using ball size trend and game logic.
//

import Foundation

struct ServeInferenceService {

    /// Infer which side served for every rally.
    /// - Rally 0: uses `setup.firstServer`
    /// - Rally 1+: uses "winner of previous point serves" rule
    /// - Fallback when no previous winner: uses `ballSizeTrend` slope
    static func inferServes(segments: [RallySegment], setup: GameSetup, decisions: [RallyScoringDecision] = []) -> [ServeInference] {
        guard !segments.isEmpty else { return [] }

        var inferences: [ServeInference] = []

        for index in segments.indices {
            let segment = segments[index]

            if index == 0 {
                // First rally: infer from ball trajectory, fall back to setup value
                if let slope = segment.ballSizeTrend, abs(slope) > 1e-6 {
                    let server: CourtSide = slope > 0 ? .far : .near
                    let confidence = min(1.0, abs(slope) * 100)
                    inferences.append(ServeInference(
                        rallyIndex: index,
                        bboxSizeSlope: slope,
                        sampleCount: 0,
                        inferredServer: server,
                        confidence: confidence,
                        method: .bboxTrend
                    ))
                } else {
                    inferences.append(ServeInference(
                        rallyIndex: index,
                        bboxSizeSlope: segment.ballSizeTrend ?? 0,
                        sampleCount: 0,
                        inferredServer: setup.firstServer,
                        confidence: 0.5,
                        method: .firstRallySetup
                    ))
                }
                continue
            }

            // Check if we have a decision for the previous rally
            if let prevDecision = decisions.first(where: { $0.rallyIndex == index - 1 }) {
                // Winner of previous point serves next
                inferences.append(ServeInference(
                    rallyIndex: index,
                    bboxSizeSlope: segment.ballSizeTrend ?? 0,
                    sampleCount: 0,
                    inferredServer: prevDecision.pointWinner,
                    confidence: 0.9,
                    method: .previousPointWinner
                ))
                continue
            }

            // Fallback: use ball size trend
            // Positive slope = ball getting bigger = approaching camera = far side served
            // Negative slope = ball getting smaller = receding = near side served
            if let slope = segment.ballSizeTrend, abs(slope) > 1e-6 {
                let server: CourtSide = slope > 0 ? .far : .near
                let confidence = min(1.0, abs(slope) * 100) // Scale slope magnitude to confidence
                inferences.append(ServeInference(
                    rallyIndex: index,
                    bboxSizeSlope: slope,
                    sampleCount: 0,
                    inferredServer: server,
                    confidence: confidence,
                    method: .bboxTrend
                ))
            } else {
                // No trend data: default to previous inference's server or setup default
                let prevServer = inferences.last?.inferredServer ?? setup.firstServer
                inferences.append(ServeInference(
                    rallyIndex: index,
                    bboxSizeSlope: 0,
                    sampleCount: 0,
                    inferredServer: prevServer,
                    confidence: 0.3,
                    method: .bboxTrend
                ))
            }
        }

        return inferences
    }
}
