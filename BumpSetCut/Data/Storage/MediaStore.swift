//
//  MediaStore.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import Foundation

protocol CaptureDelegate: AnyObject {
    func presentCaptureInterface()
}

// MARK: - Video Metadata Models

struct VideoMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    let originalURL: URL
    var customName: String?
    var folderPath: String
    let createdDate: Date
    let fileSize: Int64
    let duration: TimeInterval?
    
    var displayName: String {
        customName ?? originalURL.deletingPathExtension().lastPathComponent
    }
    
    var fileName: String {
        originalURL.lastPathComponent
    }
    
    init(originalURL: URL, customName: String?, folderPath: String, createdDate: Date, fileSize: Int64, duration: TimeInterval?) {
        self.id = UUID()
        self.originalURL = originalURL
        self.customName = customName
        self.folderPath = folderPath
        self.createdDate = createdDate
        self.fileSize = fileSize
        self.duration = duration
    }
}

struct FolderMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var parentPath: String?
    let createdDate: Date
    var modifiedDate: Date
    var videoCount: Int
    var subfolderCount: Int
    
    init(name: String, path: String, parentPath: String?, createdDate: Date, modifiedDate: Date, videoCount: Int, subfolderCount: Int) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.videoCount = videoCount
        self.subfolderCount = subfolderCount
    }
}

// MARK: - Folder Manifest

struct FolderManifest: Codable {
    var folders: [String: FolderMetadata] = [:]
    var videos: [String: VideoMetadata] = [:]
    var version: Int = 1
    let createdDate: Date
    var lastModified: Date
    
    init() {
        let now = Date()
        self.createdDate = now
        self.lastModified = now
    }
    
    mutating func updateModifiedDate() {
        lastModified = Date()
    }
}

@MainActor class MediaStore: ObservableObject {
    weak var captureDelegate: CaptureDelegate?
    
    private var manifest: FolderManifest
    private let manifestURL: URL
    let baseDirectory: URL
    
    init() {
        let fileManager = FileManager.default
        self.baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BumpSetCut", isDirectory: true)
        
        self.manifestURL = baseDirectory.appendingPathComponent("manifest.json")
        
        // Create base directory if it doesn't exist
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        
        // Load or create manifest
        if let data = try? Data(contentsOf: manifestURL),
           let loadedManifest = try? JSONDecoder().decode(FolderManifest.self, from: data) {
            self.manifest = loadedManifest
        } else {
            self.manifest = FolderManifest()
            saveManifest()
        }
    }
    
    private func saveManifest() {
        do {
            manifest.updateModifiedDate()
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL)
        } catch {
            print("Failed to save manifest: \(error)")
        }
    }
}

// MARK: - Folder Operations

extension MediaStore {
    func createFolder(name: String, parentPath: String = "") -> Bool {
        let folderPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        
        // Check if folder already exists
        if manifest.folders[folderPath] != nil {
            return false
        }
        
        let physicalURL = baseDirectory.appendingPathComponent(folderPath, isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true, attributes: nil)
            
            let folderMetadata = FolderMetadata(
                name: name,
                path: folderPath,
                parentPath: parentPath.isEmpty ? nil : parentPath,
                createdDate: Date(),
                modifiedDate: Date(),
                videoCount: 0,
                subfolderCount: 0
            )
            
            manifest.folders[folderPath] = folderMetadata
            
            // Update parent folder subfolder count
            if !parentPath.isEmpty {
                manifest.folders[parentPath]?.subfolderCount += 1
                manifest.folders[parentPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to create folder: \(error)")
            return false
        }
    }
    
    func renameFolder(at path: String, to newName: String) -> Bool {
        guard var folderMetadata = manifest.folders[path] else { return false }
        
        let parentPath = folderMetadata.parentPath ?? ""
        let newPath = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
        
        if manifest.folders[newPath] != nil {
            return false // Name already exists
        }
        
        let oldURL = baseDirectory.appendingPathComponent(path, isDirectory: true)
        let newURL = baseDirectory.appendingPathComponent(newPath, isDirectory: true)
        
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            
            // Update folder metadata
            folderMetadata.name = newName
            folderMetadata.path = newPath
            folderMetadata.modifiedDate = Date()
            
            manifest.folders.removeValue(forKey: path)
            manifest.folders[newPath] = folderMetadata
            
            // Update all child folders and videos
            updateChildPaths(oldPath: path, newPath: newPath)
            
            saveManifest()
            return true
        } catch {
            print("Failed to rename folder: \(error)")
            return false
        }
    }
    
