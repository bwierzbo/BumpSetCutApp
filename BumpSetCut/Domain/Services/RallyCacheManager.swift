//
//  RallyCacheManager.swift
//  BumpSetCut
//
//  Created for Issue #60 Stream C - Rally Segment Preloading
//

import AVFoundation
import Foundation

/// Priority levels for rally segment preloading
enum RallyPreloadPriority: Int, CaseIterable {
    case high = 0      // Current rally being played
    case normal = 1    // Next 1-2 rallies
    case low = 2       // Future rallies beyond next 2

    var description: String {
        switch self {
        case .high: return "High (Current)"
        case .normal: return "Normal (Next 1-2)"
        case .low: return "Low (Future)"
        }
    }
}

/// Cache entry for a rally segment
struct RallyCacheEntry {
    let id: UUID
    let videoId: UUID
    let rallyIndex: Int
    let url: URL
    let creationDate: Date
    let lastAccessDate: Date
    let fileSize: Int64
    let priority: RallyPreloadPriority
    let isValidated: Bool

    /// Update last access date for LRU cache management
    func accessed() -> RallyCacheEntry {
        return RallyCacheEntry(
            id: id,
            videoId: videoId,
            rallyIndex: rallyIndex,
            url: url,
            creationDate: creationDate,
            lastAccessDate: Date(),
            fileSize: fileSize,
            priority: priority,
            isValidated: isValidated
        )
    }
}

/// Rally cache performance metrics
struct RallyCacheMetrics {
    let totalEntries: Int
    let totalSize: Int64
    let hitRate: Double
    let averageExportTime: TimeInterval
    let backgroundExportCount: Int
    let validationSuccessRate: Double
    let lastCleanupDate: Date?

    /// Get cache size in MB
    var totalSizeMB: Double {
        return Double(totalSize) / (1024 * 1024)
    }
}

/// Background task information for rally exports
struct RallyExportTask {
    let id: UUID
    let videoId: UUID
    let rallyIndex: Int
    let priority: RallyPreloadPriority
    let asset: AVAsset
    let rallySegment: RallySegment
    let creationDate: Date
    let completionHandler: ((Result<URL, Error>) -> Void)?
}

/// Manages caching and preloading of rally segments for optimal playback performance
@Observable
final class RallyCacheManager {

    // MARK: - Properties

    private let videoExporter: VideoExporter
    private let maxCacheSize: Int64 = 500 * 1024 * 1024  // 500MB default
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60  // 7 days
    private let maxEntriesPerVideo: Int = 10  // Limit entries per video

    // Cache storage
    private var cache: [UUID: RallyCacheEntry] = [:]
    private let cacheQueue = DispatchQueue(label: "com.bumpsetcut.rallycache", qos: .utility)

    // Background export queue
    private var exportQueue: [RallyExportTask] = []
    private var activeExports: Set<UUID> = []
    private let exportQueue_queue = DispatchQueue(label: "com.bumpsetcut.rallycache.export", qos: .background)

    // Performance tracking
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0
    private var exportTimes: [TimeInterval] = []
    private var validationSuccesses: Int = 0
    private var validationAttempts: Int = 0
    private var lastCleanupDate: Date?

    // MARK: - Initialization

    init(videoExporter: VideoExporter = VideoExporter()) {
        self.videoExporter = videoExporter
        loadExistingCache()
        schedulePeriodicCleanup()
    }

    // MARK: - Public Interface

    /// Get a cached rally segment if available, otherwise queue for background export
    func getRallySegment(videoId: UUID, rallyIndex: Int, asset: AVAsset, rallySegment: RallySegment, priority: RallyPreloadPriority = .normal) async -> URL? {

        // Check cache first
        if let cachedEntry = getCachedEntry(videoId: videoId, rallyIndex: rallyIndex) {
            if validateCacheEntry(cachedEntry) {
                await updateCacheAccess(entryId: cachedEntry.id)
                cacheHits += 1
                print("📁 Cache hit for rally \(rallyIndex) of video \(videoId)")
                return cachedEntry.url
            } else {
                // Invalid cache entry, remove it
                await removeCacheEntry(cachedEntry.id)
            }
        }

        cacheMisses += 1

        // Check if export is already in progress
        if isExportInProgress(videoId: videoId, rallyIndex: rallyIndex) {
            print("🔄 Export already in progress for rally \(rallyIndex) of video \(videoId)")
            return nil
        }

        // Queue for background export if low priority
        if priority == .low {
            await queueBackgroundExport(videoId: videoId, rallyIndex: rallyIndex, asset: asset, rallySegment: rallySegment, priority: priority)
            return nil
        }

        // Export immediately for high/normal priority
        return await exportRallySegment(videoId: videoId, rallyIndex: rallyIndex, asset: asset, rallySegment: rallySegment, priority: priority)
    }

