//
//  RallyCacheManager.swift
//  BumpSetCut
//
//  Persistent rally caching system for instant loading across app launches
//

import Foundation

struct CacheStats {
    let totalFiles: Int
    let totalSizeBytes: Int
    let hitRate: Double
    let lastCleanup: Date?

    var totalSizeMB: Double {
        Double(totalSizeBytes) / 1024 / 1024
    }
}

struct RallyCacheEntry: Codable {
    let rallyIndex: Int
    let fileName: String
    let fileSize: Int
    let createdDate: Date
    let lastAccessed: Date

    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}

struct RallyCacheManifest: Codable {
    var entries: [UUID: [RallyCacheEntry]] = [:]
    var lastValidated: Date = Date()
    var cacheHits: Int = 0
    var cacheMisses: Int = 0

    var hitRate: Double {
        let total = cacheHits + cacheMisses
        return total > 0 ? Double(cacheHits) / Double(total) : 0.0
    }
}

@MainActor
final class RallyCacheManager: ObservableObject {
    // MARK: - Properties
    private var manifest: RallyCacheManifest
    private let manifestURL: URL
    private let documentsURL: URL

    // MARK: - Initialization
    init() {
        self.documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.manifestURL = documentsURL.appendingPathComponent("rally_cache_manifest.json")

        // Load existing manifest or create new one
        if let data = try? Data(contentsOf: manifestURL),
           let loadedManifest = try? JSONDecoder().decode(RallyCacheManifest.self, from: data) {
            self.manifest = loadedManifest
            print("📁 Loaded rally cache manifest: \(manifest.entries.keys.count) videos cached")
        } else {
            self.manifest = RallyCacheManifest()
            print("📁 Created new rally cache manifest")
        }
    }

    // MARK: - Cache Operations
    /// Get cached rally URLs for a video, returns nil if not fully cached
    func getCachedRallyURLs(for videoId: UUID) -> [URL]? {
        guard let cacheEntries = manifest.entries[videoId] else {
            manifest.cacheMisses += 1
            return nil
        }

        // Validate all cache files exist
        let urls = cacheEntries.sorted { $0.rallyIndex < $1.rallyIndex }.map { $0.url }
        for url in urls {
            if !FileManager.default.fileExists(atPath: url.path) {
                print("📁 Cache miss: Missing file \(url.lastPathComponent)")
                manifest.cacheMisses += 1
                // Remove invalid entry
                manifest.entries.removeValue(forKey: videoId)
                saveManifest()
                return nil
            }
        }

        // Update access time
        updateAccessTime(for: videoId)
        manifest.cacheHits += 1
        saveManifest()

        print("📁 Cache hit: \(urls.count) rallies for \(videoId)")
        return urls
    }

    /// Store cached rally URLs for a video
    func storeCachedRallies(_ videoId: UUID, _ urls: [URL]) {
        var cacheEntries: [RallyCacheEntry] = []

        for (index, url) in urls.enumerated() {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes[.size] as? Int ?? 0

                let entry = RallyCacheEntry(
                    rallyIndex: index,
                    fileName: url.lastPathComponent,
                    fileSize: fileSize,
                    createdDate: Date(),
                    lastAccessed: Date()
                )
                cacheEntries.append(entry)
            } catch {
                print("❌ Failed to get file attributes for \(url.lastPathComponent): \(error)")
            }
        }

        manifest.entries[videoId] = cacheEntries
        saveManifest()

