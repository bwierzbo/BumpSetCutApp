//
//  RallyNavigationState.swift
//  BumpSetCut
//
//  Created for Rally Swiping Fixes Epic - Issue #48
//  Unified state management for rally navigation across player components
//

import Foundation
import SwiftUI
import AVFoundation

final class RallyNavigationState: ObservableObject {
    // MARK: - Core Rally State
    @Published var currentRallyIndex: Int = 0
    @Published var processingMetadata: ProcessingMetadata?
    @Published var isLoading: Bool = true
    @Published var hasError: Bool = false
    @Published var errorMessage: String = ""

    // MARK: - Video Buffering State
    @Published var isVideoBuffering: Bool = false
    @Published var playersReady: Bool = false
    @Published var videoLoadingProgress: Double = 0.0
    @Published var bufferingTimeout: Bool = false

    // MARK: - Gesture State
    @Published var dragOffset: CGSize = .zero
    @Published var isDragging: Bool = false
    @Published var bounceOffset: CGFloat = 0.0

    // MARK: - Transition State
    @Published var isTransitioning: Bool = false
    @Published var transitionOpacity: Double = 1.0
    @Published var showFlash: Bool = false

    // MARK: - Gesture Configuration (Unified)
    private let navigationThreshold: CGFloat = 100 // Consistent across both players
    private let resistanceThreshold: CGFloat = 100
    private let baseResistance: CGFloat = 0.3

    // MARK: - Dependencies
    private let videoMetadata: VideoMetadata
    internal var metadataStore: MetadataStore?

    // MARK: - Navigation Properties
    var canGoNext: Bool {
        guard let metadata = processingMetadata else { return false }
        return currentRallyIndex < metadata.rallySegments.count - 1
    }

    var canGoPrevious: Bool {
        return currentRallyIndex > 0
    }

    var totalRallies: Int {
        return processingMetadata?.rallySegments.count ?? 0
    }

    // MARK: - Current Rally
    var currentRally: RallySegment? {
        guard let metadata = processingMetadata,
              currentRallyIndex >= 0 && currentRallyIndex < metadata.rallySegments.count else {
            return nil
        }
        return metadata.rallySegments[currentRallyIndex]
    }

    // MARK: - Initialization
    init(videoMetadata: VideoMetadata, metadataStore: MetadataStore? = nil) {
        self.videoMetadata = videoMetadata
        self.metadataStore = metadataStore
    }