    /// Preload rally segments for smoother navigation
    func preloadRallySegments(videoId: UUID, currentRallyIndex: Int, rallies: [RallySegment], asset: AVAsset) async {
        print("🚀 Starting preload for video \(videoId), current rally: \(currentRallyIndex)")

        // Preload current rally with high priority
        if currentRallyIndex < rallies.count {
            await getRallySegment(
                videoId: videoId,
                rallyIndex: currentRallyIndex,
                asset: asset,
                rallySegment: rallies[currentRallyIndex],
                priority: .high
            )
        }

        // Preload next 1-2 rallies with normal priority
        for i in 1...2 {
            let nextIndex = currentRallyIndex + i
            if nextIndex < rallies.count {
                await getRallySegment(
                    videoId: videoId,
                    rallyIndex: nextIndex,
                    asset: asset,
                    rallySegment: rallies[nextIndex],
                    priority: .normal
                )
            }
        }

        // Queue future rallies for background export with low priority
        for i in 3..<min(rallies.count, currentRallyIndex + 6) {
            let futureIndex = currentRallyIndex + i
            if futureIndex < rallies.count {
                await queueBackgroundExport(
                    videoId: videoId,
                    rallyIndex: futureIndex,
                    asset: asset,
                    rallySegment: rallies[futureIndex],
                    priority: .low
                )
            }
        }
    }

    /// Get cache performance metrics
    func getMetrics() -> RallyCacheMetrics {
        let totalRequests = cacheHits + cacheMisses
        let hitRate = totalRequests > 0 ? Double(cacheHits) / Double(totalRequests) : 0.0
        let avgExportTime = exportTimes.isEmpty ? 0.0 : exportTimes.reduce(0, +) / Double(exportTimes.count)
        let validationRate = validationAttempts > 0 ? Double(validationSuccesses) / Double(validationAttempts) : 0.0

        let totalSize = cache.values.reduce(0) { $0 + $1.fileSize }

        return RallyCacheMetrics(
            totalEntries: cache.count,
            totalSize: totalSize,
            hitRate: hitRate,
            averageExportTime: avgExportTime,
            backgroundExportCount: exportQueue.count,
            validationSuccessRate: validationRate,
            lastCleanupDate: lastCleanupDate
        )
    }

    /// Clear cache for a specific video
    func clearVideoCache(videoId: UUID) async {
        await cacheQueue.run {
            let entriesToRemove = cache.values.filter { $0.videoId == videoId }
            for entry in entriesToRemove {
                cache.removeValue(forKey: entry.id)
                try? FileManager.default.removeItem(at: entry.url)
            }
            print("🗑️ Cleared cache for video \(videoId): \(entriesToRemove.count) entries removed")
        }
    }

    /// Clear entire cache
    func clearAllCache() async {
        await cacheQueue.run {
            for entry in cache.values {
                try? FileManager.default.removeItem(at: entry.url)
            }
            cache.removeAll()
            exportQueue.removeAll()
            activeExports.removeAll()
            print("🗑️ Cleared entire rally cache")
        }
    }

    // MARK: - Rally Navigation Integration

    /// Integration method for RallyNavigationState preloading
    func integrateWithNavigationState(navigationState: RallyNavigationState, asset: AVAsset) async {
        guard let metadata = navigationState.processingMetadata else { return }

        let videoId = metadata.videoId
        let currentIndex = navigationState.currentRallyIndex
        let rallies = metadata.rallySegments

        // Start preloading for current navigation context
        await preloadRallySegments(
            videoId: videoId,
            currentRallyIndex: currentIndex,
            rallies: rallies,
            asset: asset
        )

        // Update navigation state with preloading progress if needed
        if let nextTarget = navigationState.getNextPreloadTarget(),
           navigationState.shouldPreload(targetIndex: nextTarget) {

            // Check if we have the next rally cached
            if let cachedEntry = getCachedEntry(videoId: videoId, rallyIndex: nextTarget),
               validateCacheEntry(cachedEntry) {

                await MainActor.run {
                    navigationState.triggerPreloading(for: nextTarget)
                    navigationState.updatePreloadingProgress(1.0)
                    navigationState.completePreloading(success: true)
                }
                print("🎯 Rally \(nextTarget) already cached and ready for navigation")
            }
        }
    }

    /// Get preloaded rally URL for immediate playback
    func getPreloadedRallyURL(videoId: UUID, rallyIndex: Int) -> URL? {
        if let cachedEntry = getCachedEntry(videoId: videoId, rallyIndex: rallyIndex),
           validateCacheEntry(cachedEntry) {
            cacheHits += 1
            Task {
                await updateCacheAccess(entryId: cachedEntry.id)
            }
            return cachedEntry.url
        }
        return nil
    }

