//
//  RallyCacheManager.swift
//  BumpSetCut
//
//  Persistent rally caching system for instant loading across app launches
//

import Foundation
import CoreMedia

/// Priority modes for thumbnail prefetching coordination
enum PrefetchPriority {
    case immediate  // Positions 1-3 ahead - higher priority
    case extended   // Positions 4-6 ahead - lower priority
}

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

struct ThumbnailCacheEntry: Codable {
    let videoId: UUID
    let timestamp: Double  // CMTime seconds
    let fileName: String
    let fileSize: Int
    let createdDate: Date
    let lastAccessed: Date

    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".thumbnails")
            .appendingPathComponent(fileName)
    }
}

struct RallyCacheManifest: Codable {
    var entries: [UUID: [RallyCacheEntry]] = [:]
    var thumbnails: [String: ThumbnailCacheEntry] = [:]  // Key: "\(videoId)_\(timestamp)"
    var lastValidated: Date = Date()
    var cacheHits: Int = 0
    var cacheMisses: Int = 0
    var thumbnailHits: Int = 0
    var thumbnailMisses: Int = 0

    var hitRate: Double {
        let total = cacheHits + cacheMisses
        return total > 0 ? Double(cacheHits) / Double(total) : 0.0
    }

    var thumbnailHitRate: Double {
        let total = thumbnailHits + thumbnailMisses
        return total > 0 ? Double(thumbnailHits) / Double(total) : 0.0
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

        // Create thumbnails directory if needed
        let thumbnailsDir = documentsURL.appendingPathComponent(".thumbnails")
        if !FileManager.default.fileExists(atPath: thumbnailsDir.path) {
            try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        }

        // Load existing manifest or create new one
        if let data = try? Data(contentsOf: manifestURL),
           let loadedManifest = try? JSONDecoder().decode(RallyCacheManifest.self, from: data) {
            self.manifest = loadedManifest
            print("📁 Loaded rally cache manifest: \(manifest.entries.keys.count) videos, \(manifest.thumbnails.count) thumbnails cached")
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
        let rallyFiles = manifest.entries.values.flatMap { $0 }.count
        let thumbnailFiles = manifest.thumbnails.count
        let totalFiles = rallyFiles + thumbnailFiles

        let rallySizeBytes = manifest.entries.values.flatMap { $0 }.reduce(0) { $0 + $1.fileSize }
        let thumbnailSizeBytes = manifest.thumbnails.values.reduce(0) { $0 + $1.fileSize }
        let totalSizeBytes = rallySizeBytes + thumbnailSizeBytes

        // Combined hit rate
        let totalHits = manifest.cacheHits + manifest.thumbnailHits
        let totalMisses = manifest.cacheMisses + manifest.thumbnailMisses
        let combinedHitRate = (totalHits + totalMisses) > 0 ? Double(totalHits) / Double(totalHits + totalMisses) : 0.0

        return CacheStats(
            totalFiles: totalFiles,
            totalSizeBytes: totalSizeBytes,
            hitRate: combinedHitRate,
            lastCleanup: manifest.lastValidated
        )
    }

    /// Clear all cache
    func clearAllCache() {
        // Clear rally segments
        for entries in manifest.entries.values {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }

        // Clear thumbnails
        for entry in manifest.thumbnails.values {
            try? FileManager.default.removeItem(at: entry.url)
        }

        manifest.entries.removeAll()
        manifest.thumbnails.removeAll()
        manifest.cacheHits = 0
        manifest.cacheMisses = 0
        manifest.thumbnailHits = 0
        manifest.thumbnailMisses = 0
        saveManifest()

        print("📁 Cleared all rally cache and thumbnails")
    }

    /// Remove cache for specific video
    func removeCacheForVideo(_ videoId: UUID) {
        // Remove rally segments
        if let entries = manifest.entries[videoId] {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry.url)
            }
            manifest.entries.removeValue(forKey: videoId)
        }

        // Remove thumbnails
        let thumbnailKeysToRemove = manifest.thumbnails.keys.filter { key in
            key.hasPrefix(videoId.uuidString)
        }
        for key in thumbnailKeysToRemove {
            if let entry = manifest.thumbnails[key] {
                try? FileManager.default.removeItem(at: entry.url)
            }
            manifest.thumbnails.removeValue(forKey: key)
        }

