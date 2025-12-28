//
//  FolderManager.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import Foundation
import os
import Observation

@MainActor
@Observable
class FolderManager {
    private let mediaStore: MediaStore
    private let logger = Logger(subsystem: "BumpSetCut", category: "FolderManager")

    var folders: [FolderMetadata] = []
    var videos: [VideoMetadata] = []
    var currentPath: String = ""
    var isLoading = false

    // MARK: - Navigation History
    private var historyStack: [String] = [""]  // Start with root
    private var historyIndex: Int = 0
    private var isNavigatingHistory = false

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < historyStack.count - 1
    }

    var currentDepth: Int {
        currentPath.isEmpty ? 0 : currentPath.components(separatedBy: "/").count
    }

    static let maxDepth = 10

    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        loadContents()
    }
    
    // MARK: - Public Access
    
    var store: MediaStore {
        return mediaStore
    }
    
    // MARK: - Content Loading
    
    func loadContents(at path: String? = nil) {
        let targetPath = path ?? currentPath

        isLoading = true
        print("🔄 FolderManager.loadContents called for path: '\(targetPath)'")

        // Already on MainActor, update directly
        self.folders = mediaStore.getFolders(in: targetPath)
        self.videos = mediaStore.getVideos(in: targetPath)
        self.currentPath = targetPath
        self.isLoading = false

        print("✅ FolderManager loaded: \(self.folders.count) folders, \(self.videos.count) videos")
        print("   Video names: \(self.videos.map { $0.displayName })")
        logger.debug("Loaded contents for path: \(targetPath.isEmpty ? "root" : targetPath) - \(self.folders.count) folders, \(self.videos.count) videos")
    }
    
    func refreshContents() {
        // Clean up any stale entries (videos/folders that no longer exist on disk)
        mediaStore.cleanupStaleEntries()
        loadContents(at: currentPath)
    }
    
    // MARK: - Navigation

    func navigateToFolder(_ path: String) {
        guard path != currentPath else { return }

        // Track navigation history (unless we're navigating through history)
        if !isNavigatingHistory {
            // Remove forward history when navigating to a new path
            if historyIndex < historyStack.count - 1 {
                historyStack = Array(historyStack.prefix(historyIndex + 1))
            }
            historyStack.append(path)
            historyIndex = historyStack.count - 1
        }

        loadContents(at: path)
    }

    func navigateToParent() {
        guard !currentPath.isEmpty else { return }

        let parentPath = getParentPath(currentPath)
        navigateToFolder(parentPath)
    }

    func canNavigateUp() -> Bool {
        return !currentPath.isEmpty
    }

    // MARK: - History Navigation

    func navigateBack() {
        guard canGoBack else { return }
        isNavigatingHistory = true
        historyIndex -= 1
        let targetPath = historyStack[historyIndex]
        loadContents(at: targetPath)
        isNavigatingHistory = false
    }

    func navigateForward() {
        guard canGoForward else { return }
        isNavigatingHistory = true
        historyIndex += 1
        let targetPath = historyStack[historyIndex]
        loadContents(at: targetPath)
        isNavigatingHistory = false
    }

    func getHistoryPaths() -> (back: [String], forward: [String]) {
        let backPaths = historyIndex > 0 ? Array(historyStack.prefix(historyIndex).reversed()) : []
        let forwardPaths = historyIndex < historyStack.count - 1 ? Array(historyStack.suffix(from: historyIndex + 1)) : []
        return (backPaths, forwardPaths)
    }
    
    private func getParentPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 1 {
            return ""
        }
        return components.dropLast().joined(separator: "/")
    }
    
    // MARK: - Folder Operations with UI Integration
    
    func createFolder(name: String) async throws {
        // Validate name
        let sanitizedName = FolderValidationRules.sanitizeName(name)
        guard FolderValidationRules.isValidName(sanitizedName) else {
            throw FolderOperationError.invalidName(name)
        }
        
        // Check for conflicts
        if folders.contains(where: { $0.name.lowercased() == sanitizedName.lowercased() }) {
            throw FolderOperationError.nameConflict(sanitizedName)
        }
        
        let success = mediaStore.createFolder(name: sanitizedName, parentPath: currentPath)
        
        if success {
            refreshContents()
            logger.info("Created folder: \(sanitizedName)")
        } else {
            throw FolderOperationError.systemError("Failed to create folder")
        }
    }

    func renameFolder(_ folder: FolderMetadata, to newName: String) async throws {
        let sanitizedName = FolderValidationRules.sanitizeName(newName)
        guard FolderValidationRules.isValidName(sanitizedName) else {
            throw FolderOperationError.invalidName(newName)
        }

        // Check for conflicts (excluding the folder being renamed)
        if folders.contains(where: { $0.id != folder.id && $0.name.lowercased() == sanitizedName.lowercased() }) {
            throw FolderOperationError.nameConflict(sanitizedName)
        }

        let success = mediaStore.renameFolder(at: folder.path, to: sanitizedName)

        if success {
            refreshContents()
            logger.info("Renamed folder: \(folder.path) to \(sanitizedName)")
        } else {
            throw FolderOperationError.systemError("Failed to rename folder")
        }
    }

    func deleteFolder(_ folder: FolderMetadata, moveVideos: Bool = true) async throws {
        let success: Bool

        if folder.videoCount > 0 && moveVideos {
            // Move videos to parent folder first
            let videos = mediaStore.getVideos(in: folder.path)
            let parentPath = getParentPath(folder.path)

            for video in videos {
                _ = mediaStore.moveVideo(fileName: video.fileName, toFolder: parentPath)
            }
        }

        success = mediaStore.deleteFolder(at: folder.path)

        if success {
            refreshContents()
            logger.info("Deleted folder: \(folder.path)")
        } else {
            throw FolderOperationError.systemError("Failed to delete folder")
        }
    }

    // MARK: - Video Operations

    func moveVideoToFolder(_ video: VideoMetadata, targetFolderPath: String) async throws {
        let success = mediaStore.moveVideo(fileName: video.fileName, toFolder: targetFolderPath)

        if success {
            refreshContents()
            logger.info("Moved video: \(video.fileName) to \(targetFolderPath)")
        } else {
            throw FolderOperationError.systemError("Failed to move video")
        }
    }

    func renameVideo(_ video: VideoMetadata, to newName: String) async throws {
        let success = mediaStore.renameVideo(fileName: video.fileName, to: newName)

        if success {
            refreshContents()
            logger.info("Renamed video: \(video.fileName) to \(newName)")
        } else {
            throw FolderOperationError.systemError("Failed to rename video")
        }
    }

    func deleteVideo(_ video: VideoMetadata) async throws {
        let success = mediaStore.deleteVideo(fileName: video.fileName)

        if success {
            refreshContents()
            logger.info("Deleted video: \(video.fileName)")
        } else {
            throw FolderOperationError.systemError("Failed to delete video")
        }
    }

    // MARK: - Batch Operations

    func bulkMoveVideos(_ videos: [VideoMetadata], to targetFolderPath: String) async throws {
        var successCount = 0
        var errors: [String] = []

        for video in videos {
            let success = mediaStore.moveVideo(fileName: video.fileName, toFolder: targetFolderPath)

            if success {
                successCount += 1
            } else {
                errors.append(video.fileName)
            }
        }

        refreshContents()

        if !errors.isEmpty {
            let errorMessage = "Failed to move \(errors.count) videos: \(errors.joined(separator: ", "))"
            throw FolderOperationError.systemError(errorMessage)
        }

        logger.info("Bulk moved \(successCount) videos to \(targetFolderPath)")
    }
    
    // MARK: - Search
    
    func searchContents(query: String) -> (folders: [FolderMetadata], videos: [VideoMetadata]) {
        let lowercaseQuery = query.lowercased()
        
        let matchingFolders = folders.filter { folder in
            folder.name.lowercased().contains(lowercaseQuery)
        }
        
        let matchingVideos = videos.filter { video in
            video.displayName.lowercased().contains(lowercaseQuery) ||
            video.fileName.lowercased().contains(lowercaseQuery)
        }
        
        return (matchingFolders, matchingVideos)
    }
    
    func globalSearch(query: String) -> [VideoMetadata] {
        return mediaStore.searchVideos(query: query)
    }
    
    // MARK: - Utility
    
    func getFolderHierarchy() -> [BreadcrumbItem] {
        return NavigationPath(path: currentPath).breadcrumbs
    }
    
    func canCreateFolder(named name: String) -> Bool {
        let sanitizedName = FolderValidationRules.sanitizeName(name)
        return FolderValidationRules.isValidName(sanitizedName) && 
               !folders.contains(where: { $0.name.lowercased() == sanitizedName.lowercased() })
    }
    
    func getSortedFolders(by sortOption: FolderSortOption = .name) -> [FolderMetadata] {
        switch sortOption {
        case .name:
            return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateCreated:
            return folders.sorted { $0.createdDate > $1.createdDate }
        case .dateModified:
            return folders.sorted { $0.modifiedDate > $1.modifiedDate }
        case .videoCount:
            return folders.sorted { $0.videoCount > $1.videoCount }
        }
    }
    
    func getSortedVideos(by sortOption: VideoSortOption = .name) -> [VideoMetadata] {
        switch sortOption {
        case .name:
            return videos.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .dateCreated:
            return videos.sorted { $0.createdDate > $1.createdDate }
        case .fileSize:
            return videos.sorted { $0.fileSize > $1.fileSize }
        }
    }
}

// MARK: - Sort Options

enum FolderSortOption: String, CaseIterable {
    case name = "Name"
    case dateCreated = "Date Created"
    case dateModified = "Date Modified"
    case videoCount = "Video Count"
}

enum VideoSortOption: String, CaseIterable {
    case name = "Name"
    case dateCreated = "Date Created"
    case fileSize = "File Size"
}