    // MARK: - Private Methods

    private func getCachedEntry(videoId: UUID, rallyIndex: Int) -> RallyCacheEntry? {
        return cache.values.first { $0.videoId == videoId && $0.rallyIndex == rallyIndex }
    }

    private func isExportInProgress(videoId: UUID, rallyIndex: Int) -> Bool {
        return exportQueue.contains { $0.videoId == videoId && $0.rallyIndex == rallyIndex } ||
               activeExports.contains { exportId in
                   exportQueue.first { $0.id == exportId }?.videoId == videoId &&
                   exportQueue.first { $0.id == exportId }?.rallyIndex == rallyIndex
               }
    }

    private func exportRallySegment(videoId: UUID, rallyIndex: Int, asset: AVAsset, rallySegment: RallySegment, priority: RallyPreloadPriority) async -> URL? {
        let startTime = Date()

        do {
            print("🎬 Exporting rally \(rallyIndex) for video \(videoId) with \(priority.description) priority")

            // Generate cache key and URL
            let cacheKey = videoExporter.generateRallyCacheKey(asset: asset, rallyIndex: rallyIndex, rallySegment: rallySegment)
            let outputURL = videoExporter.getCachedRallyURL(cacheKey: cacheKey)

            // Check if already cached
            if videoExporter.isRallyCached(cacheKey: cacheKey) {
                print("📁 Rally already cached: \(outputURL.lastPathComponent)")

                // Create cache entry for existing file
                let fileSize = getFileSize(url: outputURL)
                let entry = RallyCacheEntry(
                    id: UUID(),
                    videoId: videoId,
                    rallyIndex: rallyIndex,
                    url: outputURL,
                    creationDate: Date(),
                    lastAccessDate: Date(),
                    fileSize: fileSize,
                    priority: priority,
                    isValidated: true
                )

                await addCacheEntry(entry)
                return outputURL
            }

            // Export to cache URL
            let url = try await videoExporter.exportRallySegmentToURL(
                asset: asset,
                rallySegment: rallySegment,
                outputURL: outputURL
            )

            // Create cache entry
            let fileSize = getFileSize(url: url)
            let entry = RallyCacheEntry(
                id: UUID(),
                videoId: videoId,
                rallyIndex: rallyIndex,
                url: url,
                creationDate: Date(),
                lastAccessDate: Date(),
                fileSize: fileSize,
                priority: priority,
                isValidated: true
            )

            await addCacheEntry(entry)

            let exportTime = Date().timeIntervalSince(startTime)
            exportTimes.append(exportTime)

            print("✅ Successfully exported rally \(rallyIndex) in \(String(format: "%.2f", exportTime))s")
            return url

        } catch {
            print("❌ Failed to export rally \(rallyIndex): \(error)")
            return nil
        }
    }

    private func queueBackgroundExport(videoId: UUID, rallyIndex: Int, asset: AVAsset, rallySegment: RallySegment, priority: RallyPreloadPriority) async {
        let task = RallyExportTask(
            id: UUID(),
            videoId: videoId,
            rallyIndex: rallyIndex,
            priority: priority,
            asset: asset,
            rallySegment: rallySegment,
            creationDate: Date(),
            completionHandler: nil
        )

        await exportQueue_queue.run {
            // Insert based on priority (high priority first)
            let insertIndex = exportQueue.firstIndex { $0.priority.rawValue > priority.rawValue } ?? exportQueue.count
            exportQueue.insert(task, at: insertIndex)
        }

        print("📋 Queued background export for rally \(rallyIndex) with \(priority.description) priority")
        processNextExportTask()
    }

    private func processNextExportTask() {
        Task {
            await exportQueue_queue.run {
                guard !exportQueue.isEmpty,
                      activeExports.count < 2,  // Limit concurrent exports
                      let nextTask = exportQueue.first else { return }

                exportQueue.removeFirst()
                activeExports.insert(nextTask.id)

                Task {
                    let url = await exportRallySegment(
                        videoId: nextTask.videoId,
                        rallyIndex: nextTask.rallyIndex,
                        asset: nextTask.asset,
                        rallySegment: nextTask.rallySegment,
                        priority: nextTask.priority
                    )

                    await exportQueue_queue.run {
                        activeExports.remove(nextTask.id)
                    }

                    nextTask.completionHandler?(url != nil ? .success(url!) : .failure(ProcessingError.exportFailed))

                    // Process next task if available
                    processNextExportTask()
                }
            }
        }
    }

    private func validateCacheEntry(_ entry: RallyCacheEntry) -> Bool {
        validationAttempts += 1

        // Check if file exists
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            print("⚠️ Cache validation failed: File missing for rally \(entry.rallyIndex)")
            return false
        }