        saveManifest()
        print("📁 Removed cache and thumbnails for video \(videoId)")
    }

    // MARK: - Thumbnail Cache Operations
    /// Get cached thumbnail data for a video at a specific timestamp
    func getCachedThumbnail(for videoId: UUID, at timestamp: Double) -> Data? {
        let key = "\(videoId.uuidString)_\(timestamp)"
        guard let entry = manifest.thumbnails[key] else {
            manifest.thumbnailMisses += 1
            return nil
        }

        // Validate file exists
        if !FileManager.default.fileExists(atPath: entry.url.path) {
            manifest.thumbnails.removeValue(forKey: key)
            manifest.thumbnailMisses += 1
            saveManifest()
            return nil
        }

        // Update access time
        updateThumbnailAccessTime(for: key)
        manifest.thumbnailHits += 1
        saveManifest()

        do {
            return try Data(contentsOf: entry.url)
        } catch {
            print("❌ Failed to read thumbnail: \(error)")
            return nil
        }
    }

    /// Store thumbnail data for a video at a specific timestamp
    func storeThumbnail(_ data: Data, for videoId: UUID, at timestamp: Double) {
        let key = "\(videoId.uuidString)_\(timestamp)"
        let fileName = "\(key).jpg"
        let thumbnailsDir = documentsURL.appendingPathComponent(".thumbnails")
        let fileURL = thumbnailsDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL)

            let entry = ThumbnailCacheEntry(
                videoId: videoId,
                timestamp: timestamp,
                fileName: fileName,
                fileSize: data.count,
                createdDate: Date(),
                lastAccessed: Date()
            )

            manifest.thumbnails[key] = entry
            saveManifest()

            print("📸 Cached thumbnail for \(videoId) at \(timestamp)s: \(data.count / 1024) KB")
        } catch {
            print("❌ Failed to save thumbnail: \(error)")
        }
    }

    /// Enhanced prefetch thumbnails for upcoming rallies with intelligent prioritization
    func prefetchThumbnails(for videoId: UUID, timestamps: [Double], videoURL: URL, priorityMode: PrefetchPriority = .extended) {
        guard !timestamps.isEmpty else { return }

        var framesToPrefetch: [(URL, CMTime)] = []

        for timestamp in timestamps {
            let key = "\(videoId.uuidString)_\(timestamp)"
            // Skip if already cached
            if manifest.thumbnails[key] != nil {
                continue
            }

            let cmTime = CMTime(seconds: timestamp, preferredTimescale: 600)
            framesToPrefetch.append((videoURL, cmTime))
        }

        guard !framesToPrefetch.isEmpty else {
            print("📸 All thumbnails already cached for \(videoId)")
            return
        }

        print("📸 Prefetching \(framesToPrefetch.count) thumbnails for \(videoId) with \(priorityMode) priority")

        // Coordinate with FrameExtractor based on priority
        let requests: [(URL, CMTime)] = framesToPrefetch

        switch priorityMode {
        case .immediate:
            FrameExtractor.shared.prefetchThumbnails(for: requests, priority: .high)
        case .extended:
            FrameExtractor.shared.prefetchThumbnails(for: requests, priority: .low)
        }
    }

    /// Batch prefetch for multiple videos with optimized scheduling
    func batchPrefetchThumbnails(requests: [(videoId: UUID, timestamps: [Double], videoURL: URL, priority: PrefetchPriority)]) {
        print("📸 Starting batch prefetch for \(requests.count) video sets")

        // Sort by priority: immediate first, then extended
        let sortedRequests = requests.sorted { lhs, rhs in
            switch (lhs.priority, rhs.priority) {
            case (.immediate, .extended):
                return true
            case (.extended, .immediate):
                return false
            default:
                return false
            }
        }

        for request in sortedRequests {
            prefetchThumbnails(
                for: request.videoId,
                timestamps: request.timestamps,
                videoURL: request.videoURL,
                priorityMode: request.priority
            )
        }
    }

    /// Smart prefetch based on navigation position and video stack context
    func smartPrefetch(currentVideoId: UUID, upcomingVideos: [(videoId: UUID, videoURL: URL, timestamps: [Double])]) {
        guard !upcomingVideos.isEmpty else { return }

        var prefetchRequests: [(videoId: UUID, timestamps: [Double], videoURL: URL, priority: PrefetchPriority)] = []

        for (index, video) in upcomingVideos.enumerated() {
            let priority: PrefetchPriority = index < 3 ? .immediate : .extended
            prefetchRequests.append((
                videoId: video.videoId,
                timestamps: video.timestamps,
                videoURL: video.videoURL,
                priority: priority
            ))
        }

        batchPrefetchThumbnails(requests: prefetchRequests)
    }

    /// Get prefetch coordination metrics from FrameExtractor
    func getPrefetchStatus() -> (queuedFrames: Int, completedPrefetches: Int, successRate: Double, memoryPressureSkips: Int) {
        let metrics = FrameExtractor.shared.performanceMetrics
        return (
            queuedFrames: 0, // Not available in current API
            completedPrefetches: 0, // Not available in current API
            successRate: 1.0 - metrics.errorRate,
            memoryPressureSkips: metrics.memoryPressureEvents
        )
    }

    /// Check if FrameExtractor is under memory pressure
    var isUnderMemoryPressure: Bool {
        return FrameExtractor.shared.isUnderMemoryPressure
    }

    /// Extract timestamp from video URL for prefetch coordination
    private func extractTimestampFromURL(_ url: URL) -> Double? {
        // For prefetch coordination, we'll use a default timestamp of 0.5 seconds
        // This represents the typical thumbnail extraction point
        return 0.5
    }

    /// Force cache synchronization with FrameExtractor when thumbnails are extracted
    func syncThumbnailFromFrameExtractor(videoId: UUID, timestamp: Double, imageData: Data) {
        // Store the extracted thumbnail in our cache system
        storeThumbnail(imageData, for: videoId, at: timestamp)
        print("📸 Synced thumbnail from FrameExtractor: \(videoId) at \(timestamp)s")
    }

    /// Clear prefetch queues in FrameExtractor when cache is cleared
    func clearAllCacheWithCoordination() {
        // Clear our own cache first
        for entries in manifest.entries.values {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }

        for entry in manifest.thumbnails.values {
            try? FileManager.default.removeItem(at: entry.url)
        }

        manifest.entries.removeAll()
        manifest.thumbnails.removeAll()
        manifest.cacheHits = 0
        manifest.cacheMisses = 0
        manifest.thumbnailHits = 0
        manifest.thumbnailMisses = 0
        saveManifest()

        // Clear FrameExtractor cache as well for coordination
        FrameExtractor.shared.clearCache()

        print("📁 Cleared all rally cache, thumbnails, and FrameExtractor cache")
    }

    /// Clean up old thumbnails based on LRU policy
    func cleanupThumbnails(maxCount: Int = 100) {
        guard manifest.thumbnails.count > maxCount else { return }

        // Sort thumbnails by last access time
        let sortedThumbnails = manifest.thumbnails.sorted { $0.value.lastAccessed < $1.value.lastAccessed }

        // Remove oldest thumbnails
        let countToRemove = manifest.thumbnails.count - maxCount
        for (key, entry) in sortedThumbnails.prefix(countToRemove) {
            try? FileManager.default.removeItem(at: entry.url)
            manifest.thumbnails.removeValue(forKey: key)
        }

        saveManifest()
        print("📸 Cleaned up \(countToRemove) old thumbnails")
    }

    private func updateThumbnailAccessTime(for key: String) {
        guard let entry = manifest.thumbnails[key] else { return }

        manifest.thumbnails[key] = ThumbnailCacheEntry(
            videoId: entry.videoId,
            timestamp: entry.timestamp,
            fileName: entry.fileName,
            fileSize: entry.fileSize,
            createdDate: entry.createdDate,
            lastAccessed: Date()
        )
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

        // Clean up excess thumbnails
        cleanupThumbnails(maxCount: 100)

        let stats = getCacheStats()
        print("📊 Cache stats: \(stats.totalFiles) files, \(String(format: "%.1f", stats.totalSizeMB)) MB, \(String(format: "%.1f", stats.hitRate * 100))% hit rate")
    }

    /// Perform lighter cache maintenance in background
    func performBackgroundMaintenance() {
        validateCache()
        // Less aggressive cleanup in background
        cleanupOldCache(maxAge: 30 * 24 * 60 * 60) // 30 days
    }
}