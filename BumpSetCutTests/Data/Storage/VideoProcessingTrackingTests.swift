//
//  VideoProcessingTrackingTests.swift
//  BumpSetCutTests
//
//  Created by Benjamin Wierzbanowski on 9/4/25.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class VideoProcessingTrackingTests: XCTestCase {

    var mediaStore: MediaStore!
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()

        // Create a temporary directory for test files
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Initialize MediaStore (uses its own persistent storage)
        mediaStore = MediaStore()
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

    // MARK: - Metadata Support Tests

    func testVideoMetadata_DefaultMetadataProperties() {
        let videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )

        XCTAssertFalse(videoMetadata.hasProcessingMetadata, "New videos should not have processing metadata flag set")
        XCTAssertNil(videoMetadata.metadataCreatedDate, "New videos should not have metadata created date")
        XCTAssertNil(videoMetadata.metadataFileSize, "New videos should not have metadata file size")
    }

    func testVideoMetadata_MetadataFilePath() {
        let _ = UUID()
        var videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )

        // Manually set the ID to test path generation
        videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )

        let expectedPath = StorageManager.getPersistentStorageDirectory()
            .appendingPathComponent("ProcessedMetadata", isDirectory: true)
            .appendingPathComponent("\(videoMetadata.id.uuidString).json")

        XCTAssertEqual(videoMetadata.metadataFilePath, expectedPath, "Metadata file path should match expected pattern")
    }

    func testVideoMetadata_HasMetadataProperty() {
        let videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )

        // Initially should have no metadata
        XCTAssertFalse(videoMetadata.hasMetadata, "Video without metadata file should return false for hasMetadata")

        // This property checks actual file existence, so without creating a file it should be false
        // The file doesn't exist in our test, so this validates the file existence check
    }

    func testVideoMetadata_UpdateMetadataTracking() {
        var videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )

        // Update metadata tracking
        let testFileSize: Int64 = 5120
        videoMetadata.updateMetadataTracking(fileSize: testFileSize)

        XCTAssertTrue(videoMetadata.hasProcessingMetadata, "Should set processing metadata flag to true")
        XCTAssertNotNil(videoMetadata.metadataCreatedDate, "Should set metadata created date")
        XCTAssertEqual(videoMetadata.metadataFileSize, testFileSize, "Should set metadata file size")

        // Verify the created date is recent (within last second)
        let timeDifference = Date().timeIntervalSince(videoMetadata.metadataCreatedDate!)
        XCTAssertLessThan(timeDifference, 1.0, "Metadata created date should be recent")
    }

    func testVideoMetadata_ClearMetadataTracking() {
        var videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )

        // Set metadata tracking first
        videoMetadata.updateMetadataTracking(fileSize: 1024)
        XCTAssertTrue(videoMetadata.hasProcessingMetadata, "Should have metadata tracking set")

        // Clear metadata tracking
        videoMetadata.clearMetadataTracking()

        XCTAssertFalse(videoMetadata.hasProcessingMetadata, "Should clear processing metadata flag")
        XCTAssertNil(videoMetadata.metadataCreatedDate, "Should clear metadata created date")
        XCTAssertNil(videoMetadata.metadataFileSize, "Should clear metadata file size")
    }

    func testVideoMetadata_GetCurrentMetadataSize() throws {
        let videoMetadata = VideoMetadata(
            fileName: "test.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: 1000000,
            duration: 120.0
        )

        // Should return nil when no metadata file exists
        XCTAssertNil(videoMetadata.getCurrentMetadataSize(), "Should return nil when no metadata file exists")

        // Test with actual metadata file
        let metadataDirectory = StorageManager.getPersistentStorageDirectory()
            .appendingPathComponent("ProcessedMetadata", isDirectory: true)

        // Create the metadata directory if it doesn't exist
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true, attributes: nil)

        // Create a test metadata file
        let testMetadata = "{ \"test\": \"metadata\" }".data(using: .utf8)!
        let metadataFilePath = videoMetadata.metadataFilePath
        try testMetadata.write(to: metadataFilePath)

        // Now the method should return the file size
        let retrievedSize = videoMetadata.getCurrentMetadataSize()
        XCTAssertEqual(retrievedSize, Int64(testMetadata.count), "Should return actual file size when metadata exists")

        // Clean up test file
        try? FileManager.default.removeItem(at: metadataFilePath)
    }

    // MARK: - Backwards Compatibility Tests

    func testVideoMetadata_BackwardsCompatibleDecoding() throws {
        // Create JSON data without metadata fields (simulating old format)
        let oldFormatJSON = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "fileName": "old_video.mp4",
            "customName": "Old Video",
            "folderPath": "test_folder",
            "createdDate": "2023-01-01T12:00:00Z",
            "fileSize": 1024000,
            "duration": 60.0,
            "isProcessed": false,
            "processedVideoIds": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Should decode successfully with defaults for new fields
        let decodedVideo = try decoder.decode(VideoMetadata.self, from: oldFormatJSON)

        XCTAssertEqual(decodedVideo.fileName, "old_video.mp4", "Should decode old fields correctly")
        XCTAssertFalse(decodedVideo.hasProcessingMetadata, "Should default to false for missing hasProcessingMetadata")
        XCTAssertNil(decodedVideo.metadataCreatedDate, "Should default to nil for missing metadataCreatedDate")
        XCTAssertNil(decodedVideo.metadataFileSize, "Should default to nil for missing metadataFileSize")
    }

    func testVideoMetadata_NewFormatEncodingDecoding() throws {
        var originalVideo = VideoMetadata(
            fileName: "new_video.mp4",
            customName: "New Video",
            folderPath: "test_folder",
            createdDate: Date(),
            fileSize: 2048000,
            duration: 120.0
        )

        // Set metadata tracking
        originalVideo.updateMetadataTracking(fileSize: 5120)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedData = try encoder.encode(originalVideo)

        // Decode back
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedVideo = try decoder.decode(VideoMetadata.self, from: encodedData)

        // Verify all fields are preserved
        XCTAssertEqual(decodedVideo.id, originalVideo.id, "Should preserve video ID")
        XCTAssertEqual(decodedVideo.fileName, originalVideo.fileName, "Should preserve file name")
        XCTAssertTrue(decodedVideo.hasProcessingMetadata, "Should preserve metadata tracking flag")
        XCTAssertEqual(decodedVideo.metadataFileSize, originalVideo.metadataFileSize, "Should preserve metadata file size")
        XCTAssertNotNil(decodedVideo.metadataCreatedDate, "Should preserve metadata created date")

        // Verify computed properties work correctly
        XCTAssertEqual(decodedVideo.metadataFilePath, originalVideo.metadataFilePath, "Should compute same metadata path")
    }
}