        // Check if file size matches
        let currentSize = getFileSize(url: entry.url)
        guard currentSize == entry.fileSize else {
            print("⚠️ Cache validation failed: File size mismatch for rally \(entry.rallyIndex)")
            return false
        }

        // Check if file is too old
        let age = Date().timeIntervalSince(entry.creationDate)
        guard age < maxCacheAge else {
            print("⚠️ Cache validation failed: File too old for rally \(entry.rallyIndex)")
            return false
        }

        validationSuccesses += 1
        return true
    }

    private func getFileSize(url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }

    @MainActor
    private func addCacheEntry(_ entry: RallyCacheEntry) async {
        await cacheQueue.run {
            cache[entry.id] = entry
        }

        // Trigger cleanup if needed
        await performCacheCleanup()
    }

    @MainActor
    private func removeCacheEntry(_ entryId: UUID) async {
        await cacheQueue.run {
            if let entry = cache.removeValue(forKey: entryId) {
                try? FileManager.default.removeItem(at: entry.url)
                print("🗑️ Removed invalid cache entry for rally \(entry.rallyIndex)")
            }
        }
    }

    @MainActor
    private func updateCacheAccess(entryId: UUID) async {
        await cacheQueue.run {
            if let entry = cache[entryId] {
                cache[entryId] = entry.accessed()
            }
        }
    }

    private func loadExistingCache() {
        // Load existing rally files and populate cache
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: []
            )

            let rallyFiles = files.filter { $0.lastPathComponent.hasPrefix("rally_") }

            for file in rallyFiles {
                if let entry = createCacheEntryFromFile(url: file) {
                    cache[entry.id] = entry
                }
            }

            print("📁 Loaded \(cache.count) existing rally cache entries")

        } catch {
            print("⚠️ Failed to load existing cache: \(error)")
        }
    }

    private func createCacheEntryFromFile(url: URL) -> RallyCacheEntry? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let creationDate = attributes[.creationDate] as? Date,
                  let fileSize = attributes[.size] as? Int64 else {
                return nil
            }

            // Parse filename to extract video and rally info
            // Format: rally_{sourceHash}_{rallyIndex}_{timeHash}.mp4
            let filename = url.lastPathComponent
            let components = filename.replacingOccurrences(of: ".mp4", with: "").components(separatedBy: "_")
            guard components.count >= 3,
                  let rallyIndex = Int(components[2]) else {
                return nil
            }

            // Generate a deterministic video ID from the source hash (this is a simplification)
            let videoId = UUID() // In a real implementation, you'd map this properly

            return RallyCacheEntry(
                id: UUID(),
                videoId: videoId,
                rallyIndex: rallyIndex,
                url: url,
                creationDate: creationDate,
                lastAccessDate: creationDate,
                fileSize: fileSize,
                priority: .normal,
                isValidated: false  // Will be validated on first access
            )

        } catch {
            print("⚠️ Failed to create cache entry for file \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func performCacheCleanup() async {
        let currentSize = cache.values.reduce(0) { $0 + $1.fileSize }

        // Only cleanup if we exceed size limit
        guard currentSize > maxCacheSize else { return }

        await cacheQueue.run {
            print("🧹 Starting cache cleanup - current size: \(currentSize / (1024 * 1024))MB")

            // Sort by priority (low first) and then by last access date (oldest first)
            let sortedEntries = cache.values.sorted { entry1, entry2 in
                if entry1.priority != entry2.priority {
                    return entry1.priority.rawValue > entry2.priority.rawValue
                }
                return entry1.lastAccessDate < entry2.lastAccessDate
            }

            var removedSize: Int64 = 0
            let targetRemovalSize = currentSize - (maxCacheSize * 3 / 4)  // Remove to 75% of max

            for entry in sortedEntries {
                if removedSize >= targetRemovalSize { break }

                cache.removeValue(forKey: entry.id)
                try? FileManager.default.removeItem(at: entry.url)
                removedSize += entry.fileSize

                print("🗑️ Removed cache entry for rally \(entry.rallyIndex): \(entry.fileSize / (1024 * 1024))MB")
            }

            lastCleanupDate = Date()
            print("✅ Cache cleanup completed - removed \(removedSize / (1024 * 1024))MB")
        }
    }

    private func schedulePeriodicCleanup() {
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in  // Every hour
            Task {
                await self.performCacheCleanup()
            }
        }
    }
}

// MARK: - Extensions

extension DispatchQueue {
    func run<T>(@Sendable operation: @escaping () async -> T) async -> T {
        return await withUnsafeContinuation { continuation in
            self.async {
                Task {
                    let result = await operation()
                    continuation.resume(returning: result)
                }
            }
        }
    }
}