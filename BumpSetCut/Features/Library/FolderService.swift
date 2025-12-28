//
//  FolderService.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import Foundation
import os

@MainActor
class FolderService: ObservableObject {
    private let mediaStore: MediaStore
    private let logger = Logger(subsystem: "BumpSetCut", category: "FolderService")
    
    @Published var currentPath: String = ""
    @Published var isOperationInProgress = false
    @Published var bulkOperationProgress: BulkOperationProgress?
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
    }
    
    // MARK: - Navigation
    
    func navigateToFolder(_ path: String) {
        currentPath = path
        logger.info("Navigated to folder: \(path.isEmpty ? "root" : path)")
    }
    
    func navigateUp() -> Bool {
        guard !currentPath.isEmpty else { return false }
        
        let parentPath = getParentPath(currentPath)
        navigateToFolder(parentPath)
        return true
    }
    
    func getBreadcrumbs() -> NavigationPath {
        return NavigationPath(path: currentPath)
    }
    
    private func getParentPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        
        let components = path.split(separator: "/")
        if components.count <= 1 {
            return ""
        }
        
        return components.dropLast().joined(separator: "/")
    }
    
    // MARK: - Folder Operations
    
    func createFolder(name: String, in parentPath: String? = nil) async -> FolderOperationResult {
        let targetPath = parentPath ?? currentPath
        let operation = FolderOperationType.create(name, parentPath: targetPath)
        
        // Validate name
        guard FolderValidationRules.isValidName(name) else {
            return .failure(operation, error: .invalidName(name))
        }
        
        // Check if folder already exists
        if mediaStore.getFolderMetadata(at: targetPath.isEmpty ? name : "\(targetPath)/\(name)") != nil {
            return .failure(operation, error: .nameConflict(name))
        }
        
        isOperationInProgress = true
        defer { isOperationInProgress = false }
        
        let success = mediaStore.createFolder(name: name, parentPath: targetPath)
        
        if success {
            logger.info("Created folder: \(name) in \(targetPath.isEmpty ? "root" : targetPath)")
            return .success(operation, message: "Folder '\(name)' created successfully")
        } else {
            return .failure(operation, error: .systemError("Failed to create folder"))
        }
    }
    
    func renameFolder(at path: String, to newName: String) async -> FolderOperationResult {
        let operation = FolderOperationType.rename(path, newName: newName)
        
        // Validate new name
        guard FolderValidationRules.isValidName(newName) else {
            return .failure(operation, error: .invalidName(newName))
        }
        
        // Check if folder exists
        guard mediaStore.getFolderMetadata(at: path) != nil else {
            return .failure(operation, error: .pathNotFound(path))
        }
        
        isOperationInProgress = true
        defer { isOperationInProgress = false }
        
        let success = mediaStore.renameFolder(at: path, to: newName)
        
        if success {
            logger.info("Renamed folder: \(path) to \(newName)")
            
            // Update current path if we renamed a folder in our current path
            updateCurrentPathAfterRename(oldPath: path, newName: newName)
            
            return .success(operation, message: "Folder renamed to '\(newName)'")
        } else {
            return .failure(operation, error: .nameConflict(newName))
        }
    }
    
    func deleteFolder(at path: String, deleteVideos: Bool = false) async -> FolderOperationResult {
        let operation = FolderOperationType.delete(path, deleteVideos: deleteVideos)
        
        // Check if folder exists
        guard let folderMetadata = mediaStore.getFolderMetadata(at: path) else {
            return .failure(operation, error: .pathNotFound(path))
        }
        
        // Check if folder has videos and deleteVideos is false
        if folderMetadata.videoCount > 0 && !deleteVideos {
            return .failure(operation, error: .notEmpty(path, videoCount: folderMetadata.videoCount))
        }
        
        isOperationInProgress = true
        defer { isOperationInProgress = false }
        
        // If not deleting videos, move them to parent folder first
        if folderMetadata.videoCount > 0 && !deleteVideos {
            let videos = mediaStore.getVideos(in: path)
            let parentPath = getParentPath(path)
            
            for video in videos {
                _ = mediaStore.moveVideo(fileName: video.fileName, toFolder: parentPath)
            }
        }
        
        let success = mediaStore.deleteFolder(at: path)
        
        if success {
            logger.info("Deleted folder: \(path)")
            
            // Navigate up if we deleted our current folder or a parent
            if currentPath == path || currentPath.hasPrefix(path + "/") {
                navigateToFolder(getParentPath(path))
            }
            
            let message = deleteVideos 
                ? "Folder '\(path)' and its contents deleted"
                : "Folder '\(path)' deleted, videos moved to parent folder"
            
            return .success(operation, message: message)
        } else {
            return .failure(operation, error: .systemError("Failed to delete folder"))
        }
    }
    
    func moveFolder(from sourcePath: String, to targetParentPath: String) async -> FolderOperationResult {
        let operation = FolderOperationType.move(sourcePath, newParentPath: targetParentPath)

        // Check if source folder exists
        guard let sourceFolderMetadata = mediaStore.getFolderMetadata(at: sourcePath) else {
            return .failure(operation, error: .pathNotFound(sourcePath))
        }

        // Check for circular reference - cannot move folder into itself or any of its descendants
        let sourcePathWithSeparator = sourcePath + "/"
        if targetParentPath == sourcePath || targetParentPath.hasPrefix(sourcePathWithSeparator) {
            return .failure(operation, error: .circularReference(sourcePath))
        }

        // Check if target folder exists (if not empty)
        if !targetParentPath.isEmpty && mediaStore.getFolderMetadata(at: targetParentPath) == nil {
            return .failure(operation, error: .pathNotFound(targetParentPath))
        }

        // Generate new path
        let folderName = sourceFolderMetadata.name
        let newPath = targetParentPath.isEmpty ? folderName : "\(targetParentPath)/\(folderName)"

        // Additional cyclic check: ensure resulting path isn't inside source
        if newPath == sourcePath || newPath.hasPrefix(sourcePathWithSeparator) {
            return .failure(operation, error: .circularReference(sourcePath))
        }

        isOperationInProgress = true
        defer { isOperationInProgress = false }

        // Check for name conflict in target
        if mediaStore.getFolderMetadata(at: newPath) != nil {
            return .failure(operation, error: .nameConflict(folderName))
        }
        
        let success = mediaStore.renameFolder(at: sourcePath, to: folderName) // This moves it via path update
        
        if success {
            logger.info("Moved folder: \(sourcePath) to \(targetParentPath)")
            
            // Update current path if needed
            if currentPath == sourcePath || currentPath.hasPrefix(sourcePath + "/") {
                let relativePath = String(currentPath.dropFirst(sourcePath.count))
                navigateToFolder(newPath + relativePath)
            }
            
            return .success(operation, message: "Folder moved successfully", affectedPaths: [newPath])
        } else {
            return .failure(operation, error: .systemError("Failed to move folder"))
        }
    }
    
    // MARK: - Bulk Operations
    
    func bulkMoveVideosTofolder(videoFileNames: [String], to targetFolderPath: String) async -> FolderOperationResult {
        let operation = FolderOperationType.bulkMove(videoFileNames, newParentPath: targetFolderPath)
        
        guard !videoFileNames.isEmpty else {
            return .failure(operation, error: .systemError("No videos selected"))
        }
        
        // Check if target folder exists (unless root)
        if !targetFolderPath.isEmpty && mediaStore.getFolderMetadata(at: targetFolderPath) == nil {
            return .failure(operation, error: .pathNotFound(targetFolderPath))
        }
        
        isOperationInProgress = true
        bulkOperationProgress = BulkOperationProgress(totalItems: videoFileNames.count, completedItems: 0, currentItem: "", errors: [])
        
        defer {
            isOperationInProgress = false
            bulkOperationProgress = nil
        }
        
        var completedCount = 0
        var errors: [FolderOperationError] = []
        var successfulMoves: [String] = []
        
        for videoFileName in videoFileNames {
            bulkOperationProgress = BulkOperationProgress(
                totalItems: videoFileNames.count,
                completedItems: completedCount,
                currentItem: videoFileName,
                errors: errors
            )
            
            let success = mediaStore.moveVideo(fileName: videoFileName, toFolder: targetFolderPath)
            
            if success {
                successfulMoves.append(videoFileName)
                logger.debug("Moved video: \(videoFileName) to \(targetFolderPath)")
            } else {
                errors.append(.systemError("Failed to move video: \(videoFileName)"))
                logger.error("Failed to move video: \(videoFileName)")
            }
            
            completedCount += 1
            
            // Small delay to prevent overwhelming the system
            try? await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        }
        
        let message = """
            Bulk move completed: \(successfulMoves.count) of \(videoFileNames.count) videos moved successfully.
            \(errors.isEmpty ? "" : "\(errors.count) errors occurred.")
            """
        
        if successfulMoves.count == videoFileNames.count {
            return .success(operation, message: message, affectedPaths: successfulMoves)
        } else if successfulMoves.isEmpty {
            return .failure(operation, error: .systemError("No videos could be moved"))
        } else {
            // Partial success - return success with message about errors
            return .success(operation, message: message, affectedPaths: successfulMoves)
        }
    }
    
    // MARK: - Search and Query
    
    func searchFolders(query: String, in parentPath: String? = nil) -> [FolderMetadata] {
        let searchPath = parentPath ?? currentPath
        let folders = mediaStore.getFolders(in: searchPath)
        
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return folders
        }
        
        let lowercaseQuery = query.lowercased()
        return folders.filter { folder in
            folder.name.lowercased().contains(lowercaseQuery) ||
            folder.path.lowercased().contains(lowercaseQuery)
        }
    }
    
    func getAllSubfolders(in path: String) -> [FolderMetadata] {
        var allFolders: [FolderMetadata] = []
        let directFolders = mediaStore.getFolders(in: path)
        
        allFolders.append(contentsOf: directFolders)
        
        // Recursively get subfolders
        for folder in directFolders {
            let subfolders = getAllSubfolders(in: folder.path)
            allFolders.append(contentsOf: subfolders)
        }
        
        return allFolders
    }
    
    func getDepth(of path: String) -> Int {
        return path.isEmpty ? 0 : path.components(separatedBy: "/").count
    }
    
    // MARK: - Helper Methods
    
    private func updateCurrentPathAfterRename(oldPath: String, newName: String) {
        if currentPath == oldPath {
            // We renamed our current folder
            let parentPath = getParentPath(oldPath)
            currentPath = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
        } else if currentPath.hasPrefix(oldPath + "/") {
            // We renamed a parent folder
            let parentPath = getParentPath(oldPath)
            let newFolderPath = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
            let relativePath = String(currentPath.dropFirst(oldPath.count))
            currentPath = newFolderPath + relativePath
        }
    }
}