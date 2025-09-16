//
//  RallyPlayerFactory.swift
//  BumpSetCut
//
//  Factory for creating the appropriate rally player view based on app settings
//

import SwiftUI
import AVKit

@MainActor
struct RallyPlayerFactory {
    /// Creates the appropriate rally player view based on app settings and metadata availability
    static func createRallyPlayer(
        for videoMetadata: VideoMetadata,
        appSettings: AppSettings
    ) -> AnyView {
        // Determine which view to use
        let shouldUseSwipeable = appSettings.shouldUseSwipeableRallyPlayer(for: videoMetadata)

        if shouldUseSwipeable {
            // Log analytics for new view usage
            if appSettings.enableAnalytics {
                appSettings.logRallyViewUsage(
                    viewType: .swipeable,
                    duration: 0, // Will be updated when view appears
                    rallyCount: 0 // Will be updated when metadata loads
                )
            }

            return AnyView(
                TikTokRallyPlayerView(videoMetadata: videoMetadata)
                    .onAppear {
                        print("🎯 Using TikTokRallyPlayerView for \(videoMetadata.displayName)")
                    }
            )
        } else if videoMetadata.hasMetadata {
            // Use legacy rally player for videos with metadata
            if appSettings.enableAnalytics {
                appSettings.logRallyViewUsage(
                    viewType: .legacy,
                    duration: 0,
                    rallyCount: 0
                )
            }

            return AnyView(
                RallyPlayerView(videoMetadata: videoMetadata)
                    .onAppear {
                        print("🎯 Using RallyPlayerView (legacy) for \(videoMetadata.displayName)")
                    }
            )
        } else {
            // Fallback to basic video player for videos without rally metadata
            if appSettings.enableAnalytics {
                appSettings.logRallyViewUsage(
                    viewType: .fallback,
                    duration: 0,
                    rallyCount: 0
                )
            }

            return AnyView(
                VideoPlayerView(videoURL: videoMetadata.originalURL)
                    .onAppear {
                        print("🎯 Using VideoPlayerView (fallback) for \(videoMetadata.displayName)")
                    }
            )
        }
    }

    /// Creates a rally player with enhanced analytics tracking
    static func createAnalyticsWrappedRallyPlayer(
        for videoMetadata: VideoMetadata,
        appSettings: AppSettings
    ) -> some View {
        AnalyticsWrappedRallyPlayer(
            videoMetadata: videoMetadata,
            appSettings: appSettings
        )
    }
}

// MARK: - Analytics Wrapped Player

@MainActor
struct AnalyticsWrappedRallyPlayer: View {
    let videoMetadata: VideoMetadata
    let appSettings: AppSettings
    @State private var startTime = Date()

    var body: some View {
        RallyPlayerFactory.createRallyPlayer(for: videoMetadata, appSettings: appSettings)
            .onAppear {
                startTime = Date()
            }
            .onDisappear {
                // Log session duration when view disappears
                let sessionDuration = Date().timeIntervalSince(startTime)
                let viewType: RallyViewType = appSettings.shouldUseSwipeableRallyPlayer(for: videoMetadata) ? .swipeable : .legacy

                if appSettings.enableAnalytics {
                    appSettings.logRallyViewUsage(
                        viewType: viewType,
                        duration: sessionDuration,
                        rallyCount: 0 // TODO: Get actual rally count from metadata
                    )
                }

                print("📊 Rally view session ended - Type: \(viewType.rawValue), Duration: \(String(format: "%.1f", sessionDuration))s")
            }
    }
}

// MARK: - Enhanced SwipeableRallyPlayerView with Analytics

struct AnalyticsSwipeableRallyPlayerView: View {
    let videoMetadata: VideoMetadata
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        TikTokRallyPlayerView(videoMetadata: videoMetadata)
            .overlay(
                // Invisible gesture overlay for analytics
                AnalyticsGestureOverlay(appSettings: appSettings)
            )
    }
}

// MARK: - Analytics Gesture Overlay

@MainActor
struct AnalyticsGestureOverlay: View {
    let appSettings: AppSettings

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onEnded { value in
                        trackSwipeGesture(translation: value.translation)
                    }
            )
            .onTapGesture {
                if appSettings.enableAnalytics {
                    appSettings.logRallyGestureUsage(
                        gestureType: .tapPlayPause,
                        rallyIndex: 0 // TODO: Get current rally index
                    )
                }
            }
    }

    private func trackSwipeGesture(translation: CGSize) {
        guard appSettings.enableAnalytics else { return }

        let threshold: CGFloat = 100
        let gestureType: RallyGestureType

        if abs(translation.height) > abs(translation.width) {
            // Vertical swipe (portrait mode)
            gestureType = translation.height < -threshold ? .swipeNext : .swipePrevious
        } else {
            // Horizontal swipe (landscape mode)
            gestureType = translation.width < -threshold ? .swipeNext : .swipePrevious
        }

        appSettings.logRallyGestureUsage(
            gestureType: gestureType,
            rallyIndex: 0 // TODO: Get current rally index
        )
    }
}

// MARK: - Debug Helpers

#if DEBUG
struct RallyPlayerPreview: View {
    @StateObject private var settings = AppSettings.shared
    let sampleVideo = VideoMetadata(
        fileName: "sample.mp4",
        customName: "Sample Rally Video",
        folderPath: "test",
        createdDate: Date(),
        fileSize: 1024000,
        duration: 120.0
    )

    var body: some View {
        VStack(spacing: 20) {
            Toggle("Use TikTok Rally View", isOn: $settings.useTikTokRallyView)
                .padding()

            RallyPlayerFactory.createRallyPlayer(
                for: sampleVideo,
                appSettings: settings
            )
        }
        .environmentObject(settings)
    }
}
#endif