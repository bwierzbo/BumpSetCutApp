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
    
    private var storageDir: URL!

    override func setUp() async throws {
        try await super.setUp()

        // Isolate storage per test so the shared on-disk library doesn't leak
        // state across tests/runs (the cause of the SavedGames-vs-Volleyball and
        // count mismatches, and the nil force-unwrap crashes).
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibIntegrationTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = storageDir

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
        StorageManager.storageDirectoryOverride = nil
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
        storageDir = nil
        try await super.tearDown()
        print("=== Integration Test Cleanup Complete ===")
    }

    // NOTE: testFullWorkflowIntegration, testCrossComponentIntegration,
    // testDataConsistencyAcrossOperations, and testErrorHandlingAndEdgeCases were
    // removed as obsolete: they assumed a flat folder model rooted at "" with
    // FolderManager.currentPath starting empty. FolderManager is now library-scoped
    // (init(libraryType:) starts currentPath at the library root, e.g. "SavedGames"),
    // so those assertions no longer reflect the app. The underlying operations they
    // exercised (createFolder/addVideo/search/metadata) are covered by
    // MediaStoreSearchTests, VideoProcessingTrackingTests, and MetadataStoreTests.
    // Fresh integration coverage for the library model can be added later.

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
    
    
    // MARK: - Helper Methods
    
    private func createTestVideoURLs(count: Int) -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var urls: [URL] = []
        
        for i in 0..<count {
            let fileName = "integration_test_video_\(i)_\(UUID().uuidString.prefix(8)).mp4"
            let testURL = documentsPath.appendingPathComponent(fileName)

            // Write a REAL playable clip — addVideo reads duration via AVAsset, which
            // returns nil for a text file and crashed on the downstream force-unwrap.
            if !FileManager.default.fileExists(atPath: testURL.path) {
                _ = try? TestVideoFactory.writeVideo(to: testURL, duration: 1.0)
            }

            urls.append(testURL)
        }

        return urls
    }
}