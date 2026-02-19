//
//  StorageChecker.swift
//  BumpSetCut
//
//  Utility to check available device storage before operations
//

import Foundation

enum StorageChecker {
    /// Check if there's enough storage space for an operation
    /// - Parameters:
    ///   - requiredBytes: The number of bytes needed for the operation
    ///   - safetyMargin: Additional margin to keep free (default 100MB)
    /// - Returns: A result with available space or an error describing the shortage
    static func checkAvailableSpace(requiredBytes: Int64, safetyMargin: Int64 = 100_000_000) -> StorageCheckResult {
        let availableBytes = getAvailableSpace()
        let totalRequired = requiredBytes + safetyMargin

        if availableBytes >= totalRequired {
            return .sufficient(available: availableBytes)
        } else {
            let shortage = totalRequired - availableBytes
            return .insufficient(
                available: availableBytes,
                required: totalRequired,
                shortage: shortage
            )
        }
    }

    /// Get the available storage space on the device
    /// - Returns: Available bytes, or 0 if unable to determine
    static func getAvailableSpace() -> Int64 {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first

        guard let url = documentsURL else { return 0 }

        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            // Fallback to older API
            do {
                let attributes = try fileManager.attributesOfFileSystem(forPath: url.path)
                return (attributes[.systemFreeSize] as? Int64) ?? 0
            } catch {
                return 0
            }
        }
    }

    /// Get the size of a file at the given URL
    /// - Parameter url: The file URL
    /// - Returns: File size in bytes, or 0 if unable to determine
    static func getFileSize(at url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? Int64) ?? 0
        } catch {
            return 0
        }
    }

    /// Threshold for "low storage" warning (500 MB)
    static let lowStorageThreshold: Int64 = 500_000_000

    /// Check if device storage is running low
    static func isStorageLow() -> (isLow: Bool, available: Int64) {
        let available = getAvailableSpace()
        return (available < lowStorageThreshold, available)
    }

    /// Check if an error is a storage-full error
    static func isStorageError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // POSIX "No space left on device" (errno 28)
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 { return true }
        // Cocoa file write error with underlying POSIX 28
        if nsError.domain == NSCocoaErrorDomain,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain && underlying.code == 28 { return true }
        // Check localizedDescription as last resort
        let desc = error.localizedDescription.lowercased()
        return desc.contains("no space left") || desc.contains("not enough space") || desc.contains("disk full")
    }

    /// Format bytes into a human-readable string
    /// - Parameter bytes: Number of bytes
    /// - Returns: Formatted string (e.g., "1.5 GB")
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Storage Check Result

enum StorageCheckResult {
    case sufficient(available: Int64)
    case insufficient(available: Int64, required: Int64, shortage: Int64)

    var isSufficient: Bool {
        if case .sufficient = self { return true }
        return false
    }

    var errorMessage: String? {
        switch self {
        case .sufficient:
            return nil
        case .insufficient(let available, let required, let shortage):
            let availableStr = StorageChecker.formatBytes(available)
            let requiredStr = StorageChecker.formatBytes(required)
            let shortageStr = StorageChecker.formatBytes(shortage)
            return "Not enough storage space. You have \(availableStr) available but need \(requiredStr). Please free up at least \(shortageStr) to continue."
        }
    }

    var shortMessage: String? {
        switch self {
        case .sufficient:
            return nil
        case .insufficient(_, _, let shortage):
            return "Free up \(StorageChecker.formatBytes(shortage)) to continue"
        }
    }
}
