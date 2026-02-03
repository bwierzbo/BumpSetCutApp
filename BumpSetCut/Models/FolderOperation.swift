//
//  FolderOperation.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import Foundation

// MARK: - Operation Types

enum FolderOperationType {
    case create(String, parentPath: String)
    case rename(String, newName: String)
    case delete(String, deleteVideos: Bool)
    case move(String, newParentPath: String)
    case bulkMove([String], newParentPath: String)
}

// MARK: - Operation Results

struct FolderOperationResult {
    let success: Bool
    let operation: FolderOperationType
    let affectedPaths: [String]
    let message: String
    let error: FolderOperationError?
    
    static func success(_ operation: FolderOperationType, message: String, affectedPaths: [String] = []) -> FolderOperationResult {
        return FolderOperationResult(
            success: true,
            operation: operation,
            affectedPaths: affectedPaths,
            message: message,
            error: nil
        )
    }
    
    static func failure(_ operation: FolderOperationType, error: FolderOperationError) -> FolderOperationResult {
        return FolderOperationResult(
            success: false,
            operation: operation,
            affectedPaths: [],
            message: error.localizedDescription,
            error: error
        )
    }
}

// MARK: - Error Types

enum FolderOperationError: Error, LocalizedError {
    case invalidName(String)
    case nameConflict(String)
    case pathNotFound(String)
    case circularReference(String)
    case notEmpty(String, videoCount: Int)
    case permissionDenied(String)
    case systemError(String)
    case operationCancelled
    case maxDepthReached

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "Invalid folder name: '\(name)'. Names cannot contain special characters or be empty."
        case .nameConflict(let name):
            return "A folder named '\(name)' already exists in this location."
        case .pathNotFound(let path):
            return "Folder not found: '\(path)'"
        case .circularReference(let path):
            return "Cannot move folder '\(path)': This would create a circular reference."
        case .notEmpty(let path, let videoCount):
            return "Folder '\(path)' contains \(videoCount) videos. Please choose an option for handling them."
        case .permissionDenied(let path):
            return "Permission denied accessing folder: '\(path)'"
        case .systemError(let message):
            return "System error: \(message)"
        case .operationCancelled:
            return "Operation was cancelled"
        case .maxDepthReached:
            return "Cannot create folder: Folders can only be created at the root level."
        }
    }
}

// MARK: - Breadcrumb Navigation

struct BreadcrumbItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isRoot: Bool
    
    init(name: String, path: String) {
        self.name = name
        self.path = path
        self.isRoot = path.isEmpty
    }
}

struct NavigationPath {
    let breadcrumbs: [BreadcrumbItem]
    let currentPath: String
    
    init(path: String) {
        self.currentPath = path
        
        if path.isEmpty {
            self.breadcrumbs = [BreadcrumbItem(name: "Library", path: "")]
        } else {
            var crumbs = [BreadcrumbItem(name: "Library", path: "")]
            let pathComponents = path.split(separator: "/")
            var currentPath = ""
            
            for component in pathComponents {
                if !currentPath.isEmpty {
                    currentPath += "/"
                }
                currentPath += component
                crumbs.append(BreadcrumbItem(name: String(component), path: currentPath))
            }
            
            self.breadcrumbs = crumbs
        }
    }
}

// MARK: - Bulk Operation Support

struct BulkOperationProgress {
    let totalItems: Int
    let completedItems: Int
    let currentItem: String
    let errors: [FolderOperationError]
    
    var progress: Double {
        guard totalItems > 0 else { return 1.0 }
        return Double(completedItems) / Double(totalItems)
    }
    
    var isComplete: Bool {
        return completedItems >= totalItems
    }
}

// MARK: - Validation Rules

struct FolderValidationRules {
    static let maxNameLength = 255
    static let minNameLength = 1
    static let maxDepth = 1  // Simplified: only root-level folders
    static let reservedNames = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
    static let invalidCharacters = CharacterSet(charactersIn: "<>:\"/\\|?*")
    
    static func isValidName(_ name: String) -> Bool {
        // Check length
        guard name.count >= minNameLength && name.count <= maxNameLength else { return false }
        
        // Check for invalid characters
        guard name.rangeOfCharacter(from: invalidCharacters) == nil else { return false }
        
        // Check for reserved names (case insensitive)
        guard !reservedNames.contains(name.uppercased()) else { return false }
        
        // Check for leading/trailing whitespace or dots
        guard name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))) == name else { return false }
        
        return true
    }
    
    static func sanitizeName(_ name: String) -> String {
        var sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Replace invalid characters with underscores
        let invalidChars = "<>:\"/\\|?*"
        for char in invalidChars {
            sanitized = sanitized.replacingOccurrences(of: String(char), with: "_")
        }
        
        // Truncate to max length
        if sanitized.count > maxNameLength {
            sanitized = String(sanitized.prefix(maxNameLength))
        }
        
        // Ensure not empty
        if sanitized.isEmpty {
            sanitized = "New Folder"
        }
        
        return sanitized
    }
}