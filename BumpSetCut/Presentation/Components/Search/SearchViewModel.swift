//
//  SearchViewModel.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import Foundation
import Combine
import os

// MARK: - Search Models

struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    let type: SearchResultType
    let title: String
    let subtitle: String
    let folderPath: String
    let matchedText: String
    let relevanceScore: Double
    
    enum SearchResultType: Hashable {
        case video(VideoMetadata)
        case folder(FolderMetadata)
    }
}

struct SearchFilter {
    var fileType: FileTypeFilter = .all
    var dateRange: DateRangeFilter = .all
    var sizeRange: FileSizeFilter = .all
    var folderDepth: FolderDepthFilter = .all
    
    enum FileTypeFilter: String, CaseIterable {
        case all = "All"
        case mov = "MOV"
        case mp4 = "MP4"
        
        var predicate: (VideoMetadata) -> Bool {
            switch self {
            case .all: return { _ in true }
            case .mov: return { $0.fileName.lowercased().hasSuffix(".mov") }
            case .mp4: return { $0.fileName.lowercased().hasSuffix(".mp4") }
            }
        }
    }
    
    enum DateRangeFilter: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        case thisYear = "This Year"
        
        var predicate: (Date) -> Bool {
            let now = Date()
            let calendar = Calendar.current
            
            switch self {
            case .all: return { _ in true }
            case .today: return { calendar.isDate($0, inSameDayAs: now) }
            case .thisWeek: return { calendar.isDate($0, equalTo: now, toGranularity: .weekOfYear) }
            case .thisMonth: return { calendar.isDate($0, equalTo: now, toGranularity: .month) }
            case .thisYear: return { calendar.isDate($0, equalTo: now, toGranularity: .year) }
            }
        }
    }
    
    enum FileSizeFilter: String, CaseIterable {
        case all = "All Sizes"
        case small = "Small (< 100MB)"
        case medium = "Medium (100MB - 1GB)"
        case large = "Large (> 1GB)"
        
        var predicate: (Int64) -> Bool {
            switch self {
            case .all: return { _ in true }
            case .small: return { $0 < 100 * 1024 * 1024 }
            case .medium: return { $0 >= 100 * 1024 * 1024 && $0 < 1024 * 1024 * 1024 }
            case .large: return { $0 >= 1024 * 1024 * 1024 }
            }
        }
    }
    
    enum FolderDepthFilter: String, CaseIterable {
        case all = "All Folders"
        case root = "Root Only"
        case shallow = "1-2 Levels"
        case deep = "3+ Levels"
        
        func predicate(for folderPath: String) -> Bool {
            let depth = folderPath.isEmpty ? 0 : folderPath.components(separatedBy: "/").count
            
            switch self {
            case .all: return true
            case .root: return depth == 0
            case .shallow: return depth >= 1 && depth <= 2
            case .deep: return depth >= 3
            }
        }
    }
}

struct SearchHistory: Codable, Identifiable {
    let id = UUID()
    let query: String
    let timestamp: Date
    let resultCount: Int
}

struct SavedSearch: Codable, Identifiable {
    let id = UUID()
    var name: String
    let query: String
    let filters: SearchFilterData
    let createdDate: Date
    var lastUsed: Date
    
    struct SearchFilterData: Codable {
        let fileType: String
        let dateRange: String
        let sizeRange: String
        let folderDepth: String
    }
}

// MARK: - Advanced Sorting

enum AdvancedSortOption: String, CaseIterable {
    case relevance = "Relevance"
    case name = "Name"
    case dateCreated = "Date Created"
    case dateModified = "Date Modified"
    case fileSize = "File Size"
    case folderDepth = "Folder Depth"
    case videoCount = "Video Count"
    
    var isDescending: Bool {
        switch self {
        case .relevance, .dateCreated, .dateModified, .fileSize, .videoCount:
            return true
        case .name, .folderDepth:
            return false
        }
    }
}

// MARK: - Search ViewModel

@MainActor
class SearchViewModel: ObservableObject {
    private let mediaStore: MediaStore
    private let logger = Logger(subsystem: "BumpSetCut", category: "SearchViewModel")
    
    // Search state
    @Published var searchText: String = ""
    @Published var isSearching: Bool = false
    @Published var searchResults: [SearchResult] = []
    @Published var searchFilter = SearchFilter()
    @Published var sortOption: AdvancedSortOption = .relevance
    @Published var isShowingFilters: Bool = false
    
