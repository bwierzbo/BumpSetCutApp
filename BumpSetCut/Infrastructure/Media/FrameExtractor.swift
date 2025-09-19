//
//  FrameExtractor.swift
//  BumpSetCut
//
//  Created by Infrastructure Layer on 9/17/25.
//

import Foundation
import AVFoundation
import CoreGraphics
import UIKit
import os.log

/// Infrastructure layer service for extracting video frames with LRU caching
/// Isolates AVFoundation frame extraction from the domain layer
/// Enhanced with performance monitoring, memory pressure detection, and graceful degradation
@MainActor
final class FrameExtractor {

    /// Shared instance for app-wide frame extraction
    static let shared = FrameExtractor()

    /// Performance telemetry tracking with enhanced prefetch metrics
    private struct PerformanceTelemetry {
        var totalExtractions: Int = 0
        var totalExtractionTime: TimeInterval = 0
        var cacheHits: Int = 0
        var memoryPressureEvents: Int = 0
        var timeoutEvents: Int = 0
        var errorEvents: Int = 0

        // Enhanced prefetch tracking
        var immediatePrefetches: Int = 0
        var extendedPrefetches: Int = 0
        var prefetchSkippedMemory: Int = 0
        var prefetchSkippedCache: Int = 0
        var prefetchErrors: Int = 0

        var averageExtractionTime: TimeInterval {
            guard totalExtractions > 0 else { return 0 }
            return totalExtractionTime / Double(totalExtractions)
        }

        var cacheHitRate: Double {
            guard totalExtractions > 0 else { return 0 }
            return Double(cacheHits) / Double(totalExtractions)
        }

        var prefetchSuccessRate: Double {
            let totalPrefetchAttempts = immediatePrefetches + extendedPrefetches + prefetchErrors
            guard totalPrefetchAttempts > 0 else { return 0 }
            return Double(immediatePrefetches + extendedPrefetches) / Double(totalPrefetchAttempts)
        }
    }

    /// Memory pressure monitoring
    private struct MemoryPressureMonitor {
        var currentMemoryPressure: DispatchSource.MemoryPressureEvent = []
        var isUnderMemoryPressure: Bool = false
        var lastPressureDetected: Date?
        var gracefulDegradationActive: Bool = false
    }

    /// Prefetch queue management for background processing
    private struct PrefetchQueueManager {
        private var immediatePrefetchQueue: [(URL, CMTime)] = []
        private var extendedPrefetchQueue: [(URL, CMTime)] = []
        private let maxQueueSize: Int = 20
        private let maxExtendedQueueSize: Int = 50

        mutating func addImmediatePrefetch(videoURL: URL, timestamp: CMTime) {
            guard immediatePrefetchQueue.count < maxQueueSize else { return }
            immediatePrefetchQueue.append((videoURL, timestamp))
        }

        mutating func addExtendedPrefetch(videoURL: URL, timestamp: CMTime) {
            guard extendedPrefetchQueue.count < maxExtendedQueueSize else { return }
            extendedPrefetchQueue.append((videoURL, timestamp))
        }

        mutating func getNextImmediatePrefetch() -> (URL, CMTime)? {
            guard !immediatePrefetchQueue.isEmpty else { return nil }
            return immediatePrefetchQueue.removeFirst()
        }

        mutating func getNextExtendedPrefetch() -> (URL, CMTime)? {
            guard !extendedPrefetchQueue.isEmpty else { return nil }
            return extendedPrefetchQueue.removeFirst()
        }

        mutating func clearQueues() {
            immediatePrefetchQueue.removeAll()
            extendedPrefetchQueue.removeAll()
        }

        var queueSizes: (immediate: Int, extended: Int) {
            return (immediatePrefetchQueue.count, extendedPrefetchQueue.count)
        }

        var hasWork: Bool {
            return !immediatePrefetchQueue.isEmpty || !extendedPrefetchQueue.isEmpty
        }
    }

    /// Configuration for frame extraction
    struct ExtractionConfig {
        let frameTime: CMTime
        let maximumSize: CGSize
        let appliesPreferredTrackTransform: Bool
        let extractionTimeout: TimeInterval

