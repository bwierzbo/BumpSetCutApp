//
//  AnalysisRunsKeepNothingTests.swift
//  RallyLabTests
//
//  RallyLab runs the shared pipeline on project recordings, never on library videos: every run
//  must go through VideoProcessor.analyzeVideo, which saves no metadata file and no checkpoint.
//  `processVideo(_:videoId:)` under a throwaway ID left about 6 MB per run in
//  ~/Library/Application Support/BumpSetCut/ProcessedMetadata that nothing read or removed
//  (5.5 GB by 2026-11-10). A new caller cannot bring that back unnoticed.
//

import XCTest

final class AnalysisRunsKeepNothingTests: XCTestCase {

    func testNoRallyLabSourceCallsTheLibraryProcessingPath() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RallyLab", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the RallyLab sources were not found at \(sources.path)")
        var callers: [String] = []
        var analysisRuns = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".processVideo(") || text.contains(".processVideoMetadata(") { callers.append(file.lastPathComponent) }
            analysisRuns += text.components(separatedBy: ".analyzeVideo(").count - 1
        }
        XCTAssertEqual(callers.sorted(), [], "these save a metadata file per run; use analyzeVideo(_:)")
        XCTAssertGreaterThanOrEqual(analysisRuns, 10, "the pipeline runs this test protects were not found")
    }
}
