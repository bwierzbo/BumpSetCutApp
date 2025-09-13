//
//  VideoProcessingTrackingTests.swift
//  BumpSetCutTests
//
//  Created by Benjamin Wierzbanowski on 9/4/25.
//

import XCTest
@testable import BumpSetCut

final class VideoProcessingTrackingTests: XCTestCase {
    
    var mediaStore: MediaStore!
    var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        
        // Create a temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Initialize MediaStore with temp directory
        mediaStore = MediaStore(baseDirectory: tempDirectory)
    }
    
    override func tearDown() {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDirectory)
        mediaStore = nil
        tempDirectory = nil
        super.tearDown()
    }
    
    // MARK: - VideoMetadata Processing Status Tests
    
    func testVideoMetadata_DefaultProperties() {
        let videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )
        
        XCTAssertFalse(videoMetadata.isProcessed, "New videos should not be marked as processed")
        XCTAssertNil(videoMetadata.processedDate, "New videos should not have a processed date")
        XCTAssertNil(videoMetadata.originalVideoId, "New videos should not have an original video ID")
        XCTAssertTrue(videoMetadata.processedVideoIds.isEmpty, "New videos should have empty processed video IDs")
        XCTAssertTrue(videoMetadata.isOriginalVideo, "New videos should be original videos")
        XCTAssertTrue(videoMetadata.canBeProcessed, "Original videos should be processable")
    }
    
    func testVideoMetadata_ProcessedVideoProperties() {
        var videoMetadata = VideoMetadata(
            fileName: "processed.mp4",
            customName: "Processed Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 800000,
            duration: 60.0
        )
        
        let originalVideoId = UUID()
        videoMetadata.isProcessed = true
        videoMetadata.processedDate = Date()
        videoMetadata.originalVideoId = originalVideoId
        
        XCTAssertTrue(videoMetadata.isProcessed, "Processed videos should be marked as processed")
        XCTAssertNotNil(videoMetadata.processedDate, "Processed videos should have a processed date")
        XCTAssertEqual(videoMetadata.originalVideoId, originalVideoId, "Processed videos should reference original")
        XCTAssertFalse(videoMetadata.isOriginalVideo, "Processed videos should not be original videos")
        XCTAssertFalse(videoMetadata.canBeProcessed, "Processed videos should not be processable")
    }
    
    func testVideoMetadata_OriginalWithProcessedVersions() {
        var videoMetadata = VideoMetadata(
            fileName: "original.mp4",
            customName: "Original Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 2000000,
            duration: 300.0
        )
        
        let processedVideoId1 = UUID()
        let processedVideoId2 = UUID()
        videoMetadata.processedVideoIds = [processedVideoId1, processedVideoId2]
        
        XCTAssertFalse(videoMetadata.isProcessed, "Original videos with processed versions should not be marked as processed")
        XCTAssertTrue(videoMetadata.isOriginalVideo, "Videos with processed versions should still be original")
        XCTAssertFalse(videoMetadata.canBeProcessed, "Videos with processed versions should not be processable again")
        XCTAssertEqual(videoMetadata.processedVideoIds.count, 2, "Should track multiple processed versions")
    }
    
    // MARK: - MediaStore Integration Tests
    
    func testAddProcessedVideo_CreatesCorrectMetadata() throws {
        // Create a test video file
        let originalVideoPath = tempDirectory.appendingPathComponent("original.mp4")
        let testData = "test video data".data(using: .utf8)!
        try testData.write(to: originalVideoPath)
        
        // Add original video
        let originalAdded = mediaStore.addVideo(at: originalVideoPath, toFolder: "", customName: "Original Test")
        XCTAssertTrue(originalAdded, "Should successfully add original video")
        
        // Get the original video metadata
        let originalVideos = mediaStore.getVideos(in: "")
        guard let originalVideo = originalVideos.first(where: { $0.displayName == "Original Test" }) else {
            XCTFail("Original video not found in MediaStore")
            return
        }
        
        // Create a processed video file
        let processedVideoPath = tempDirectory.appendingPathComponent("processed01 Original Test.mp4")
        let processedData = "processed video data".data(using: .utf8)!
        try processedData.write(to: processedVideoPath)
        
        // Add processed video
        let processedAdded = mediaStore.addProcessedVideo(
            at: processedVideoPath,
            toFolder: "",
            customName: "Processed01 Original Test",
            originalVideoId: originalVideo.id
        )
        XCTAssertTrue(processedAdded, "Should successfully add processed video")
        
        // Verify processed video metadata
        let allVideos = mediaStore.getVideos(in: "")
        guard let processedVideo = allVideos.first(where: { $0.displayName == "Processed01 Original Test" }) else {
            XCTFail("Processed video not found in MediaStore")
            return
        }
        
        XCTAssertTrue(processedVideo.isProcessed, "Processed video should be marked as processed")
        XCTAssertNotNil(processedVideo.processedDate, "Processed video should have a processed date")
        XCTAssertEqual(processedVideo.originalVideoId, originalVideo.id, "Processed video should reference original")
        XCTAssertFalse(processedVideo.canBeProcessed, "Processed video should not be processable")
        
        // Verify original video was updated
        guard let updatedOriginal = allVideos.first(where: { $0.id == originalVideo.id }) else {
            XCTFail("Updated original video not found")
            return
        }
        
        XCTAssertTrue(updatedOriginal.processedVideoIds.contains(processedVideo.id), 
                     "Original video should reference processed version")
        XCTAssertFalse(updatedOriginal.canBeProcessed, "Original with processed versions should not be processable")
    }
    
    func testAddProcessedVideo_HandlesMultipleProcessedVersions() throws {
        // Create original video
        let originalVideoPath = tempDirectory.appendingPathComponent("original.mp4")
        let testData = "test video data".data(using: .utf8)!
        try testData.write(to: originalVideoPath)
        
        let originalAdded = mediaStore.addVideo(at: originalVideoPath, toFolder: "", customName: "Multi Test")
        XCTAssertTrue(originalAdded, "Should add original video")
        
        let originalVideo = mediaStore.getVideos(in: "").first { $0.displayName == "Multi Test" }!
        
        // Add first processed version
        let processed1Path = tempDirectory.appendingPathComponent("processed01.mp4")
        try testData.write(to: processed1Path)
        
        let processed1Added = mediaStore.addProcessedVideo(
            at: processed1Path,
            toFolder: "",
            customName: "Processed01 Multi Test",
            originalVideoId: originalVideo.id
        )
        XCTAssertTrue(processed1Added, "Should add first processed video")
        
        // Add second processed version
        let processed2Path = tempDirectory.appendingPathComponent("debug01.mp4")
        try testData.write(to: processed2Path)
        
        let processed2Added = mediaStore.addProcessedVideo(
            at: processed2Path,
            toFolder: "",
            customName: "Debug01 Multi Test",
            originalVideoId: originalVideo.id
        )
        XCTAssertTrue(processed2Added, "Should add second processed video")
        
        // Verify original tracks both processed versions
        let allVideos = mediaStore.getVideos(in: "")
        let updatedOriginal = allVideos.first { $0.id == originalVideo.id }!
        
        XCTAssertEqual(updatedOriginal.processedVideoIds.count, 2, 
                      "Original should track both processed versions")
        XCTAssertFalse(updatedOriginal.canBeProcessed, 
                      "Original with multiple processed versions should not be processable")
    }
    
    // MARK: - Edge Cases
    
    func testAddProcessedVideo_WithNonExistentOriginal() throws {
        // Create a processed video file
        let processedVideoPath = tempDirectory.appendingPathComponent("orphan.mp4")
        let testData = "orphan video data".data(using: .utf8)!
        try testData.write(to: processedVideoPath)
        
        // Try to add processed video with non-existent original ID
        let fakeOriginalId = UUID()
        let processedAdded = mediaStore.addProcessedVideo(
            at: processedVideoPath,
            toFolder: "",
            customName: "Orphan Video",
            originalVideoId: fakeOriginalId
        )
        
        XCTAssertTrue(processedAdded, "Should still add the processed video even if original not found")
        
        // Verify the processed video was added with correct metadata
        let videos = mediaStore.getVideos(in: "")
        let orphanVideo = videos.first { $0.displayName == "Orphan Video" }
        
        XCTAssertNotNil(orphanVideo, "Orphan processed video should be added")
        XCTAssertTrue(orphanVideo?.isProcessed ?? false, "Orphan video should be marked as processed")
        XCTAssertEqual(orphanVideo?.originalVideoId, fakeOriginalId, "Should maintain reference to non-existent original")
        XCTAssertFalse(orphanVideo?.canBeProcessed ?? true, "Orphan processed video should not be processable")
    }
    
    func testCanBeProcessed_Logic() {
        // Test original video (can be processed)
        let originalVideo = VideoMetadata(
            fileName: "original.mp4",
            customName: "Original",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000,
            duration: 60
        )
        XCTAssertTrue(originalVideo.canBeProcessed, "Original videos should be processable")
        
        // Test processed video (cannot be processed)
        var processedVideo = originalVideo
        processedVideo.isProcessed = true
        processedVideo.originalVideoId = UUID()
        XCTAssertFalse(processedVideo.canBeProcessed, "Processed videos should not be processable")
        
        // Test original with processed versions (cannot be processed)
        var originalWithProcessed = originalVideo
        originalWithProcessed.processedVideoIds = [UUID()]
        XCTAssertFalse(originalWithProcessed.canBeProcessed, "Originals with processed versions should not be processable")
    }
}