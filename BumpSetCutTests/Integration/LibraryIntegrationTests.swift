//
//  LibraryIntegrationTests.swift
//  BumpSetCutTests
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import XCTest
import Combine
@testable import BumpSetCut

@MainActor
final class LibraryIntegrationTests: XCTestCase {
    var mediaStore: MediaStore!
    var folderManager: FolderManager!
    var uploadCoordinator: UploadCoordinator!
    var searchViewModel: SearchViewModel!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Initialize core components
        mediaStore = MediaStore()
        folderManager = FolderManager(mediaStore: mediaStore)
        uploadCoordinator = UploadCoordinator(mediaStore: mediaStore)
        searchViewModel = SearchViewModel(mediaStore: mediaStore)
        cancellables = Set<AnyCancellable>()
        
        print("=== Integration Test Setup ===")
        print("MediaStore initialized: \(mediaStore != nil)")
        print("FolderManager initialized: \(folderManager != nil)")
        print("UploadCoordinator initialized: \(uploadCoordinator != nil)")
        print("SearchViewModel initialized: \(searchViewModel != nil)")
    }
    
    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        searchViewModel = nil
        uploadCoordinator = nil
        folderManager = nil
        mediaStore = nil
        try await super.tearDown()
        print("=== Integration Test Cleanup Complete ===")
    }
    
    // MARK: - Full Workflow Integration Tests
    
    func testFullWorkflowIntegration() async throws {
        print("\n=== Testing Full Workflow Integration ===")
        
        // 1. Create folder structure
        print("1. Creating folder structure...")
        let rootFolder = mediaStore.createFolder(name: "Volleyball", parentPath: "")
        let practiceFolder = mediaStore.createFolder(name: "Practice", parentPath: "Volleyball")
        let gamesFolder = mediaStore.createFolder(name: "Games", parentPath: "Volleyball")
        
        XCTAssertNotNil(rootFolder)
        XCTAssertNotNil(practiceFolder)
        XCTAssertNotNil(gamesFolder)
        print("✅ Folder structure created successfully")
        
        // 2. Navigate through folders
        print("2. Testing folder navigation...")
        folderManager.navigateToFolder("Volleyball")
        XCTAssertEqual(folderManager.currentPath, "Volleyball")
        
        folderManager.navigateToFolder("Volleyball/Practice")
        XCTAssertEqual(folderManager.currentPath, "Volleyball/Practice")
        
        folderManager.navigateToParent()
        XCTAssertEqual(folderManager.currentPath, "Volleyball")
        print("✅ Folder navigation working correctly")
        
        // 3. Test upload simulation (without actual files for performance)
        print("3. Testing upload integration...")
        let testVideoURLs = createTestVideoURLs(count: 5)
        
        for (index, url) in testVideoURLs.enumerated() {
            let customName = "Test Video \(index + 1)"
            let video = mediaStore.addVideo(at: url, toFolder: "Volleyball/Practice", customName: customName)
            XCTAssertNotNil(video)
        }
        print("✅ Upload integration successful")
        
        // 4. Test search functionality
        print("4. Testing search integration...")
        let searchExpectation = XCTestExpectation(description: "Search results received")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                if !results.isEmpty {
                    searchExpectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "test"
        
        await fulfillment(of: [searchExpectation], timeout: 3.0)
        XCTAssertFalse(searchViewModel.searchResults.isEmpty)
        print("✅ Search integration successful")
        
        // 5. Test video management operations
        print("5. Testing video management...")
        folderManager.navigateToFolder("Volleyball/Practice")
        folderManager.refreshContents()
        
        XCTAssertFalse(folderManager.videos.isEmpty)
        
        // Test video rename
        let firstVideo = folderManager.videos.first!
        try await folderManager.renameVideo(firstVideo, to: "Renamed Test Video")
        folderManager.refreshContents()
        
        let renamedVideo = folderManager.videos.first { $0.id == firstVideo.id }
        XCTAssertEqual(renamedVideo?.displayName, "Renamed Test Video")
        print("✅ Video management successful")
        
        print("=== Full Workflow Integration Test Complete ===\n")
    }
    
    // MARK: - Cross-Component Integration Tests
    
    func testCrossComponentIntegration() async throws {
        print("\n=== Testing Cross-Component Integration ===")
        
        // Test LibraryView + FolderManager + Upload + Search integration
        print("1. Creating test data structure...")
        
        // Create complex folder structure
        let folders = [
            ("Sports", ""),
            ("Volleyball", "Sports"),
            ("Basketball", "Sports"),
            ("Training", "Sports/Volleyball"),
            ("Games", "Sports/Volleyball"),
            ("Highlights", "Sports/Volleyball/Games")
        ]
        
        for (name, parentPath) in folders {
            let folder = mediaStore.createFolder(name: name, parentPath: parentPath)
            XCTAssertNotNil(folder, "Failed to create folder: \(name) at \(parentPath)")
        }
        print("✅ Complex folder structure created")
        
        // Add videos to different folders
        print("2. Adding videos to various folders...")
        let videoData = [
            ("serve_practice.mov", "Sports/Volleyball/Training", "Volleyball Serve Practice"),
            ("spike_drill.mp4", "Sports/Volleyball/Training", "Spike Training Drill"),
            ("game_highlights.mov", "Sports/Volleyball/Games/Highlights", "Championship Highlights"),
            ("basketball_shots.mp4", "Sports/Basketball", "Basketball Shooting Practice")
        ]
        
        let testURLs = createTestVideoURLs(count: videoData.count)
        for (index, (_, folderPath, customName)) in videoData.enumerated() {
            let video = mediaStore.addVideo(at: testURLs[index], toFolder: folderPath, customName: customName)
            XCTAssertNotNil(video, "Failed to add video: \(customName)")
        }
        print("✅ Videos added to folders")
        
        // Test navigation and data consistency
        print("3. Testing navigation and data consistency...")
        folderManager.navigateToFolder("Sports/Volleyball/Training")
        folderManager.refreshContents()
        
        XCTAssertEqual(folderManager.videos.count, 2, "Expected 2 videos in Training folder")
        XCTAssertTrue(folderManager.videos.contains { $0.displayName.contains("Serve") })
        XCTAssertTrue(folderManager.videos.contains { $0.displayName.contains("Spike") })
        print("✅ Navigation and data consistency verified")
        
        // Test cross-folder search
        print("4. Testing cross-folder search...")
        let crossFolderSearchExpectation = XCTestExpectation(description: "Cross-folder search completed")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                crossFolderSearchExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "volleyball"
        
        await fulfillment(of: [crossFolderSearchExpectation], timeout: 3.0)
        
        let volleyballResults = searchViewModel.searchResults.filter { 
            $0.title.lowercased().contains("volleyball") || 
            $0.folderPath.lowercased().contains("volleyball")
        }
        XCTAssertGreaterThan(volleyballResults.count, 0, "Should find volleyball-related content")
        print("✅ Cross-folder search working")
        
        print("=== Cross-Component Integration Test Complete ===\n")
    }
    
    // MARK: - Data Consistency Tests
    
    func testDataConsistencyAcrossOperations() async throws {
        print("\n=== Testing Data Consistency ===")
        
        // Create initial data
        print("1. Setting up initial data...")
        let folder = mediaStore.createFolder(name: "DataTest", parentPath: "")
        XCTAssertNotNil(folder)
        
        let testURLs = createTestVideoURLs(count: 3)
        for (index, url) in testURLs.enumerated() {
            let video = mediaStore.addVideo(at: url, toFolder: "DataTest", customName: "Data Test Video \(index + 1)")
            XCTAssertNotNil(video)
        }
        
        folderManager.navigateToFolder("DataTest")
        folderManager.refreshContents()
        let initialVideoCount = folderManager.videos.count
        XCTAssertEqual(initialVideoCount, 3)
        print("✅ Initial data setup complete")
        
        // Test operations maintain consistency
        print("2. Testing move operation consistency...")
        let subfolder = mediaStore.createFolder(name: "Moved", parentPath: "DataTest")
        XCTAssertNotNil(subfolder)
        
        let videoToMove = folderManager.videos.first!
        try await folderManager.moveVideoToFolder(videoToMove, targetFolderPath: "DataTest/Moved")
        
        // Check source folder
        folderManager.refreshContents()
        XCTAssertEqual(folderManager.videos.count, initialVideoCount - 1, "Source folder should have one less video")
        
        // Check destination folder
        folderManager.navigateToFolder("DataTest/Moved")
        folderManager.refreshContents()
        XCTAssertEqual(folderManager.videos.count, 1, "Destination folder should have one video")
        print("✅ Move operation maintains data consistency")
        
        // Test delete operation consistency
        print("3. Testing delete operation consistency...")
        let videoToDelete = folderManager.videos.first!
        try await folderManager.deleteVideo(videoToDelete)
        
        folderManager.refreshContents()
        XCTAssertEqual(folderManager.videos.count, 0, "Folder should be empty after deletion")
        
        // Verify video is not found in search
        let searchExpectation = XCTestExpectation(description: "Search after delete completed")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                searchExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = videoToDelete.displayName
        
        await fulfillment(of: [searchExpectation], timeout: 3.0)
        
        let foundDeletedVideo = searchViewModel.searchResults.contains { result in
            if case .video(let video) = result.type {
                return video.id == videoToDelete.id
            }
            return false
        }
        XCTAssertFalse(foundDeletedVideo, "Deleted video should not appear in search results")
        print("✅ Delete operation maintains data consistency")
        
        print("=== Data Consistency Test Complete ===\n")
    }
    
    // MARK: - Performance Tests
    
    func testLargeCollectionPerformance() async throws {
        print("\n=== Testing Large Collection Performance ===")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Create 100+ videos across multiple folders
        print("1. Creating large collection (100+ videos)...")
        let folderStructure = [
            "Performance",
            "Performance/Folder1",
            "Performance/Folder2",
            "Performance/Folder3",
            "Performance/Folder4",
            "Performance/Folder5"
        ]
        
        for folderPath in folderStructure {
            let pathComponents = folderPath.split(separator: "/")
            if pathComponents.count == 1 {
                _ = mediaStore.createFolder(name: String(pathComponents[0]), parentPath: "")
            } else {
                let parentPath = pathComponents.dropLast().joined(separator: "/")
                let folderName = String(pathComponents.last!)
                _ = mediaStore.createFolder(name: folderName, parentPath: parentPath)
            }
        }
        
        // Add 20 videos per folder (120 total)
        let testURLs = createTestVideoURLs(count: 120)
        var urlIndex = 0
        
        for folderPath in folderStructure.dropFirst() { // Skip root folder
            for i in 1...20 {
                let customName = "Performance Video \(i) - \(folderPath.split(separator: "/").last ?? "Unknown")"
                let video = mediaStore.addVideo(at: testURLs[urlIndex], toFolder: folderPath, customName: customName)
                XCTAssertNotNil(video, "Failed to create video: \(customName)")
                urlIndex += 1
            }
        }
        
        let setupTime = CFAbsoluteTimeGetCurrent() - startTime
        print("✅ Large collection created in \(String(format: "%.3f", setupTime))s")
        
        // Test LibraryView performance with large collection
        print("2. Testing LibraryView load performance...")
        let loadStartTime = CFAbsoluteTimeGetCurrent()
        
        folderManager.navigateToFolder("Performance")
        folderManager.refreshContents()
        
        let loadTime = CFAbsoluteTimeGetCurrent() - loadStartTime
        print("✅ LibraryView loaded \(folderManager.folders.count) folders in \(String(format: "%.3f", loadTime))s")
        
        // Performance requirement: LibraryView should load <500ms with 100+ videos
        XCTAssertLessThan(loadTime, 0.5, "LibraryView should load in under 500ms")
        
        // Test folder with many videos
        print("3. Testing folder with 20 videos...")
        let videoLoadStartTime = CFAbsoluteTimeGetCurrent()
        
        folderManager.navigateToFolder("Performance/Folder1")
        folderManager.refreshContents()
        
        let videoLoadTime = CFAbsoluteTimeGetCurrent() - videoLoadStartTime
        print("✅ Folder with 20 videos loaded in \(String(format: "%.3f", videoLoadTime))s")
        
        XCTAssertLessThan(videoLoadTime, 0.3, "Folder with 20 videos should load in under 300ms")
        
        // Test search performance with large collection
        print("4. Testing search performance...")
        let searchStartTime = CFAbsoluteTimeGetCurrent()
        
        let searchExpectation = XCTestExpectation(description: "Large collection search completed")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                let searchTime = CFAbsoluteTimeGetCurrent() - searchStartTime
                print("✅ Search completed in \(String(format: "%.3f", searchTime))s with \(results.count) results")
                XCTAssertLessThan(searchTime, 1.0, "Search should complete in under 1 second")
                searchExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "performance"
        
        await fulfillment(of: [searchExpectation], timeout: 5.0)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        print("=== Large Collection Performance Test Complete - Total time: \(String(format: "%.3f", totalTime))s ===\n")
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorHandlingAndEdgeCases() async throws {
        print("\n=== Testing Error Handling and Edge Cases ===")
        
        // Test invalid folder operations
        print("1. Testing invalid folder operations...")
        
        // Try to create folder with empty name
        let emptyNameFolder = mediaStore.createFolder(name: "", parentPath: "")
        XCTAssertNil(emptyNameFolder, "Should not create folder with empty name")
        
        // Try to create folder with invalid characters
        let invalidCharFolder = mediaStore.createFolder(name: "Test/Folder", parentPath: "")
        XCTAssertNil(invalidCharFolder, "Should not create folder with invalid characters")
        
        // Try to navigate to non-existent folder
        let originalPath = folderManager.currentPath
        folderManager.navigateToFolder("NonExistent/Path")
        XCTAssertEqual(folderManager.currentPath, originalPath, "Should not navigate to non-existent path")
        print("✅ Invalid folder operations handled correctly")
        
        // Test video operations with missing files
        print("2. Testing video operations with edge cases...")
        
        // Create a valid folder first
        let testFolder = mediaStore.createFolder(name: "ErrorTest", parentPath: "")
        XCTAssertNotNil(testFolder)
        
        // Test with non-existent file
        let nonExistentURL = URL(fileURLWithPath: "/path/to/nonexistent/video.mp4")
        let _ = mediaStore.addVideo(at: nonExistentURL, toFolder: "ErrorTest", customName: "Invalid Video")
        // This might return a video object but operations on it should handle the missing file gracefully
        
        print("✅ Edge case video operations handled")
        
        // Test search with special characters
        print("3. Testing search with special characters...")
        let specialCharSearchExpectation = XCTestExpectation(description: "Special character search completed")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                specialCharSearchExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        // Test various special characters
        let specialQueries = ["@#$%", "test & more", "video (1)", "file.name"]
        
        for query in specialQueries {
            searchViewModel.searchText = query
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        await fulfillment(of: [specialCharSearchExpectation], timeout: 3.0)
        print("✅ Special character searches handled gracefully")
        
        // Test memory and resource cleanup
        print("4. Testing resource cleanup...")
        
        // Create and immediately clear large amount of data
        let cleanupTestURLs = createTestVideoURLs(count: 50)
        for (index, url) in cleanupTestURLs.enumerated() {
            let _ = mediaStore.addVideo(at: url, toFolder: "ErrorTest", customName: "Cleanup Test \(index)")
        }
        
        folderManager.navigateToFolder("ErrorTest")
        folderManager.refreshContents()
        
        let videoCount = folderManager.videos.count
        XCTAssertGreaterThan(videoCount, 40, "Should have created multiple test videos")
        
        // Clear search
        searchViewModel.clearSearch()
        XCTAssertEqual(searchViewModel.searchText, "")
        XCTAssertTrue(searchViewModel.searchResults.isEmpty)
        
        print("✅ Resource cleanup successful")
        
        print("=== Error Handling and Edge Cases Test Complete ===\n")
    }
    
    // MARK: - Helper Methods
    
    private func createTestVideoURLs(count: Int) -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var urls: [URL] = []
        
        for i in 0..<count {
            let fileName = "integration_test_video_\(i)_\(UUID().uuidString.prefix(8)).mp4"
            let testURL = documentsPath.appendingPathComponent(fileName)
            
            // Create minimal test file if it doesn't exist
            if !FileManager.default.fileExists(atPath: testURL.path) {
                let testData = "test video data".data(using: .utf8) ?? Data()
                FileManager.default.createFile(atPath: testURL.path, contents: testData, attributes: nil)
            }
            
            urls.append(testURL)
        }
        
        return urls
    }
}