import SwiftUI

// MARK: - BSCEmptyState
/// A configurable empty state component with icon, message, and optional action
struct BSCEmptyState: View {
    // MARK: - Properties
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var secondaryActionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    var onSecondaryAction: (() -> Void)? = nil
    var actionAccessibilityID: String? = nil

    // MARK: - Body
    var body: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Icon + text combine into one element; buttons stay individually
            // focusable/queryable for VoiceOver and UI tests.
            VStack(spacing: BSCSpacing.xl) {
                // Animated icon
                animatedIcon

                // Text content
                VStack(spacing: BSCSpacing.sm) {
                    Text(title)
                        .bscFont(size: 20, weight: .bold)
                        .foregroundColor(.bscTextPrimary)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(message)")

            // Action buttons
            if actionTitle != nil || secondaryActionTitle != nil {
                VStack(spacing: BSCSpacing.md) {
                    if let actionTitle = actionTitle, let onAction = onAction {
                        BSCButton(title: actionTitle, style: .primary, action: onAction)
                            .frame(maxWidth: BSCContentWidth.compact)
                            .accessibilityIdentifier(actionAccessibilityID ?? "")
                    }

                    if let secondaryActionTitle = secondaryActionTitle, let onSecondaryAction = onSecondaryAction {
                        BSCButton(title: secondaryActionTitle, style: .ghost, action: onSecondaryAction)
                            .frame(maxWidth: BSCContentWidth.compact)
                    }
                }
            }
        }
        .padding(BSCSpacing.xxl)
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Animated Icon
    private var animatedIcon: some View {
        ZStack {
            // Glow circle
            Circle()
                .fill(Color.bscPrimary.opacity(0.1))
                .frame(width: 120, height: 120)

            // Icon circle
            Circle()
                .fill(Color.bscSurfaceGlass)
                .frame(width: 80, height: 80)
                .overlay(
                    Circle()
                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                )

            // Icon
            Image(systemName: icon)
                .bscFont(size: 32, weight: .medium)
                .foregroundStyle(LinearGradient.bscPrimaryGradient)
                .bscFloatingEffect()
        }
    }
}

// MARK: - Preset Empty States
extension BSCEmptyState {
    /// Empty library state
    static func noVideos(onUpload: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "video.badge.plus",
            title: "No Videos Yet",
            message: "Upload your first volleyball video to get started with rally detection.",
            actionTitle: "Upload Video",
            onAction: onUpload
        )
    }

    /// Empty folder state
    static func emptyFolder(onUpload: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "folder.badge.plus",
            title: "Empty Folder",
            message: "This folder doesn't have any videos yet. Add some to organize your content.",
            actionTitle: "Upload Video",
            onAction: onUpload
        )
    }

    /// No rallies detected state
    static func noRallies(onRetry: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "figure.volleyball",
            title: "No Rallies Found",
            message: "We couldn't detect any volleyball rallies in this video. Try a video with more visible ball movement.",
            actionTitle: "Try Another Video",
            onAction: onRetry
        )
    }

    /// Rally playback opened for a video with no detected rally segments
    static func noRallySegments(onGoBack: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "film.stack",
            title: "No Rallies Found",
            message: "This video doesn't have any detected rally segments. Try processing the video first.",
            actionTitle: "Go Back",
            onAction: onGoBack
        )
    }

    /// Home processing queue is empty
    static func allCaughtUp() -> BSCEmptyState {
        BSCEmptyState(
            icon: "checkmark.seal.fill",
            title: "All Caught Up!",
            message: "No unprocessed videos. Import a new one above."
        )
    }

    /// No search results state
    static func noSearchResults(query: String, onClear: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "magnifyingglass",
            title: "No Results",
            message: "No videos match \"\(query)\". Try a different search term.",
            actionTitle: "Clear Search",
            onAction: onClear
        )
    }

    /// No processed videos state - for processed videos view when empty
    static func noProcessedVideos(onViewLibrary: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "brain.head.profile",
            title: "No Processed Videos",
            message: "You haven't processed any videos yet. Process a video to automatically detect rallies, or view your saved video library.",
            actionTitle: "View Saved Library",
            onAction: onViewLibrary
        )
    }

    /// All videos processed state - for unprocessed videos view when empty
    static func noUnprocessedVideos(onViewLibrary: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "video.badge.checkmark",
            title: "All Videos Processed",
            message: "Great job! All your videos have been processed. View your saved library to see all content.",
            actionTitle: "View Saved Library",
            onAction: onViewLibrary
        )
    }

    // MARK: - Social Empty States

    /// Following feed with no highlights from followed users
    static func noFollowingHighlights(actionAccessibilityID: String? = nil, onRefresh: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "person.2",
            title: "No highlights from followed users",
            message: "Follow players to see their highlights here.",
            actionTitle: "Refresh",
            onAction: onRefresh,
            actionAccessibilityID: actionAccessibilityID
        )
    }

    /// For You feed with no highlights at all
    static func noHighlights(actionAccessibilityID: String? = nil, onRefresh: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "figure.volleyball",
            title: "No highlights yet",
            message: "Be the first to share a volleyball rally!",
            actionTitle: "Refresh",
            onAction: onRefresh,
            actionAccessibilityID: actionAccessibilityID
        )
    }

    /// User has no posted highlights
    static func noUserHighlights(isOwnProfile: Bool) -> BSCEmptyState {
        BSCEmptyState(
            icon: "figure.volleyball",
            title: isOwnProfile ? "No Highlights Yet" : "No Posts Yet",
            message: isOwnProfile
                ? "Share your best rallies with the community. Process a video and post your first highlight!"
                : "This player hasn't posted any highlights yet.",
            actionTitle: nil,
            onAction: nil
        )
    }

    /// No followers
    static func noFollowers() -> BSCEmptyState {
        BSCEmptyState(
            icon: "person.2.slash",
            title: "No Followers Yet",
            message: "Share great highlights to attract followers!",
            actionTitle: nil,
            onAction: nil
        )
    }

    /// Not following anyone
    static func noFollowing(onDiscover: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "person.crop.circle.badge.plus",
            title: "Not Following Anyone",
            message: "Discover players and follow them to see their content in your feed.",
            actionTitle: "Discover Players",
            onAction: onDiscover
        )
    }

    /// Failed to load remote content. Use for any social surface that had a network/auth error.
    static func loadFailed(message: String? = nil, onRetry: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "wifi.exclamationmark",
            title: "Couldn't load",
            message: message ?? "Check your connection and try again.",
            actionTitle: "Retry",
            onAction: onRetry
        )
    }
}

// MARK: - Preview
#Preview("BSCEmptyState") {
    ScrollView {
        VStack(spacing: BSCSpacing.xxl) {
            BSCEmptyState.noVideos(onUpload: {})

            Divider()
                .background(Color.bscSurfaceBorder)

            BSCEmptyState.noRallies(onRetry: {})

            Divider()
                .background(Color.bscSurfaceBorder)

            BSCEmptyState.noSearchResults(query: "beach", onClear: {})
        }
        .padding()
    }
    .background(Color.bscBackground)
}