        static let defaultConfig = ExtractionConfig(
            frameTime: CMTime(seconds: 0.1, preferredTimescale: 600),
            maximumSize: CGSize(width: 640, height: 640),
            appliesPreferredTrackTransform: true,
            extractionTimeout: 0.1 // 100ms
        )
    }

    /// Cache entry containing the extracted frame and metadata
    private struct CacheEntry {
        let image: UIImage
        let extractedAt: Date
        let memoryUsage: Int
    }

    /// LRU cache implementation with automatic eviction
    private final class FrameCache {
        private var cache: [URL: CacheEntry] = [:]
        private var accessOrder: [URL] = []
        private let maxEntries: Int
        private let maxMemoryBytes: Int

        private var currentMemoryUsage: Int = 0

        init(maxEntries: Int = 5, maxMemoryMB: Int = 10) {
            self.maxEntries = maxEntries
            self.maxMemoryBytes = maxMemoryMB * 1024 * 1024
        }

        func get(_ key: URL) -> UIImage? {
            guard let entry = cache[key] else { return nil }

            // Move to front of access order
            moveToFront(key)
            return entry.image
        }

        func set(_ key: URL, image: UIImage) {
            let memoryUsage = estimateMemoryUsage(for: image)
            let entry = CacheEntry(
                image: image,
                extractedAt: Date(),
                memoryUsage: memoryUsage
            )

            // Remove existing entry if present
            if let existingEntry = cache[key] {
                currentMemoryUsage -= existingEntry.memoryUsage
            } else {
                accessOrder.append(key)
            }

            cache[key] = entry
            currentMemoryUsage += memoryUsage
            moveToFront(key)

            // Evict entries if necessary
            evictIfNecessary()
        }

        func clear() {
            cache.removeAll()
            accessOrder.removeAll()
            currentMemoryUsage = 0
        }

        func clearAll() {
            clear()
        }

        func clearOldest(ratio: Double) {
            let countToRemove = Int(Double(cache.count) * ratio)
            for _ in 0..<countToRemove {
                evictLeastRecentlyUsed()
            }
        }

        func reduceCapacity() {
            // Temporarily reduce cache capacity under memory pressure
            while cache.count > 2 {
                evictLeastRecentlyUsed()
            }
        }

        func restoreCapacity() {
            // Capacity is controlled by maxEntries, no action needed
        }

        private func moveToFront(_ key: URL) {
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
            }
            accessOrder.insert(key, at: 0)
        }

        private func evictIfNecessary() {
            // Evict by count
            while cache.count > maxEntries {
                evictLeastRecentlyUsed()
            }

            // Evict by memory usage
            while currentMemoryUsage > maxMemoryBytes {
                evictLeastRecentlyUsed()
            }
        }

        private func evictLeastRecentlyUsed() {
            guard let lruKey = accessOrder.last else { return }

            if let entry = cache.removeValue(forKey: lruKey) {
                currentMemoryUsage -= entry.memoryUsage
            }
            accessOrder.removeLast()
        }

        private func estimateMemoryUsage(for image: UIImage) -> Int {
            let size = image.size
            let scale = image.scale
            let pixelCount = Int(size.width * scale * size.height * scale)
            return pixelCount * 4 // 4 bytes per pixel (RGBA)
        }