    // Search history and saved searches
    @Published var searchHistory: [SearchHistory] = []
    @Published var savedSearches: [SavedSearch] = []
    @Published var isShowingHistory: Bool = false
    @Published var isShowingSavedSearches: Bool = false
    
    // Quick filters
    @Published var activeQuickFilters: Set<QuickFilter> = []
    
    private var cancellables = Set<AnyCancellable>()
    private let searchDebounceTime: TimeInterval = 0.3
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        setupSearchDebouncing()
        loadSearchHistory()
        loadSavedSearches()
    }
    
    // MARK: - Search Setup
    
    private func setupSearchDebouncing() {
        $searchText
            .debounce(for: .seconds(searchDebounceTime), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] searchText in
                Task {
                    await self?.performSearch(query: searchText)
                }
            }
            .store(in: &cancellables)
        
        // Also trigger search when filters change
        Publishers.CombineLatest($searchFilter, $sortOption)
            .debounce(for: .seconds(0.1), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self = self, !self.searchText.isEmpty else { return }
                Task {
                    await self.performSearch(query: self.searchText)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Core Search Logic
    
    private func performSearch(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        
        isSearching = true
        
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Search videos across all folders
        let videos = mediaStore.searchVideos(query: trimmedQuery)
        let folders = searchFolders(query: trimmedQuery)
        
        // Apply filters
        let filteredVideos = applyFilters(to: videos)
        let filteredFolders = applyFilters(to: folders)
        
        // Convert to search results with relevance scoring
        let videoResults = filteredVideos.map { video in
            createSearchResult(for: video, query: trimmedQuery)
        }
        
        let folderResults = filteredFolders.map { folder in
            createSearchResult(for: folder, query: trimmedQuery)
        }
        
        // Combine and sort results
        let allResults = videoResults + folderResults
        let sortedResults = sortResults(allResults)
        
        searchResults = sortedResults
        isSearching = false
        
        // Add to search history
        addToSearchHistory(query: trimmedQuery, resultCount: allResults.count)
        
        logger.debug("Search completed: '\(trimmedQuery)' - \(allResults.count) results")
    }
    
    private func searchFolders(query: String) -> [FolderMetadata] {
        return mediaStore.searchFolders(query: query)
    }
    
    // MARK: - Filtering
    
    private func applyFilters(to videos: [VideoMetadata]) -> [VideoMetadata] {
        return videos.filter { video in
            searchFilter.fileType.predicate(video) &&
            searchFilter.dateRange.predicate(video.createdDate) &&
            searchFilter.sizeRange.predicate(video.fileSize) &&
            searchFilter.folderDepth.predicate(for: video.folderPath)
        }
    }
    
    private func applyFilters(to folders: [FolderMetadata]) -> [FolderMetadata] {
        return folders.filter { folder in
            searchFilter.folderDepth.predicate(for: folder.path)
        }
    }
    
    // MARK: - Search Result Creation
    
    private func createSearchResult(for video: VideoMetadata, query: String) -> SearchResult {
        let relevanceScore = calculateRelevanceScore(for: video, query: query)
        let matchedText = findMatchedText(in: [video.displayName, video.fileName], query: query)
        
        return SearchResult(
            type: .video(video),
            title: video.displayName,
            subtitle: formatVideoSubtitle(video),
            folderPath: video.folderPath,
            matchedText: matchedText,
            relevanceScore: relevanceScore
        )
    }
    
    private func createSearchResult(for folder: FolderMetadata, query: String) -> SearchResult {
        let relevanceScore = calculateRelevanceScore(for: folder, query: query)
        let matchedText = findMatchedText(in: [folder.name, folder.path], query: query)
        
        return SearchResult(
            type: .folder(folder),
            title: folder.name,
            subtitle: formatFolderSubtitle(folder),
            folderPath: folder.path,
            matchedText: matchedText,
            relevanceScore: relevanceScore
        )
    }
    
    private func calculateRelevanceScore(for video: VideoMetadata, query: String) -> Double {
        let lowercaseQuery = query.lowercased()
        var score = 0.0
        
        // Exact match in display name gets highest score
        if video.displayName.lowercased() == lowercaseQuery {
            score += 100.0
        } else if video.displayName.lowercased().hasPrefix(lowercaseQuery) {
            score += 50.0
        } else if video.displayName.localizedCaseInsensitiveContains(query) {
            score += 25.0
        }
        
        // File name matches
        if video.fileName.lowercased().hasPrefix(lowercaseQuery) {
            score += 30.0
        } else if video.fileName.localizedCaseInsensitiveContains(query) {
            score += 15.0
        }
        
        // Boost for shorter folder paths (closer to root)
        let depthPenalty = Double(video.folderPath.components(separatedBy: "/").count) * 2.0
        score = max(0, score - depthPenalty)
        
        return score
    }
    
    private func calculateRelevanceScore(for folder: FolderMetadata, query: String) -> Double {
        let lowercaseQuery = query.lowercased()
        var score = 0.0
        
        if folder.name.lowercased() == lowercaseQuery {
            score += 100.0
        } else if folder.name.lowercased().hasPrefix(lowercaseQuery) {
            score += 50.0
        } else if folder.name.localizedCaseInsensitiveContains(query) {
            score += 25.0
        }
        
        // Boost for folders with more content
        score += Double(folder.videoCount) * 0.5
        score += Double(folder.subfolderCount) * 0.3
        
        return score
    }
    
    private func findMatchedText(in texts: [String], query: String) -> String {
        for text in texts {
            if text.localizedCaseInsensitiveContains(query) {
                return text
            }
        }
        return texts.first ?? ""
    }
    
    private func formatVideoSubtitle(_ video: VideoMetadata) -> String {
        let sizeString = formatFileSize(video.fileSize)
        let folderString = video.folderPath.isEmpty ? "Root" : video.folderPath
        return "\(sizeString) • \(folderString)"
    }
    
    private func formatFolderSubtitle(_ folder: FolderMetadata) -> String {
        let contentString = "\(folder.videoCount) videos, \(folder.subfolderCount) folders"
        let pathString = folder.parentPath ?? "Root"
        return "\(contentString) • \(pathString)"
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - Sorting
    
    private func sortResults(_ results: [SearchResult]) -> [SearchResult] {
        return results.sorted { first, second in
            switch sortOption {
            case .relevance:
                return first.relevanceScore > second.relevanceScore
            case .name:
                return first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
            case .dateCreated:
                let firstDate = getCreationDate(for: first)
                let secondDate = getCreationDate(for: second)
                return firstDate > secondDate
            case .dateModified:
                let firstDate = getModificationDate(for: first)
                let secondDate = getModificationDate(for: second)
                return firstDate > secondDate
            case .fileSize:
                let firstSize = getFileSize(for: first)
                let secondSize = getFileSize(for: second)
                return firstSize > secondSize
            case .folderDepth:
                let firstDepth = first.folderPath.components(separatedBy: "/").count
                let secondDepth = second.folderPath.components(separatedBy: "/").count
                return firstDepth < secondDepth
            case .videoCount:
                let firstCount = getVideoCount(for: first)
                let secondCount = getVideoCount(for: second)
                return firstCount > secondCount
            }
        }
    }
    
    private func getCreationDate(for result: SearchResult) -> Date {
        switch result.type {
        case .video(let video): return video.createdDate
        case .folder(let folder): return folder.createdDate
        }
    }
    
    private func getModificationDate(for result: SearchResult) -> Date {
        switch result.type {
        case .video(let video): return video.createdDate // Videos don't have modification date
        case .folder(let folder): return folder.modifiedDate
        }
    }
    
    private func getFileSize(for result: SearchResult) -> Int64 {
        switch result.type {
        case .video(let video): return video.fileSize
        case .folder(_): return 0 // Folders don't have file size
        }
    }
    
    private func getVideoCount(for result: SearchResult) -> Int {
        switch result.type {
        case .video(_): return 0
        case .folder(let folder): return folder.videoCount
        }
    }
    
    // MARK: - Search History
    
    private func addToSearchHistory(query: String, resultCount: Int) {
        let historyEntry = SearchHistory(query: query, timestamp: Date(), resultCount: resultCount)
        
        // Remove duplicate entries
        searchHistory.removeAll { $0.query == query }
        
        // Add new entry at the beginning
        searchHistory.insert(historyEntry, at: 0)
        
        // Keep only last 20 searches
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        
        saveSearchHistory()
    }
    
    private func loadSearchHistory() {
        guard let data = UserDefaults.standard.data(forKey: "SearchHistory"),
              let history = try? JSONDecoder().decode([SearchHistory].self, from: data) else {
            return
        }
        searchHistory = history
    }
    
    private func saveSearchHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) {
            UserDefaults.standard.set(data, forKey: "SearchHistory")
        }
    }
    
    // MARK: - Saved Searches
    
    func saveSearch(name: String) {
        guard !searchText.isEmpty else { return }
        
        let filterData = SavedSearch.SearchFilterData(
            fileType: searchFilter.fileType.rawValue,
            dateRange: searchFilter.dateRange.rawValue,
            sizeRange: searchFilter.sizeRange.rawValue,
            folderDepth: searchFilter.folderDepth.rawValue
        )
        
        let savedSearch = SavedSearch(
            name: name,
            query: searchText,
            filters: filterData,
            createdDate: Date(),
            lastUsed: Date()
        )
        
        savedSearches.append(savedSearch)
        saveSavedSearches()
        
        logger.info("Saved search: \(name)")
    }
    
    func loadSavedSearch(_ savedSearch: SavedSearch) {
        searchText = savedSearch.query
        
        // Restore filters
        searchFilter.fileType = SearchFilter.FileTypeFilter(rawValue: savedSearch.filters.fileType) ?? .all
        searchFilter.dateRange = SearchFilter.DateRangeFilter(rawValue: savedSearch.filters.dateRange) ?? .all
        searchFilter.sizeRange = SearchFilter.FileSizeFilter(rawValue: savedSearch.filters.sizeRange) ?? .all
        searchFilter.folderDepth = SearchFilter.FolderDepthFilter(rawValue: savedSearch.filters.folderDepth) ?? .all
        
        // Update last used timestamp
        if let index = savedSearches.firstIndex(where: { $0.id == savedSearch.id }) {
            savedSearches[index].lastUsed = Date()
            saveSavedSearches()
        }
        
        logger.info("Loaded saved search: \(savedSearch.name)")
    }
    
    func deleteSavedSearch(_ savedSearch: SavedSearch) {
        savedSearches.removeAll { $0.id == savedSearch.id }
        saveSavedSearches()
        logger.info("Deleted saved search: \(savedSearch.name)")
    }
    
    private func loadSavedSearches() {
        guard let data = UserDefaults.standard.data(forKey: "SavedSearches"),
              let searches = try? JSONDecoder().decode([SavedSearch].self, from: data) else {
            return
        }
        savedSearches = searches
    }
    
    private func saveSavedSearches() {
        if let data = try? JSONEncoder().encode(savedSearches) {
            UserDefaults.standard.set(data, forKey: "SavedSearches")
        }
    }
    
    // MARK: - Quick Filters
    
    func toggleQuickFilter(_ filter: QuickFilter) {
        if activeQuickFilters.contains(filter) {
            activeQuickFilters.remove(filter)
        } else {
            activeQuickFilters.insert(filter)
        }
        
        applyQuickFilters()
    }
    
    private func applyQuickFilters() {
        for filter in activeQuickFilters {
            switch filter {
            case .recentVideos:
                searchFilter.dateRange = .thisWeek
            case .largeFiles:
                searchFilter.sizeRange = .large
            case .rootFolder:
                searchFilter.folderDepth = .root
            case .movFiles:
                searchFilter.fileType = .mov
            case .mp4Files:
                searchFilter.fileType = .mp4
            }
        }
    }
    
    // MARK: - Public Interface
    
    func clearSearch() {
        searchText = ""
        searchResults = []
        activeQuickFilters.removeAll()
        resetFilters()
    }
    
    func resetFilters() {
        searchFilter = SearchFilter()
        sortOption = .relevance
    }
    
    func searchFromHistory(_ historyEntry: SearchHistory) {
        searchText = historyEntry.query
    }
}

// MARK: - Quick Filter Enum

enum QuickFilter: String, CaseIterable {
    case recentVideos = "Recent"
    case largeFiles = "Large Files"
    case rootFolder = "Root Only"
    case movFiles = "MOV Files"
    case mp4Files = "MP4 Files"
    
    var displayName: String { rawValue }
    var systemImage: String {
        switch self {
        case .recentVideos: return "clock"
        case .largeFiles: return "externaldrive"
        case .rootFolder: return "house"
        case .movFiles: return "video"
        case .mp4Files: return "video.fill"
        }
    }
}