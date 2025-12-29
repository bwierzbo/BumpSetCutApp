import SwiftUI
import Combine
import Observation

// MARK: - LibraryViewModel
@MainActor
@Observable
final class LibraryViewModel {
    // MARK: - Dependencies
    let folderManager: FolderManager
    let uploadCoordinator: UploadCoordinator
    let searchViewModel: SearchViewModel
    let libraryType: LibraryType

    // MARK: - State
    var sortOption: ContentSortOption = .name
    var viewMode: ViewMode = .grid
    var searchText: String = ""
    var showingCreateFolder: Bool = false
    var newFolderName: String = ""
    var isSearching: Bool = false

    // MARK: - Computed Properties
    var currentPath: String {
        folderManager.currentPath
    }

    var isLoading: Bool {
        folderManager.isLoading
    }

    var folderCount: Int {
        folderManager.folders.count
    }

    var videoCount: Int {
        folderManager.videos.count
    }

    var isAtRoot: Bool {
        folderManager.isAtLibraryRoot
    }

    var canGoBack: Bool {
        folderManager.canGoBack
    }

    var canGoForward: Bool {
        folderManager.canGoForward
    }

    var currentDepth: Int {
        folderManager.currentDepth
    }

    var depthIndicator: String? {
        let depth = currentDepth
        guard depth > 0 else { return nil }
        return "Level \(depth) of \(FolderManager.maxDepth)"
    }

    var title: String {
        if isAtRoot {
            return libraryType.displayName
        }
        return currentPath.components(separatedBy: "/").last ?? "Contents"
    }

    var subtitle: String {
        if folderCount > 0 || videoCount > 0 {
            return "\(folderCount) folders, \(videoCount) videos"
        }
        return ""
    }

    var isEmpty: Bool {
        filteredFolders.isEmpty && filteredVideos.isEmpty && !isLoading
    }

    var emptyStateMessage: String {
        searchText.isEmpty ? "No content in this folder yet." : "No matching content found."
    }

    // MARK: - Filtered Content
    var filteredFolders: [FolderMetadata] {
        if searchText.isEmpty {
            return folderManager.getSortedFolders(by: sortOption.folderSort)
        } else {
            // Use library-scoped search
            return folderManager.globalSearchFolders(query: searchText)
                .sorted { folder1, folder2 in
                    switch sortOption.folderSort {
                    case .name:
                        return folder1.name.localizedCaseInsensitiveCompare(folder2.name) == .orderedAscending
                    case .dateCreated:
                        return folder1.createdDate < folder2.createdDate
                    case .dateModified:
                        return folder1.modifiedDate < folder2.modifiedDate
                    case .videoCount:
                        return folder1.videoCount < folder2.videoCount
                    }
                }
        }
    }

    var filteredVideos: [VideoMetadata] {
        var videos: [VideoMetadata]

        if searchText.isEmpty {
            videos = folderManager.getSortedVideos(by: sortOption.videoSort)
        } else {
            // Use library-scoped search
            videos = folderManager.globalSearch(query: searchText)
                .sorted { video1, video2 in
                    switch sortOption.videoSort {
                    case .name:
                        return video1.displayName.localizedCaseInsensitiveCompare(video2.displayName) == .orderedAscending
                    case .dateCreated:
                        return video1.createdDate < video2.createdDate
                    case .fileSize:
                        return video1.fileSize < video2.fileSize
                    }
                }
        }

        // No filter needed - library separation handles this
        return videos
    }

    // MARK: - Breadcrumbs
    var breadcrumbs: [BSCBreadcrumb.Crumb] {
        // Use relative path for breadcrumbs, with library name as root
        let relativePath = folderManager.currentRelativePath
        return BSCBreadcrumb.crumbs(from: relativePath, rootName: libraryType.displayName)
    }

    // MARK: - Initialization
    init(mediaStore: MediaStore, libraryType: LibraryType = .saved) {
        self.libraryType = libraryType
        self.folderManager = FolderManager(mediaStore: mediaStore, libraryType: libraryType)
        self.uploadCoordinator = UploadCoordinator(mediaStore: mediaStore)
        self.searchViewModel = SearchViewModel(mediaStore: mediaStore)
    }

    // MARK: - Actions
    func refresh() {
        folderManager.refreshContents()
    }

    func navigateToFolder(_ path: String) {
        folderManager.navigateToFolder(path)
    }

    func navigateBack() {
        folderManager.navigateBack()
    }

    func navigateForward() {
        folderManager.navigateForward()
    }

    func navigateToParent() {
        folderManager.navigateToParent()
    }

    func createFolder() async throws {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        try await folderManager.createFolder(name: trimmedName)
        await MainActor.run {
            showingCreateFolder = false
            newFolderName = ""
        }
    }

    func deleteFolder(_ folder: FolderMetadata) async throws {
        try await folderManager.deleteFolder(folder)
    }

    func renameFolder(_ folder: FolderMetadata, to newName: String) async throws {
        try await folderManager.renameFolder(folder, to: newName)
    }

    func deleteVideo(_ video: VideoMetadata) async throws {
        try await folderManager.deleteVideo(video)
    }

    func renameVideo(_ video: VideoMetadata, to newName: String) async throws {
        try await folderManager.renameVideo(video, to: newName)
    }

    func moveVideo(_ video: VideoMetadata, to targetFolder: String) async throws {
        try await folderManager.moveVideoToFolder(video, targetFolderPath: targetFolder)
    }

    func clearSearch() {
        searchText = ""
    }
}

// MARK: - Content Options
enum ContentSortOption: String, CaseIterable {
    case name = "Name"
    case dateCreated = "Date Created"
    case fileSize = "File Size"

    var folderSort: FolderSortOption {
        switch self {
        case .name: return .name
        case .dateCreated: return .dateCreated
        case .fileSize: return .videoCount
        }
    }

    var videoSort: VideoSortOption {
        switch self {
        case .name: return .name
        case .dateCreated: return .dateCreated
        case .fileSize: return .fileSize
        }
    }

    var icon: String {
        switch self {
        case .name: return "textformat"
        case .dateCreated: return "calendar"
        case .fileSize: return "externaldrive"
        }
    }
}

enum ViewMode: String, CaseIterable {
    case list = "List"
    case grid = "Grid"

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}