        var debugDescription: String {
            return "FrameCache(entries: \(cache.count)/\(maxEntries), memory: \(currentMemoryUsage/1024/1024)MB/\(maxMemoryBytes/1024/1024)MB)"
        }
    }

    private let cache = FrameCache()
    private let config: ExtractionConfig
    private let extractionQueue = DispatchQueue(label: "com.bumpsetcut.frameextractor", qos: .userInitiated, attributes: .concurrent)
    private let highPriorityQueue = DispatchQueue(label: "com.bumpsetcut.frameextractor.priority", qos: .userInteractive)
    private let prefetchQueue = DispatchQueue(label: "com.bumpsetcut.frameextractor.prefetch", qos: .utility, attributes: .concurrent)
    private var telemetry = PerformanceTelemetry()
    private var memoryMonitor = MemoryPressureMonitor()
    private var prefetchQueueManager = PrefetchQueueManager()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let logger = Logger(subsystem: "com.bumpsetcut", category: "FrameExtractor")

    // Background prefetch processing
    private var prefetchTimer: Timer?

    init(config: ExtractionConfig = .defaultConfig) {
        self.config = config
        setupEnhancedMemoryPressureMonitoring()
        setupApplicationLifecycleObservers()
        startBackgroundPrefetchProcessing()
    }

    /// Extract a frame from the video at a specific timestamp
    /// Enhanced with performance monitoring, memory pressure detection, and graceful degradation
    func extractFrame(from videoURL: URL, at timestamp: CMTime, priority: ExtractionPriority = .normal) async throws -> UIImage {
        let extractionStartTime = Date()

        // Update telemetry
        var currentTelemetry = telemetry
        currentTelemetry.totalExtractions += 1

        // Check for memory pressure and degrade gracefully if needed
        if memoryMonitor.isUnderMemoryPressure {
            logger.warning("⚠️ Memory pressure detected during frame extraction")

            // Clear cache to free memory
            cache.clear()
            memoryMonitor.gracefulDegradationActive = true

            // If under severe memory pressure, throw early
            if memoryMonitor.currentMemoryPressure.contains(.critical) {
                currentTelemetry.errorEvents += 1
                throw FrameExtractionError.memoryPressure
            }
        }

        // Create cache key with timestamp for more specific caching
        let timestampKey = URL(string: "\(videoURL.absoluteString)_\(timestamp.seconds)")!

        // Check cache first
        if let cachedImage = cache.get(timestampKey) {
            currentTelemetry.cacheHits += 1
            logger.debug("✅ Cache hit for frame extraction: \(videoURL.lastPathComponent) at \(timestamp.seconds)s")
            return cachedImage
        }

        // Choose appropriate queue based on priority and memory pressure
        let selectedQueue = determineExtractionQueue(priority: priority)

        // Extract frame on background queue with enhanced error handling
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            selectedQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: FrameExtractionError.extractorReleased)
                    return
                }

                // Use a flag to prevent multiple continuation resumes
                var hasResumed = false
                let resumeLock = NSLock()

                func safeResume(with result: Result<UIImage, Error>) {
                    resumeLock.lock()
                    defer { resumeLock.unlock() }

                    guard !hasResumed else { return }
                    hasResumed = true

                    switch result {
                    case .success(let image):
                        continuation.resume(returning: image)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                let asset = AVURLAsset(url: videoURL)
                let imageGenerator = AVAssetImageGenerator(asset: asset)

                // Configure image generator
                let maxSize = self.config.maximumSize

                imageGenerator.maximumSize = maxSize
                imageGenerator.appliesPreferredTrackTransform = self.config.appliesPreferredTrackTransform
                imageGenerator.requestedTimeToleranceBefore = .zero
                imageGenerator.requestedTimeToleranceAfter = .zero

                // Adjust timeout based on priority
                let timeout = priority == .high ? self.config.extractionTimeout * 2 : self.config.extractionTimeout

                // Create timeout mechanism
                let timeoutTask = DispatchWorkItem {
                    imageGenerator.cancelAllCGImageGeneration()
                    Task { @MainActor in
                        var updatedTelemetry = self.telemetry
                        updatedTelemetry.timeoutEvents += 1
                        self.logger.error("⏰ Frame extraction timeout for: \(videoURL.lastPathComponent)")
                    }
                    safeResume(with: .failure(FrameExtractionError.timeoutExceeded))
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)

                // Extract frame
                let requestedTime = timestamp
                imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { (requestedTime, cgImage, actualTime, result, error) in
                    timeoutTask.cancel()

                    if let error = error {
                        Task { @MainActor in
                            var updatedTelemetry = self.telemetry
                            updatedTelemetry.errorEvents += 1
                            self.logger.error("❌ AVFoundation error: \(error.localizedDescription)")
                        }
                        safeResume(with: .failure(FrameExtractionError.avFoundationError(error)))
                        return
                    }

                    guard result == .succeeded, let cgImage = cgImage else {
                        Task { @MainActor in
                            var updatedTelemetry = self.telemetry
                            updatedTelemetry.errorEvents += 1
                            self.logger.error("❌ Image generation failed for: \(videoURL.lastPathComponent)")
                        }
                        safeResume(with: .failure(FrameExtractionError.imageGenerationFailed))
                        return
                    }

                    let uiImage = UIImage(cgImage: cgImage)
                    safeResume(with: .success(uiImage))
                }
            }
        }

        // Update telemetry with timing
        let extractionTime = Date().timeIntervalSince(extractionStartTime)
        currentTelemetry.totalExtractionTime += extractionTime

        logger.debug("⏱️ Frame extraction completed in \(Int(extractionTime * 1000))ms for: \(videoURL.lastPathComponent) at \(timestamp.seconds)s")

        // Cache the extracted image if not under severe memory pressure
        if !memoryMonitor.currentMemoryPressure.contains(.critical) {
            await MainActor.run {
                cache.set(timestampKey, image: image)
            }
        }

        // Reset graceful degradation if extraction succeeded and memory pressure is normal
        if !memoryMonitor.isUnderMemoryPressure {
            memoryMonitor.gracefulDegradationActive = false
        }

        return image
    }

    /// Extract a frame from the video at the configured time (0.1 seconds)
    /// Enhanced with performance monitoring, memory pressure detection, and graceful degradation
    func extractFrame(from videoURL: URL, priority: ExtractionPriority = .normal) async throws -> UIImage {
        return try await extractFrame(from: videoURL, at: config.frameTime, priority: priority)
    }

    /// Batch prefetch frames for extended lookahead (positions 4-6 ahead)
    /// Uses optimized background processing and respects memory constraints
    func prefetchFramesExtended(videoURLs: [(URL, CMTime)], priority: ExtractionPriority = .low) {
        guard !memoryMonitor.isUnderMemoryPressure else {
            telemetry.prefetchSkippedMemory += videoURLs.count
            logger.warning("⚠️ Skipping extended prefetching due to memory pressure")
            return
        }

        logger.debug("🔮 Queuing \(videoURLs.count) frames for extended prefetch (positions 4-6 ahead)")

        // Add to queue for background processing
        for (videoURL, timestamp) in videoURLs {
            // Check if frame is already cached before queuing
            let timestampKey = URL(string: "\(videoURL.absoluteString)_\(timestamp.seconds)")!
            if cache.get(timestampKey) != nil {
                telemetry.prefetchSkippedCache += 1
                logger.debug("⚡ Extended prefetch skipped (already cached): \(videoURL.lastPathComponent) at \(timestamp.seconds)s")
                continue
            }

            prefetchQueueManager.addExtendedPrefetch(videoURL: videoURL, timestamp: timestamp)
        }

        logger.debug("📊 Extended prefetch queue size: \(prefetchQueueManager.queueSizes.extended)")
    }

    /// Enhanced prefetch for immediate upcoming frames (positions 1-3 ahead)
    /// Higher priority than extended prefetching
    func prefetchFramesImmediate(videoURLs: [(URL, CMTime)]) {
        guard !memoryMonitor.currentMemoryPressure.contains(.critical) else {
            telemetry.prefetchSkippedMemory += videoURLs.count
            logger.warning("⚠️ Skipping immediate prefetching due to critical memory pressure")
            return
        }

        logger.debug("⚡ Queuing \(videoURLs.count) frames for immediate prefetch (positions 1-3 ahead)")

        // Add to immediate prefetch queue for priority processing
        for (videoURL, timestamp) in videoURLs {
            // Check if frame is already cached before queuing
            let timestampKey = URL(string: "\(videoURL.absoluteString)_\(timestamp.seconds)")!
            if cache.get(timestampKey) != nil {
                telemetry.prefetchSkippedCache += 1
                logger.debug("⚡ Immediate prefetch skipped (already cached): \(videoURL.lastPathComponent) at \(timestamp.seconds)s")
                continue
            }

            prefetchQueueManager.addImmediatePrefetch(videoURL: videoURL, timestamp: timestamp)
        }

        logger.debug("📊 Immediate prefetch queue size: \(prefetchQueueManager.queueSizes.immediate)")
    }

    /// Check if a frame is already cached at a specific timestamp
    func isFrameCached(videoURL: URL, at timestamp: CMTime) -> Bool {
        let timestampKey = URL(string: "\(videoURL.absoluteString)_\(timestamp.seconds)")!
        return cache.get(timestampKey) != nil
    }

    /// Get current prefetch performance metrics
    var prefetchMetrics: (queuedExtractions: Int, completedPrefetches: Int, memoryPressureSkips: Int, successRate: Double) {
        let queueSizes = prefetchQueueManager.queueSizes
        return (
            queuedExtractions: queueSizes.immediate + queueSizes.extended,
            completedPrefetches: telemetry.immediatePrefetches + telemetry.extendedPrefetches,
            memoryPressureSkips: telemetry.prefetchSkippedMemory,
            successRate: telemetry.prefetchSuccessRate
        )
    }

    /// Clear all cached frames
    func clearCache() {
        cache.clear()
        logger.debug("🗑️ Cache cleared manually")
    }

    /// Get current cache status for debugging
    var cacheStatus: String {
        return cache.debugDescription
    }

    /// Get performance telemetry for monitoring
    var performanceMetrics: (averageTime: TimeInterval, cacheHitRate: Double, memoryPressureEvents: Int, errorRate: Double) {
        let errorRate = telemetry.totalExtractions > 0 ? Double(telemetry.errorEvents) / Double(telemetry.totalExtractions) : 0
        return (
            averageTime: telemetry.averageExtractionTime,
            cacheHitRate: telemetry.cacheHitRate,
            memoryPressureEvents: telemetry.memoryPressureEvents,
            errorRate: errorRate
        )
    }

    /// Check if system is under memory pressure
    var isUnderMemoryPressure: Bool {
        return memoryMonitor.isUnderMemoryPressure
    }

    /// Enable graceful degradation mode
    func enableGracefulDegradation() {
        memoryMonitor.gracefulDegradationActive = true
        cache.reduceCapacity()
        logger.warning("🔻 Graceful degradation enabled")
    }

    /// Disable graceful degradation mode
    func disableGracefulDegradation() {
        memoryMonitor.gracefulDegradationActive = false
        cache.restoreCapacity()
        logger.info("🔺 Graceful degradation disabled")
    }

    // MARK: - Background Prefetch Processing

    private func startBackgroundPrefetchProcessing() {
        prefetchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processBackgroundPrefetchQueue()
            }
        }
    }

    private func processBackgroundPrefetchQueue() {
        guard prefetchQueueManager.hasWork && !memoryMonitor.isUnderMemoryPressure else {
            return
        }

        // Process immediate prefetches first (higher priority)
        if let (videoURL, timestamp) = prefetchQueueManager.getNextImmediatePrefetch() {
            processImmediatePrefetch(videoURL: videoURL, timestamp: timestamp)
        }
        // Then process extended prefetches
        else if let (videoURL, timestamp) = prefetchQueueManager.getNextExtendedPrefetch() {
            processExtendedPrefetch(videoURL: videoURL, timestamp: timestamp)
        }
    }

    private func processImmediatePrefetch(videoURL: URL, timestamp: CMTime) {
        Task {
            do {
                let _ = try await extractFrame(from: videoURL, at: timestamp, priority: .normal)
                telemetry.immediatePrefetches += 1
                logger.debug("🎯 Immediate prefetch completed: \(videoURL.lastPathComponent) at \(timestamp.seconds)s")
            } catch {
                telemetry.prefetchErrors += 1
                logger.warning("⚠️ Immediate prefetch failed for \(videoURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func processExtendedPrefetch(videoURL: URL, timestamp: CMTime) {
        prefetchQueue.async { [weak self] in
            guard let self = self else { return }

            Task {
                do {
                    let _ = try await self.extractFrame(from: videoURL, at: timestamp, priority: .low)
                    await MainActor.run {
                        self.telemetry.extendedPrefetches += 1
                    }
                    self.logger.debug("🎯 Extended prefetch completed: \(videoURL.lastPathComponent) at \(timestamp.seconds)s")
                } catch {
                    await MainActor.run {
                        self.telemetry.prefetchErrors += 1
                    }
                    self.logger.warning("⚠️ Extended prefetch failed for \(videoURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Performance Helper Methods

    private func determineExtractionQueue(priority: ExtractionPriority) -> DispatchQueue {
        switch priority {
        case .high:
            return highPriorityQueue
        case .normal:
            return memoryMonitor.gracefulDegradationActive ? DispatchQueue.global(qos: .utility) : extractionQueue
        case .low:
            return DispatchQueue.global(qos: .utility)
        }
    }

    // MARK: - Enhanced Memory Pressure Monitoring

    private func setupEnhancedMemoryPressureMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self else { return }

            let event = self.memoryPressureSource?.mask ?? []
            self.handleMemoryPressure(event: event)
        }

        memoryPressureSource?.resume()
    }

    private func handleMemoryPressure(event: DispatchSource.MemoryPressureEvent) {
        memoryMonitor.currentMemoryPressure = event
        memoryMonitor.isUnderMemoryPressure = true
        memoryMonitor.lastPressureDetected = Date()

        telemetry.memoryPressureEvents += 1

        if event.contains(.critical) {
            logger.error("🎆 Critical memory pressure - immediate cache clearing and prefetch queue clearing")
            cache.clearAll()
            prefetchQueueManager.clearQueues()
            memoryMonitor.gracefulDegradationActive = true
        } else if event.contains(.warning) {
            logger.warning("🟠 Memory pressure warning - moderate cache reduction and extended prefetch queue clearing")
            cache.clearOldest(ratio: 0.3)
            // Clear only extended prefetch queue, keep immediate prefetches
            while prefetchQueueManager.queueSizes.extended > 0 {
                _ = prefetchQueueManager.getNextExtendedPrefetch()
            }
        }

        // Schedule memory pressure reset check
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.checkMemoryPressureRecovery()
        }
    }

    private func checkMemoryPressureRecovery() {
        // Reset memory pressure flag after delay if no new pressure events
        if let lastPressure = memoryMonitor.lastPressureDetected,
           Date().timeIntervalSince(lastPressure) > 5.0 {
            memoryMonitor.isUnderMemoryPressure = false
            memoryMonitor.currentMemoryPressure = []

            // Gradually disable graceful degradation if memory stabilizes
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                if let self = self, !self.memoryMonitor.isUnderMemoryPressure {
                    self.memoryMonitor.gracefulDegradationActive = false
                    self.logger.info("🔄 Memory pressure recovered - normal operation resumed")
                }
            }
        }
    }

    // MARK: - Application Lifecycle Monitoring

    private func setupApplicationLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleApplicationMemoryWarning()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleApplicationDidEnterBackground()
            }
        }
    }

    private func handleApplicationMemoryWarning() {
        logger.warning("🚨 Application memory warning received")
        cache.clearOldest(ratio: 0.8)
        memoryMonitor.gracefulDegradationActive = true
    }

    private func handleApplicationDidEnterBackground() {
        logger.debug("🌃 Application entering background - clearing cache")
        cache.clear()
    }

    deinit {
        memoryPressureSource?.cancel()
        prefetchTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

/// Extraction priority for queue selection and timeout adjustment
enum ExtractionPriority {
    case high    // User-interactive (current peek frame)
    case normal  // Standard extraction
    case low     // Background prefetching
}

/// Frame extraction specific errors
enum FrameExtractionError: LocalizedError {
    case invalidVideoURL
    case avFoundationError(Error)
    case imageGenerationFailed
    case timeoutExceeded
    case extractorReleased
    case memoryPressure

    var errorDescription: String? {
        switch self {
        case .invalidVideoURL:
            return "Invalid video URL provided for frame extraction"
        case .avFoundationError(let error):
            return "AVFoundation error during frame extraction: \(error.localizedDescription)"
        case .imageGenerationFailed:
            return "Failed to generate image from video frame"
        case .timeoutExceeded:
            return "Frame extraction timed out (exceeded 100ms limit)"
        case .extractorReleased:
            return "Frame extractor was released during extraction"
        case .memoryPressure:
            return "Frame extraction cancelled due to memory pressure"
        }
    }
}