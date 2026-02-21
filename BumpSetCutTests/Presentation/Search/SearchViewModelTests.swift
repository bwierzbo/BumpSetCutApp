//
//  SearchViewModelTests.swift
//  BumpSetCutTests
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import XCTest
import Combine
@testable import BumpSetCut

@MainActor
final class SearchViewModelTests: XCTestCase {
    var mediaStore: MediaStore!
    var searchViewModel: SearchViewModel!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        mediaStore = MediaStore()
        searchViewModel = SearchViewModel(mediaStore: mediaStore)
        cancellables = Set<AnyCancellable>()
        
        // Add test data
        await setupTestData()
    }
    
    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        searchViewModel = nil
        mediaStore = nil
        try await super.tearDown()
    }
    
    // MARK: - Test Data Setup
    
    private func setupTestData() async {
        // Create test folders
        _ = mediaStore.createFolder(name: "Volleyball", parentPath: "")
        _ = mediaStore.createFolder(name: "Practice", parentPath: "Volleyball")
        _ = mediaStore.createFolder(name: "Games", parentPath: "Volleyball")
        _ = mediaStore.createFolder(name: "Basketball", parentPath: "")
        
        // Create test videos
        let testVideos = [
            ("volleyball_serve.mov", "Volleyball", "Volleyball Serve Practice"),
            ("spike_training.mp4", "Volleyball/Practice", "Spike Training Session"),
            ("game_highlights.mov", "Volleyball/Games", "Championship Game Highlights"),
            ("basketball_shots.mp4", "Basketball", "Basketball Free Throws"),
            ("team_practice.mov", "", "Team Practice Video")
        ]
        
        for (fileName, folderPath, customName) in testVideos {
            let testURL = createTestVideoURL(fileName: fileName)
            _ = mediaStore.addVideo(at: testURL, toFolder: folderPath, customName: customName)
        }
    }
    
    private func createTestVideoURL(fileName: String) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let testURL = documentsPath.appendingPathComponent(fileName)
        
        // Create empty test file if it doesn't exist
        if !FileManager.default.fileExists(atPath: testURL.path) {
            FileManager.default.createFile(atPath: testURL.path, contents: Data(), attributes: nil)
        }
        
        return testURL
    }
    
    // MARK: - Basic Search Tests
    
    func testSearchInitialState() {
        XCTAssertEqual(searchViewModel.searchText, "")
        XCTAssertFalse(searchViewModel.isSearching)
        XCTAssertTrue(searchViewModel.searchResults.isEmpty)
        XCTAssertEqual(searchViewModel.sortOption, .relevance)
        XCTAssertTrue(searchViewModel.activeQuickFilters.isEmpty)
    }
    
    func testEmptySearchReturnsNoResults() async {
        searchViewModel.searchText = ""
        
        // Wait for debounce
        try? await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds
        
        XCTAssertTrue(searchViewModel.searchResults.isEmpty)
        XCTAssertFalse(searchViewModel.isSearching)
    }
    
    func testBasicVideoSearch() async {
        let expectation = XCTestExpectation(description: "Search completes")
        
        searchViewModel.$searchResults
            .dropFirst() // Skip initial empty state
            .sink { results in
                if !results.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "volleyball"
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertFalse(searchViewModel.searchResults.isEmpty)
        XCTAssertTrue(searchViewModel.searchResults.contains { result in
            result.title.lowercased().contains("volleyball")
        })
    }
    
    func testCaseInsensitiveSearch() async {
        let expectation = XCTestExpectation(description: "Case insensitive search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                if !results.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "VOLLEYBALL"
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertFalse(searchViewModel.searchResults.isEmpty)
        let hasVolleyballResult = searchViewModel.searchResults.contains { result in
            result.title.lowercased().contains("volleyball")
        }
        XCTAssertTrue(hasVolleyballResult)
    }
    
    func testPartialMatchSearch() async {
        let expectation = XCTestExpectation(description: "Partial match search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                if !results.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "pract"
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertFalse(searchViewModel.searchResults.isEmpty)
        let hasPracticeResult = searchViewModel.searchResults.contains { result in
            result.title.lowercased().contains("practice") || result.folderPath.lowercased().contains("practice")
        }
        XCTAssertTrue(hasPracticeResult)
    }
    
    // MARK: - Filter Tests
    
    func testFileTypeFilter() async {
        // First search to get all results
        let allResultsExpectation = XCTestExpectation(description: "All results loaded")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                if !results.isEmpty {
                    allResultsExpectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "video"
        await fulfillment(of: [allResultsExpectation], timeout: 2.0)
        
        let allResultsCount = searchViewModel.searchResults.count
        
        // Apply MOV filter
        let movFilterExpectation = XCTestExpectation(description: "MOV filter applied")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                movFilterExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchFilter.fileType = .mov
        
        await fulfillment(of: [movFilterExpectation], timeout: 2.0)
        
        let movResultsCount = searchViewModel.searchResults.count
        XCTAssertLessThanOrEqual(movResultsCount, allResultsCount)
        
        // Verify all results are MOV files
        for result in searchViewModel.searchResults {
            if case .video(let video) = result.type {
                XCTAssertTrue(video.fileName.lowercased().hasSuffix(".mov"))
            }
        }
    }
    
    func testDateRangeFilter() async {
        let expectation = XCTestExpectation(description: "Date filter search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "video"
        searchViewModel.searchFilter.dateRange = .today
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        // All test videos should be created today, so we should have results
        XCTAssertFalse(searchViewModel.searchResults.isEmpty)
        
        for result in searchViewModel.searchResults {
            if case .video(let video) = result.type {
                XCTAssertTrue(Calendar.current.isDateInToday(video.createdDate))
            }
        }
    }
    
    func testFolderDepthFilter() async {
        let expectation = XCTestExpectation(description: "Folder depth filter search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "video"
        searchViewModel.searchFilter.folderDepth = .root
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        // Should only return videos in root folder
        for result in searchViewModel.searchResults {
            if case .video(let video) = result.type {
                XCTAssertTrue(video.folderPath.isEmpty)
            }
        }
    }
    
    // MARK: - Sorting Tests
    
    func testRelevanceSorting() async {
        let expectation = XCTestExpectation(description: "Relevance sort search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "volleyball"
        searchViewModel.sortOption = .relevance
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertFalse(searchViewModel.searchResults.isEmpty)
        
        // Results should be sorted by relevance score (descending)
        var previousScore: Double = Double.greatestFiniteMagnitude
        for result in searchViewModel.searchResults {
            XCTAssertLessThanOrEqual(result.relevanceScore, previousScore)
            previousScore = result.relevanceScore
        }
    }
    
    func testNameSorting() async {
        let expectation = XCTestExpectation(description: "Name sort search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "video"
        searchViewModel.sortOption = .name
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertFalse(searchViewModel.searchResults.isEmpty)
        
        // Results should be sorted by name (ascending)
        var previousName: String = ""
        for result in searchViewModel.searchResults {
            XCTAssertTrue(result.title.localizedCaseInsensitiveCompare(previousName) != .orderedAscending)
            previousName = result.title
        }
    }
    
    // MARK: - Quick Filter Tests
    
    func testQuickFilterToggle() {
        XCTAssertTrue(searchViewModel.activeQuickFilters.isEmpty)
        
        searchViewModel.toggleQuickFilter(.recentVideos)
        XCTAssertTrue(searchViewModel.activeQuickFilters.contains(.recentVideos))
        
        searchViewModel.toggleQuickFilter(.recentVideos)
        XCTAssertFalse(searchViewModel.activeQuickFilters.contains(.recentVideos))
    }
    
    func testQuickFilterApplication() {
        searchViewModel.toggleQuickFilter(.movFiles)
        XCTAssertEqual(searchViewModel.searchFilter.fileType, .mov)
        
        searchViewModel.toggleQuickFilter(.largeFiles)
        XCTAssertEqual(searchViewModel.searchFilter.sizeRange, .large)
        
        searchViewModel.toggleQuickFilter(.rootFolder)
        XCTAssertEqual(searchViewModel.searchFilter.folderDepth, .root)
    }
    
    // MARK: - Search History Tests
    
    func testSearchHistoryAdded() async {
        XCTAssertTrue(searchViewModel.searchHistory.isEmpty)
        
        let expectation = XCTestExpectation(description: "Search history updated")
        
        searchViewModel.$searchHistory
            .dropFirst()
            .sink { history in
                if !history.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "volleyball"
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertFalse(searchViewModel.searchHistory.isEmpty)
        XCTAssertEqual(searchViewModel.searchHistory.first?.query, "volleyball")
    }
    
    func testSearchHistoryDeduplication() async {
        // Perform first search
        let firstSearchExpectation = XCTestExpectation(description: "First search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                firstSearchExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "volleyball"
        await fulfillment(of: [firstSearchExpectation], timeout: 2.0)
        
        let _ = searchViewModel.searchHistory.count
        
        // Perform same search again
        let secondSearchExpectation = XCTestExpectation(description: "Second search completes")
        
        searchViewModel.$searchResults
            .dropFirst()
            .sink { results in
                secondSearchExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        searchViewModel.searchText = "volleyball again"
        searchViewModel.searchText = "volleyball" // Same search
        
        await fulfillment(of: [secondSearchExpectation], timeout: 2.0)
        
        // History should still have only one entry for "volleyball"
        let volleyballEntries = searchViewModel.searchHistory.filter { $0.query == "volleyball" }
        XCTAssertEqual(volleyballEntries.count, 1)
    }
    
    // MARK: - Saved Search Tests
    
    func testSaveSearch() {
        searchViewModel.searchText = "volleyball practice"
        searchViewModel.searchFilter.fileType = .mov
        
        searchViewModel.saveSearch(name: "Volleyball MOV Files")
        
        XCTAssertFalse(searchViewModel.savedSearches.isEmpty)
        
        let savedSearch = searchViewModel.savedSearches.first!
        XCTAssertEqual(savedSearch.name, "Volleyball MOV Files")
        XCTAssertEqual(savedSearch.query, "volleyball practice")
        XCTAssertEqual(savedSearch.filters.fileType, "MOV")
    }
    
    func testLoadSavedSearch() {
        // Save a search first
        searchViewModel.searchText = "basketball"
        searchViewModel.searchFilter.fileType = .mp4
        searchViewModel.searchFilter.sizeRange = .large
        searchViewModel.saveSearch(name: "Basketball Large MP4s")
        
        // Clear current search
        searchViewModel.clearSearch()
        XCTAssertEqual(searchViewModel.searchText, "")
        XCTAssertEqual(searchViewModel.searchFilter.fileType, .all)
        
        // Load saved search
        let savedSearch = searchViewModel.savedSearches.first!
        searchViewModel.loadSavedSearch(savedSearch)
        
        XCTAssertEqual(searchViewModel.searchText, "basketball")
        XCTAssertEqual(searchViewModel.searchFilter.fileType, .mp4)
        XCTAssertEqual(searchViewModel.searchFilter.sizeRange, .large)
    }
    
    func testDeleteSavedSearch() {
        searchViewModel.searchText = "test search"
        searchViewModel.saveSearch(name: "Test Search")
        
        XCTAssertEqual(searchViewModel.savedSearches.count, 1)
        
        let savedSearch = searchViewModel.savedSearches.first!
        searchViewModel.deleteSavedSearch(savedSearch)
        
        XCTAssertTrue(searchViewModel.savedSearches.isEmpty)
    }
    
    // MARK: - Clear Search Tests
    
    func testClearSearch() {
        searchViewModel.searchText = "test query"
        searchViewModel.searchFilter.fileType = .mov
        searchViewModel.activeQuickFilters.insert(.recentVideos)
        
        searchViewModel.clearSearch()
        
        XCTAssertEqual(searchViewModel.searchText, "")
        XCTAssertTrue(searchViewModel.searchResults.isEmpty)
        XCTAssertTrue(searchViewModel.activeQuickFilters.isEmpty)
        XCTAssertEqual(searchViewModel.searchFilter.fileType, .all)
    }
    
    // MARK: - Performance Tests
    
    func testSearchPerformance() async {
        // Add more test data for performance testing
        for i in 0..<100 {
            let testURL = createTestVideoURL(fileName: "performance_test_\(i).mov")
            _ = mediaStore.addVideo(at: testURL, toFolder: "", customName: "Performance Test Video \(i)")
        }
        
        measure {
            let expectation = XCTestExpectation(description: "Performance search completes")
            
            searchViewModel.$searchResults
                .dropFirst()
                .sink { results in
                    expectation.fulfill()
                }
                .store(in: &cancellables)
            
            searchViewModel.searchText = "performance"
            
            wait(for: [expectation], timeout: 1.0)
        }
    }
}