        let totalSize = cacheEntries.reduce(0) { $0 + $1.fileSize }
        print("📁 Cached \(cacheEntries.count) rallies for \(videoId): \(String(format: "%.1f", Double(totalSize) / 1024 / 1024)) MB")
    }

    /// Validate entire cache, removing invalid entries
    func validateCache() {
        var invalidVideoIds: Set<UUID> = []

        for (videoId, entries) in manifest.entries {
            for entry in entries {
                if !FileManager.default.fileExists(atPath: entry.url.path) {
                    print("📁 Invalid cache entry: \(entry.fileName)")
                    invalidVideoIds.insert(videoId)
                    break
                }
            }
        }

        // Remove invalid entries
        for videoId in invalidVideoIds {
            manifest.entries.removeValue(forKey: videoId)
        }

        manifest.lastValidated = Date()
        saveManifest()

        if !invalidVideoIds.isEmpty {
            print("📁 Removed \(invalidVideoIds.count) invalid cache entries")
        }
    }

    /// Clean up old cache files based on age and access time
    func cleanupOldCache(maxAge: TimeInterval = 30 * 24 * 60 * 60) { // 30 days default
        let cutoffDate = Date().addingTimeInterval(-maxAge)
        var removedVideoIds: Set<UUID> = []

        for (videoId, entries) in manifest.entries {
            // Check if any entry is old
            let hasOldEntries = entries.contains { entry in
                entry.lastAccessed < cutoffDate || entry.createdDate < cutoffDate
            }

            if hasOldEntries {
                // Remove all files for this video
                for entry in entries {
                    do {
                        try FileManager.default.removeItem(at: entry.url)
                        print("📁 Removed old cache file: \(entry.fileName)")
                    } catch {
                        print("❌ Failed to remove cache file \(entry.fileName): \(error)")
                    }
                }
                removedVideoIds.insert(videoId)
            }
        }

        // Update manifest
        for videoId in removedVideoIds {
            manifest.entries.removeValue(forKey: videoId)
        }

        if !removedVideoIds.isEmpty {
            saveManifest()
            print("📁 Cleaned up cache for \(removedVideoIds.count) videos")
        }
    }

    /// Get cache statistics
    func getCacheStats() -> CacheStats {
        let totalFiles = manifest.entries.values.flatMap { $0 }.count
        let totalSizeBytes = manifest.entries.values.flatMap { $0 }.reduce(0) { $0 + $1.fileSize }

        return CacheStats(
            totalFiles: totalFiles,
            totalSizeBytes: totalSizeBytes,
            hitRate: manifest.hitRate,
            lastCleanup: manifest.lastValidated
        )
    }

    /// Clear all cache
    func clearAllCache() {
        for entries in manifest.entries.values {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }

        manifest.entries.removeAll()
        manifest.cacheHits = 0
        manifest.cacheMisses = 0
        saveManifest()

        print("📁 Cleared all rally cache")
    }

    /// Remove cache for specific video
    func removeCacheForVideo(_ videoId: UUID) {
        guard let entries = manifest.entries[videoId] else { return }

        for entry in entries {
            try? FileManager.default.removeItem(at: entry.url)
        }

        manifest.entries.removeValue(forKey: videoId)
        saveManifest()

        print("📁 Removed cache for video \(videoId)")
    }

    // MARK: - Private Methods
    private func updateAccessTime(for videoId: UUID) {
        guard var entries = manifest.entries[videoId] else { return }

        for i in entries.indices {
            entries[i] = RallyCacheEntry(
                rallyIndex: entries[i].rallyIndex,
                fileName: entries[i].fileName,
                fileSize: entries[i].fileSize,
                createdDate: entries[i].createdDate,
                lastAccessed: Date()
            )
        }

        manifest.entries[videoId] = entries
    }

    private func saveManifest() {
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL)
        } catch {
            print("❌ Failed to save rally cache manifest: \(error)")
        }
    }
}

// MARK: - App Lifecycle Integration
extension RallyCacheManager {
    /// Perform cache maintenance on app launch
    func performAppLaunchMaintenance() {
        print("📁 Starting rally cache maintenance...")

        // Validate cache integrity
        validateCache()

        // Clean up very old cache (more aggressive on launch)
        cleanupOldCache(maxAge: 14 * 24 * 60 * 60) // 14 days

        let stats = getCacheStats()
        print("📊 Rally cache stats: \(stats.totalFiles) files, \(String(format: "%.1f", stats.totalSizeMB)) MB, \(String(format: "%.1f", stats.hitRate * 100))% hit rate")
    }

    /// Perform lighter cache maintenance in background
    func performBackgroundMaintenance() {
        validateCache()
        // Less aggressive cleanup in background
        cleanupOldCache(maxAge: 30 * 24 * 60 * 60) // 30 days
    }
}