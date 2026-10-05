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
    private let metadataStore: MetadataStore
    private let logger = Logger(subsystem: "BumpSetCut", category: "FolderManager")

    let libraryType: LibraryType

    var folders: [FolderMetadata] = []
    var videos: [VideoMetadata] = []
    var currentPath: String = ""
    var isLoading = false

    var currentDepth: Int {
        // Depth relative to library root
        let relativePath = currentRelativePath
        return relativePath.isEmpty ? 0 : relativePath.components(separatedBy: "/").count
    }

    /// Path relative to library root (without library prefix)
    var currentRelativePath: String {
        mediaStore.relativePath(from: currentPath, in: libraryType)
    }

    /// Check if currently at library root
    var isAtLibraryRoot: Bool {
        currentPath == libraryType.rootPath
    }

    static let maxDepth = 1  // Simplified: only root-level folders, no nesting

    private var hasLoadedInitialContents = false

    init(mediaStore: MediaStore, libraryType: LibraryType = .saved, metadataStore: MetadataStore? = nil) {
        self.mediaStore = mediaStore
        self.metadataStore = metadataStore ?? .shared
        self.libraryType = libraryType
        self.currentPath = libraryType.rootPath
    }

    /// Load contents on first access — avoids work when NavigationLink eagerly creates destinations
    func loadInitialContentsIfNeeded() {
        guard !hasLoadedInitialContents else { return }
        hasLoadedInitialContents = true
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

        // Already on MainActor, update directly
        self.folders = mediaStore.getFolders(in: targetPath)
        self.videos = mediaStore.getVideos(in: targetPath)
        self.currentPath = targetPath
        self.isLoading = false

        logger.debug("Loaded contents for path: \(targetPath.isEmpty ? "root" : targetPath) - \(self.folders.count) folders, \(self.videos.count) videos")
    }
    
    func refreshContents() {
        // Clean up any stale entries (videos/folders that no longer exist on disk)
        mediaStore.cleanupStaleEntries()
        loadContents(at: currentPath)
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

        // Enforce max depth: only allow folder creation at root
        guard currentDepth < Self.maxDepth else {
            throw FolderOperationError.maxDepthReached
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

    /// Remove a favorited rally clip. The source video's review selections are
    /// un-starred first, so the rally player doesn't still show it as a favorite.
    func removeFavorite(_ video: VideoMetadata) async throws {
        if let sourceVideoId = video.sourceVideoId, let rallyIndex = video.sourceRallyIndex {
            var selections = metadataStore.loadReviewSelections(for: sourceVideoId)
            selections.favorited.remove(rallyIndex)
            try metadataStore.saveReviewSelections(selections, for: sourceVideoId)
        }
        try await deleteVideo(video)
    }

    // MARK: - Search

    func globalSearch(query: String) -> [VideoMetadata] {
        return mediaStore.searchVideos(query: query, in: libraryType)
    }

    func globalSearchFolders(query: String) -> [FolderMetadata] {
        return mediaStore.searchFolders(query: query, in: libraryType)
    }
    
    // MARK: - Sorting

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