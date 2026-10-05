//
//  AVAssetExportSession+Progress.swift
//  BumpSetCut
//
//  One export-with-progress path for every exporter (stitched exports,
//  pre-trim passthrough and re-encode).
//

import AVFoundation

extension AVAssetExportSession {
    /// Export to `url`, reporting progress (0–1) about every 0.1 s, then 1.0.
    func export(to url: URL, as fileType: AVFileType,
                progress: (@Sendable (Double) -> Void)?) async throws {
        let updates = progress.map { report in
            Task { [states = states(updateInterval: 0.1)] in
                for await state in states {
                    if case .exporting(let p) = state { report(p.fractionCompleted) }
                }
            }
        }
        defer { updates?.cancel() }
        try await export(to: url, as: fileType)
        progress?(1.0)
    }
}