    func deleteFolder(at path: String) -> Bool {
        guard let folderMetadata = manifest.folders[path] else { return false }
        
        let physicalURL = baseDirectory.appendingPathComponent(path, isDirectory: true)
        
        do {
            try FileManager.default.removeItem(at: physicalURL)
            
            // Remove folder from manifest
            manifest.folders.removeValue(forKey: path)
            
            // Remove all child folders and videos
            removeChildItems(at: path)
            
            // Update parent folder subfolder count
            if let parentPath = folderMetadata.parentPath {
                manifest.folders[parentPath]?.subfolderCount -= 1
                manifest.folders[parentPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to delete folder: \(error)")
            return false
        }
    }
    
    private func updateChildPaths(oldPath: String, newPath: String) {
        // Update child folders
        let childFolders = manifest.folders.filter { $0.value.parentPath == oldPath }
        for (_, var folder) in childFolders {
            let oldFolderPath = folder.path
            let newFolderPath = folder.path.replacingOccurrences(of: oldPath, with: newPath)
            
            manifest.folders.removeValue(forKey: oldFolderPath)
            folder.path = newFolderPath
            folder.parentPath = newPath
            manifest.folders[newFolderPath] = folder
        }
        
        // Update child videos
        let childVideos = manifest.videos.filter { $0.value.folderPath == oldPath }
        for (videoKey, var video) in childVideos {
            video.folderPath = newPath
            manifest.videos[videoKey] = video
        }
    }
    
    private func removeChildItems(at path: String) {
        // Remove child folders
        let childFolders = manifest.folders.filter { $0.key.hasPrefix("\(path)/") }
        for (folderKey, _) in childFolders {
            manifest.folders.removeValue(forKey: folderKey)
        }
        
        // Remove child videos
        let childVideos = manifest.videos.filter { $0.value.folderPath.hasPrefix(path) }
        for (videoKey, _) in childVideos {
            manifest.videos.removeValue(forKey: videoKey)
        }
    }
}

// MARK: - Video Operations

extension MediaStore {
    func addVideo(at url: URL, toFolder folderPath: String = "", customName: String? = nil) -> Bool {
        let videoKey = url.lastPathComponent
        
        // Get file attributes
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return false
        }
        
        let videoMetadata = VideoMetadata(
            originalURL: url,
            customName: customName,
            folderPath: folderPath,
            createdDate: attributes[.creationDate] as? Date ?? Date(),
            fileSize: fileSize,
            duration: nil // Can be populated later if needed
        )
        
        manifest.videos[videoKey] = videoMetadata
        
        // Update folder video count
        if !folderPath.isEmpty {
            manifest.folders[folderPath]?.videoCount += 1
            manifest.folders[folderPath]?.modifiedDate = Date()
        }
        
        saveManifest()
        return true
    }
    
    func moveVideo(fileName: String, toFolder newFolderPath: String) -> Bool {
        guard var videoMetadata = manifest.videos[fileName] else { return false }
        
        let oldFolderPath = videoMetadata.folderPath
        let fileURL = baseDirectory.appendingPathComponent(oldFolderPath).appendingPathComponent(fileName)
        let newFileURL = baseDirectory.appendingPathComponent(newFolderPath).appendingPathComponent(fileName)
        
        do {
            // Ensure destination directory exists
            try FileManager.default.createDirectory(
                at: newFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            
            try FileManager.default.moveItem(at: fileURL, to: newFileURL)
            
            // Update metadata
            videoMetadata.folderPath = newFolderPath
            manifest.videos[fileName] = videoMetadata
            
            // Update folder counts
            if !oldFolderPath.isEmpty {
                manifest.folders[oldFolderPath]?.videoCount -= 1
                manifest.folders[oldFolderPath]?.modifiedDate = Date()
            }
            
            if !newFolderPath.isEmpty {
                manifest.folders[newFolderPath]?.videoCount += 1
                manifest.folders[newFolderPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to move video: \(error)")
            return false
        }
    }
    
    func renameVideo(fileName: String, to newName: String) -> Bool {
        guard var videoMetadata = manifest.videos[fileName] else { return false }
        
        videoMetadata.customName = newName
        manifest.videos[fileName] = videoMetadata
        saveManifest()
        return true
    }
    
    func deleteVideo(fileName: String) -> Bool {
        guard let videoMetadata = manifest.videos[fileName] else { return false }
        
        let folderPath = videoMetadata.folderPath
        let fileURL = baseDirectory.appendingPathComponent(folderPath).appendingPathComponent(fileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            
            manifest.videos.removeValue(forKey: fileName)
            
            // Update folder video count
            if !folderPath.isEmpty {
                manifest.folders[folderPath]?.videoCount -= 1
                manifest.folders[folderPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to delete video: \(error)")
            return false
        }
    }
}

// MARK: - Query Operations

extension MediaStore {
    func getFolders(in parentPath: String = "") -> [FolderMetadata] {
        return manifest.folders.values
            .filter { $0.parentPath == (parentPath.isEmpty ? nil : parentPath) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    func getVideos(in folderPath: String = "") -> [VideoMetadata] {
        return manifest.videos.values
            .filter { $0.folderPath == folderPath }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    
    func searchVideos(query: String) -> [VideoMetadata] {
        let lowercaseQuery = query.lowercased()
        return manifest.videos.values.filter { video in
            video.displayName.lowercased().contains(lowercaseQuery) ||
            video.fileName.lowercased().contains(lowercaseQuery)
        }
    }
    
    func searchFolders(query: String) -> [FolderMetadata] {
        let lowercaseQuery = query.lowercased()
        return manifest.folders.values.filter { folder in
            folder.name.lowercased().contains(lowercaseQuery) ||
            folder.path.lowercased().contains(lowercaseQuery)
        }
    }
    
    func getAllFolders() -> [FolderMetadata] {
        return Array(manifest.folders.values)
    }
    
    func getAllVideos() -> [VideoMetadata] {
        return Array(manifest.videos.values)
    }
    
    func advancedSearchVideos(
        query: String,
        fileType: String? = nil,
        minSize: Int64? = nil,
        maxSize: Int64? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil,
        inFolder: String? = nil
    ) -> [VideoMetadata] {
        var results = Array(manifest.videos.values)
        
        // Text search
        if !query.isEmpty {
            let lowercaseQuery = query.lowercased()
            results = results.filter { video in
                video.displayName.lowercased().contains(lowercaseQuery) ||
                video.fileName.lowercased().contains(lowercaseQuery)
            }
        }
        
        // File type filter
        if let fileType = fileType, !fileType.isEmpty {
            results = results.filter { video in
                video.fileName.lowercased().hasSuffix(".\(fileType.lowercased())")
            }
        }
        
        // Size filters
        if let minSize = minSize {
            results = results.filter { $0.fileSize >= minSize }
        }
        
        if let maxSize = maxSize {
            results = results.filter { $0.fileSize <= maxSize }
        }
        
        // Date filters
        if let fromDate = fromDate {
            results = results.filter { $0.createdDate >= fromDate }
        }
        
        if let toDate = toDate {
            results = results.filter { $0.createdDate <= toDate }
        }
        
        // Folder filter
        if let inFolder = inFolder {
            if inFolder.isEmpty {
                // Root folder only
                results = results.filter { $0.folderPath.isEmpty }
            } else {
                // Specific folder and its subfolders
                results = results.filter { 
                    $0.folderPath == inFolder || $0.folderPath.hasPrefix("\(inFolder)/")
                }
            }
        }
        
        return results
    }
    
    func getFolderMetadata(at path: String) -> FolderMetadata? {
        return manifest.folders[path]
    }
    
    func getVideoMetadata(fileName: String) -> VideoMetadata? {
        return manifest.videos[fileName]
    }
}

// MARK: - Migration

extension MediaStore {
    func migrateExistingVideos() {
        let fileManager = FileManager.default
        
        // Find all videos in root documents directory
        if let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]) {
            let videoFiles = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mov" || ext == "mp4"
            }
            
            for videoURL in videoFiles {
                let fileName = videoURL.lastPathComponent
                
                // Skip if already in manifest
                if manifest.videos[fileName] != nil {
                    continue
                }
                
                // Add to root folder (empty path)
                _ = addVideo(at: videoURL, toFolder: "", customName: nil)
            }
        }
    }
}

// MARK: - Legacy Compatibility Layer

extension MediaStore {
    @available(*, deprecated, message: "Use getVideos(in:) with folder path parameter")
    func getAllVideoURLs() -> [URL] {
        let videos = getVideos(in: "")
        return videos.compactMap { video in
            let fullPath = baseDirectory.appendingPathComponent(video.folderPath).appendingPathComponent(video.fileName)
            return URL(fileURLWithPath: fullPath.path)
        }
    }
    
    @available(*, deprecated, message: "Use addVideo(at:toFolder:customName:) instead")
    func saveVideo(at url: URL) -> Bool {
        return addVideo(at: url, toFolder: "", customName: nil)
    }
    
    @available(*, deprecated, message: "Use deleteVideo(fileName:) instead")
    func removeVideo(at url: URL) -> Bool {
        let fileName = url.lastPathComponent
        return deleteVideo(fileName: fileName)
    }
    
    func getVideoURL(for metadata: VideoMetadata) -> URL {
        return baseDirectory
            .appendingPathComponent(metadata.folderPath)
            .appendingPathComponent(metadata.fileName)
    }
    
    func loadVideosFromDocuments() -> [URL] {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        guard let files = try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "mov" || ext == "mp4"
        }
    }
    
    func needsMigration() -> Bool {
        return !loadVideosFromDocuments().isEmpty
    }
}

// MARK: - Original Capture Functionality

extension MediaStore {
    func presentCapturePopup() {
        captureDelegate?.presentCaptureInterface()
    }
}