    // MARK: - Lifecycle Management
    @MainActor
    func initialize() async {
        isLoading = true
        hasError = false

        // Create MetadataStore if not provided
        if metadataStore == nil {
            metadataStore = MetadataStore()
        }

        do {
            let metadata = try metadataStore!.loadMetadata(for: videoMetadata.id)

            guard !metadata.rallySegments.isEmpty else {
                throw RallyNavigationError.noRalliesFound
            }

            processingMetadata = metadata
            currentRallyIndex = 0

        } catch {
            hasError = true
            errorMessage = "Failed to load rally data: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Unified Gesture Handling
    func updateDragOffset(_ offset: CGSize, isPortrait: Bool) {
        isDragging = true

        if isPortrait {
            let resistanceFactor = calculateResistance(for: offset.height, axis: .vertical)
            dragOffset = CGSize(width: 0, height: offset.height * resistanceFactor)
        } else {
            let resistanceFactor = calculateResistance(for: offset.width, axis: .horizontal)
            dragOffset = CGSize(width: offset.width * resistanceFactor, height: 0)
        }
    }

    func endDrag(translation: CGSize, isPortrait: Bool) {
        isDragging = false
        dragOffset = .zero

        handleNavigation(translation: translation, isPortrait: isPortrait)
    }

    private func calculateResistance(for translation: CGFloat, axis: GestureAxis) -> CGFloat {
        switch axis {
        case .vertical:
            if translation < 0 && !canGoNext {
                return max(0.1, baseResistance * (1 - abs(translation) / resistanceThreshold))
            } else if translation > 0 && !canGoPrevious {
                return max(0.1, baseResistance * (1 - abs(translation) / resistanceThreshold))
            }
        case .horizontal:
            if translation < 0 && !canGoNext {
                return max(0.1, baseResistance * (1 - abs(translation) / resistanceThreshold))
            } else if translation > 0 && !canGoPrevious {
                return max(0.1, baseResistance * (1 - abs(translation) / resistanceThreshold))
            }
        }

        return 1.0
    }

    private func handleNavigation(translation: CGSize, isPortrait: Bool) {
        Task { @MainActor in
            if isPortrait {
                if translation.height < -navigationThreshold && canGoNext {
                    navigateToNext()
                } else if translation.height > navigationThreshold && canGoPrevious {
                    navigateToPrevious()
                } else {
                    triggerBounceEffect(translation: translation, isPortrait: isPortrait)
                }
            } else {
                if translation.width < -navigationThreshold && canGoNext {
                    navigateToNext()
                } else if translation.width > navigationThreshold && canGoPrevious {
                    navigateToPrevious()
                } else {
                    triggerBounceEffect(translation: translation, isPortrait: isPortrait)
                }
            }
        }
    }

    private func triggerBounceEffect(translation: CGSize, isPortrait: Bool) {
        let bounceDistance: CGFloat = 20

        if isPortrait {
            bounceOffset = translation.height > 0 ? bounceDistance : -bounceDistance
        } else {
            bounceOffset = translation.width > 0 ? bounceDistance : -bounceDistance
        }

        Task { @MainActor in
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            bounceOffset = 0
        }
    }

    // MARK: - Navigation Methods
    @MainActor
    func navigateToNext() {
        guard canGoNext else { return }

        Task {
            await performTransition(to: currentRallyIndex + 1)
        }
    }

    @MainActor
    func navigateToPrevious() {
        guard canGoPrevious else { return }

        Task {
            await performTransition(to: currentRallyIndex - 1)
        }
    }

    @MainActor
    private func performTransition(to newIndex: Int) async {
        guard let metadata = processingMetadata,
              newIndex >= 0 && newIndex < metadata.rallySegments.count else { return }

        isTransitioning = true

        // Flash effect
        showFlash = true
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        showFlash = false

        // Crossfade transition
        withAnimation(.easeInOut(duration: 0.15)) {
            transitionOpacity = 0.3
        }

        currentRallyIndex = newIndex

        // Fade back in
        withAnimation(.easeInOut(duration: 0.15)) {
            transitionOpacity = 1.0
        }

        isTransitioning = false
    }

    // MARK: - Video Buffering Management
    @MainActor
    func startVideoBuffering() {
        isVideoBuffering = true
        playersReady = false
        videoLoadingProgress = 0.0
        bufferingTimeout = false

        // Set timeout for video loading (10 seconds)
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if isVideoBuffering {
                bufferingTimeout = true
                completeVideoBuffering(success: false)
            }
        }
    }

    @MainActor
    func updateVideoLoadingProgress(_ progress: Double) {
        videoLoadingProgress = min(1.0, max(0.0, progress))
    }

    @MainActor
    func completeVideoBuffering(success: Bool) {
        isVideoBuffering = false
        if success {
            playersReady = true
            videoLoadingProgress = 1.0
        } else {
            playersReady = false
            if bufferingTimeout {
                hasError = true
                errorMessage = "Video loading timed out. Please try again."
            }
        }
    }

    // MARK: - State Computed Properties
    var shouldShowLoading: Bool {
        return isLoading || isVideoBuffering
    }

    var canInteract: Bool {
        return !isLoading && !isVideoBuffering && playersReady && !isTransitioning
    }

    // MARK: - Reset Methods
    func reset() {
        currentRallyIndex = 0
        dragOffset = .zero
        isDragging = false
        bounceOffset = 0.0
        isTransitioning = false
        transitionOpacity = 1.0
        showFlash = false
        isLoading = true
        hasError = false
        errorMessage = ""
        processingMetadata = nil

        // Reset video buffering state
        isVideoBuffering = false
        playersReady = false
        videoLoadingProgress = 0.0
        bufferingTimeout = false
    }
}

// MARK: - Supporting Types
enum RallyNavigationError: Error, LocalizedError {
    case noRalliesFound
    case noMetadataAvailable

    var errorDescription: String? {
        switch self {
        case .noRalliesFound:
            return "No rally segments were detected in this video."
        case .noMetadataAvailable:
            return "Rally metadata is not available for this video."
        }
    }
}

enum GestureAxis {
    case horizontal
    case vertical
}