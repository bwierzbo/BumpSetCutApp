//
//  MediaStoreSearchTests.swift
//  BumpSetCutTests
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class MediaStoreSearchTests: XCTestCase {
    var mediaStore: MediaStore!
    
    override func setUp() async throws {
        try await super.setUp()
        mediaStore = MediaStore()
        await setupTestData()
    }
    
    override func tearDown() async throws {
        mediaStore = nil
        try await super.tearDown()
    }
    
    // MARK: - Test Data Setup
    
    private func setupTestData() async {
        // Create test folder structure
        _ = mediaStore.createFolder(name: "Sports", parentPath: "")
        _ = mediaStore.createFolder(name: "Volleyball", parentPath: "Sports")
        _ = mediaStore.createFolder(name: "Basketball", parentPath: "Sports")
        _ = mediaStore.createFolder(name: "Practice", parentPath: "Sports/Volleyball")
        _ = mediaStore.createFolder(name: "Games", parentPath: "Sports/Volleyball")
        
        // Create test videos with different properties
        let testVideos = [
            // Root folder videos
            ("intro.mov", "", "Introduction Video", 50 * 1024 * 1024), // 50MB
            ("overview.mp4", "", "App Overview", 150 * 1024 * 1024), // 150MB
            
            // Sports folder videos
            ("warm_up.mov", "Sports", "Warm Up Routine", 75 * 1024 * 1024), // 75MB
            ("cool_down.mp4", "Sports", "Cool Down Session", 100 * 1024 * 1024), // 100MB
            
            // Volleyball folder videos
            ("serve_practice.mov", "Sports/Volleyball", "Serving Practice", 200 * 1024 * 1024), // 200MB
            ("spike_training.mp4", "Sports/Volleyball", "Spike Training", 300 * 1024 * 1024), // 300MB
            
            // Basketball folder videos
            ("free_throws.mov", "Sports/Basketball", "Free Throw Practice", 180 * 1024 * 1024), // 180MB
            ("layups.mp4", "Sports/Basketball", "Layup Drills", 220 * 1024 * 1024), // 220MB
            
            // Practice subfolder videos
            ("basic_drills.mov", "Sports/Volleyball/Practice", "Basic Volleyball Drills", 400 * 1024 * 1024), // 400MB
            ("advanced_drills.mp4", "Sports/Volleyball/Practice", "Advanced Training", 500 * 1024 * 1024), // 500MB
            
            // Games subfolder videos
            ("championship.mov", "Sports/Volleyball/Games", "Championship Game", 1200 * 1024 * 1024), // 1.2GB
            ("semifinals.mp4", "Sports/Volleyball/Games", "Semifinal Match", 1100 * 1024 * 1024) // 1.1GB
        ]
        
        for (fileName, folderPath, customName, fileSize) in testVideos {
            let testURL = createTestVideoURL(fileName: fileName, fileSize: fileSize)
            _ = mediaStore.addVideo(at: testURL, toFolder: folderPath, customName: customName)
        }
    }
    
    private func createTestVideoURL(fileName: String, fileSize: Int64) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let testURL = documentsPath.appendingPathComponent(fileName)
        
        // Create test file with approximate size
        if !FileManager.default.fileExists(atPath: testURL.path) {
            let testData = Data(count: Int(min(fileSize, 1024))) // Don't actually create huge files
            FileManager.default.createFile(atPath: testURL.path, contents: testData, attributes: nil)
        }
        
        return testURL
    }
    
    // MARK: - Basic Search Tests
    
    func testBasicVideoSearch() {
        let results = mediaStore.searchVideos(query: "practice")
        
        XCTAssertFalse(results.isEmpty)
        
        let expectedMatches = ["Serving Practice", "Free Throw Practice"]
        for expectedMatch in expectedMatches {
            XCTAssertTrue(results.contains { video in
                video.displayName.localizedCaseInsensitiveContains(expectedMatch)
            }, "Should find video with name containing '\(expectedMatch)'")
        }
    }
    
    func testBasicFolderSearch() {
        let results = mediaStore.searchFolders(query: "volleyball")
        
        XCTAssertFalse(results.isEmpty)
        
        let hasVolleyballFolder = results.contains { folder in
            folder.name.localizedCaseInsensitiveContains("volleyball")
        }
        XCTAssertTrue(hasVolleyballFolder, "Should find Volleyball folder")
    }
    
    func testCaseInsensitiveSearch() {
        let uppercaseResults = mediaStore.searchVideos(query: "PRACTICE")
        let lowercaseResults = mediaStore.searchVideos(query: "practice")
        let mixedCaseResults = mediaStore.searchVideos(query: "Practice")
        
        XCTAssertEqual(uppercaseResults.count, lowercaseResults.count)
        XCTAssertEqual(lowercaseResults.count, mixedCaseResults.count)
        XCTAssertFalse(uppercaseResults.isEmpty)
    }
    
    func testEmptyQueryReturnsEmptyResults() {
        let videoResults = mediaStore.searchVideos(query: "")
        let folderResults = mediaStore.searchFolders(query: "")
        
        XCTAssertTrue(videoResults.isEmpty)
        XCTAssertTrue(folderResults.isEmpty)
    }
    
    func testSearchByFileName() {
        let results = mediaStore.searchVideos(query: "serve_practice")
        
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { video in
            video.fileName.contains("serve_practice")
        })
    }
    
    func testSearchByCustomName() {
        let results = mediaStore.searchVideos(query: "Introduction")
        
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { video in
            video.displayName.contains("Introduction")
        })
    }
    
    // MARK: - Advanced Search Tests
    
    func testAdvancedSearchWithAllFilters() {
        let results = mediaStore.advancedSearchVideos(
            query: "practice",
            fileType: "mov",
            minSize: 100 * 1024 * 1024, // 100MB
            maxSize: 500 * 1024 * 1024, // 500MB
            fromDate: Calendar.current.date(byAdding: .day, value: -1, to: Date())!, // Yesterday
            toDate: Date(),
            inFolder: "Sports"
        )
        
        // Should find videos matching all criteria
        for video in results {
            XCTAssertTrue(
                video.displayName.localizedCaseInsensitiveContains("practice") ||
                video.fileName.localizedCaseInsensitiveContains("practice"),
                "Video should match search query"
            )
            XCTAssertTrue(video.fileName.lowercased().hasSuffix(".mov"), "Video should be MOV file")
            XCTAssertGreaterThanOrEqual(video.fileSize, 100 * 1024 * 1024, "Video should be at least 100MB")
            XCTAssertLessThanOrEqual(video.fileSize, 500 * 1024 * 1024, "Video should be at most 500MB")
            XCTAssertTrue(
                video.folderPath == "Sports" || video.folderPath.hasPrefix("Sports/"),
                "Video should be in Sports folder or its subfolders"
            )
        }
    }
    
    func testAdvancedSearchWithFileTypeFilter() {
        let movResults = mediaStore.advancedSearchVideos(query: "", fileType: "mov")
        let mp4Results = mediaStore.advancedSearchVideos(query: "", fileType: "mp4")
        
        // All results should match file type
        for video in movResults {
            XCTAssertTrue(video.fileName.lowercased().hasSuffix(".mov"))
        }
        
        for video in mp4Results {
            XCTAssertTrue(video.fileName.lowercased().hasSuffix(".mp4"))
        }
        
        // Should have both types in test data
        XCTAssertFalse(movResults.isEmpty)
        XCTAssertFalse(mp4Results.isEmpty)
    }
    
    func testAdvancedSearchWithSizeFilter() {
        let smallFiles = mediaStore.advancedSearchVideos(
            query: "",
            maxSize: 100 * 1024 * 1024 // 100MB
        )
        
        let largeFiles = mediaStore.advancedSearchVideos(
            query: "",
            minSize: 1000 * 1024 * 1024 // 1GB
        )
        
        for video in smallFiles {
            XCTAssertLessThanOrEqual(video.fileSize, 100 * 1024 * 1024)
        }
        
        for video in largeFiles {
            XCTAssertGreaterThanOrEqual(video.fileSize, 1000 * 1024 * 1024)
        }
        
        XCTAssertFalse(smallFiles.isEmpty)
        XCTAssertFalse(largeFiles.isEmpty)
    }
    
    func testAdvancedSearchWithFolderFilter() {
        // Search in root folder only
        let rootResults = mediaStore.advancedSearchVideos(query: "", inFolder: "")
        
        for video in rootResults {
            XCTAssertTrue(video.folderPath.isEmpty, "Should only return root folder videos")
        }
        
        // Search in Sports folder and subfolders
        let sportsResults = mediaStore.advancedSearchVideos(query: "", inFolder: "Sports")
        
        for video in sportsResults {
            XCTAssertTrue(
                video.folderPath == "Sports" || video.folderPath.hasPrefix("Sports/"),
                "Should return Sports folder and subfolder videos"
            )
        }
        
        // Search in specific subfolder
        let volleyballResults = mediaStore.advancedSearchVideos(query: "", inFolder: "Sports/Volleyball")
        
        for video in volleyballResults {
            XCTAssertTrue(
                video.folderPath == "Sports/Volleyball" || video.folderPath.hasPrefix("Sports/Volleyball/"),
                "Should return Volleyball folder and subfolder videos"
            )
        }
        
        XCTAssertFalse(rootResults.isEmpty)
        XCTAssertFalse(sportsResults.isEmpty)
        XCTAssertFalse(volleyballResults.isEmpty)
        
        // Sports results should include volleyball results
        XCTAssertGreaterThanOrEqual(sportsResults.count, volleyballResults.count)
    }
    
    func testAdvancedSearchWithDateFilter() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        
        // Search for videos created today or later
        let recentResults = mediaStore.advancedSearchVideos(
            query: "",
            fromDate: yesterday
        )
        
        // Should find all test videos (they were just created)
        XCTAssertFalse(recentResults.isEmpty)
        
        for video in recentResults {
            XCTAssertGreaterThanOrEqual(video.createdDate, yesterday)
        }
        
        // Search for videos created before tomorrow (should find all)
        let beforeTomorrowResults = mediaStore.advancedSearchVideos(
            query: "",
            toDate: tomorrow
        )
        
        XCTAssertFalse(beforeTomorrowResults.isEmpty)
        
        for video in beforeTomorrowResults {
            XCTAssertLessThanOrEqual(video.createdDate, tomorrow)
        }
        
        // Search for videos created in future (should find none)
        let futureResults = mediaStore.advancedSearchVideos(
            query: "",
            fromDate: tomorrow
        )
        
        XCTAssertTrue(futureResults.isEmpty)
    }
    
    // MARK: - Get All Items Tests
    
    func testGetAllFolders() {
        let allFolders = mediaStore.getAllFolders()
        
        XCTAssertFalse(allFolders.isEmpty)
        
        // Should contain all created folders
        let expectedFolders = ["Sports", "Volleyball", "Basketball", "Practice", "Games"]
        for expectedFolder in expectedFolders {
            XCTAssertTrue(allFolders.contains { folder in
                folder.name == expectedFolder
            }, "Should contain folder named '\(expectedFolder)'")
        }
    }
    
    func testGetAllVideos() {
        let allVideos = mediaStore.getAllVideos()
        
        XCTAssertFalse(allVideos.isEmpty)
        
        // Should contain all created videos
        let expectedVideoNames = ["Introduction Video", "App Overview", "Serving Practice", "Championship Game"]
        for expectedName in expectedVideoNames {
            XCTAssertTrue(allVideos.contains { video in
                video.displayName == expectedName
            }, "Should contain video named '\(expectedName)'")
        }
    }
    
    // MARK: - Search Performance Tests
    
    func testSearchPerformanceWithManyResults() {
        // Add more test data
        for i in 0..<50 {
            let fileName = "performance_test_\(i).mov"
            let testURL = createTestVideoURL(fileName: fileName, fileSize: 100 * 1024 * 1024)
            _ = mediaStore.addVideo(at: testURL, toFolder: "Sports", customName: "Performance Test \(i)")
        }
        
        measure {
            let results = mediaStore.searchVideos(query: "test")
            XCTAssertGreaterThanOrEqual(results.count, 50)
        }
    }
    
    func testAdvancedSearchPerformance() {
        measure {
            let results = mediaStore.advancedSearchVideos(
                query: "practice",
                fileType: "mov",
                minSize: 50 * 1024 * 1024,
                maxSize: 1000 * 1024 * 1024,
                fromDate: Calendar.current.date(byAdding: .day, value: -7, to: Date())!,
                toDate: Date(),
                inFolder: "Sports"
            )
            
            // Verify we get some results
            XCTAssertFalse(results.isEmpty)
        }
    }
    
    // MARK: - Edge Cases
    
    func testSearchWithSpecialCharacters() {
        // Add video with special characters
        let specialURL = createTestVideoURL(fileName: "special-test_file.mov", fileSize: 100 * 1024 * 1024)
        _ = mediaStore.addVideo(at: specialURL, toFolder: "", customName: "Special Test: File (2024)")
        
        let results1 = mediaStore.searchVideos(query: "special-test")
        let results2 = mediaStore.searchVideos(query: "Special Test:")
        let results3 = mediaStore.searchVideos(query: "(2024)")
        
        XCTAssertFalse(results1.isEmpty)
        XCTAssertFalse(results2.isEmpty)
        XCTAssertFalse(results3.isEmpty)
    }
    
    func testSearchWithUnicodeCharacters() {
        // Add video with unicode characters
        let unicodeURL = createTestVideoURL(fileName: "unicode_test.mov", fileSize: 100 * 1024 * 1024)
        _ = mediaStore.addVideo(at: unicodeURL, toFolder: "", customName: "Tëst Vidéo with Ünicodé")
        
        let results1 = mediaStore.searchVideos(query: "Tëst")
        let results2 = mediaStore.searchVideos(query: "Vidéo")
        let results3 = mediaStore.searchVideos(query: "Ünicodé")
        
        XCTAssertFalse(results1.isEmpty)
        XCTAssertFalse(results2.isEmpty)
        XCTAssertFalse(results3.isEmpty)
    }
    
    func testSearchWithVeryLongQuery() {
        let longQuery = String(repeating: "very long search query that exceeds normal length ", count: 10)
        
        let results = mediaStore.searchVideos(query: longQuery)
        
        // Should handle long queries without crashing
        XCTAssertTrue(results.isEmpty) // No matches expected for this long nonsense query
    }
}