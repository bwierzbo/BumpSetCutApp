import SwiftUI

// MARK: - BSCEmptyState
/// A configurable empty state component with icon, message, and optional action.
/// Title and message are localized resources; a message that is runtime text
/// (e.g. a server error) goes through `messageVerbatim` so it isn't looked up.
struct BSCEmptyState: View {
    // MARK: - Properties
    private let icon: String
    private let title: Text
    private let message: Text
    private let actionTitle: LocalizedStringResource?
    private let secondaryActionTitle: LocalizedStringResource?
    private let onAction: (() -> Void)?
    private let onSecondaryAction: (() -> Void)?
    private let actionAccessibilityID: String?

    init(
        icon: String,
        title: LocalizedStringResource,
        message: LocalizedStringResource,
        actionTitle: LocalizedStringResource? = nil,
        secondaryActionTitle: LocalizedStringResource? = nil,
        onAction: (() -> Void)? = nil,
        onSecondaryAction: (() -> Void)? = nil,
        actionAccessibilityID: String? = nil
    ) {
        self.icon = icon
        self.title = Text(title)
        self.message = Text(message)
        self.actionTitle = actionTitle
        self.secondaryActionTitle = secondaryActionTitle
        self.onAction = onAction
        self.onSecondaryAction = onSecondaryAction
        self.actionAccessibilityID = actionAccessibilityID
    }

    /// Same, with a message that is runtime text shown as-is.
    init(
        icon: String,
        title: LocalizedStringResource,
        messageVerbatim: String,
        actionTitle: LocalizedStringResource? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = Text(title)
        self.message = Text(verbatim: messageVerbatim)
        self.actionTitle = actionTitle
        self.secondaryActionTitle = nil
        self.onAction = onAction
        self.onSecondaryAction = nil
        self.actionAccessibilityID = nil
    }

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
                    title
                        .bscFont(size: 20, weight: .bold)
                        .foregroundColor(.bscTextPrimary)
                        .multilineTextAlignment(.center)

                    message
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title + Text(verbatim: ". ") + message)

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
    static func noRallySegments(onAddManually: @escaping () -> Void, onGoBack: @escaping () -> Void) -> BSCEmptyState {
        BSCEmptyState(
            icon: "film.stack",
            title: "No Rallies Found",
            message: "Detection didn't find any rallies in this video. You can mark them yourself on the timeline.",
            actionTitle: "Add Rallies Manually",
            secondaryActionTitle: "Go Back",
            onAction: onAddManually,
            onSecondaryAction: onGoBack
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
    /// `message` is runtime error text, shown verbatim; nil shows the generic hint.
    static func loadFailed(message: String? = nil, onRetry: @escaping () -> Void) -> BSCEmptyState {
        guard let message else {
            return BSCEmptyState(
                icon: "wifi.exclamationmark",
                title: "Couldn't load",
                message: "Check your connection and try again.",
                actionTitle: "Retry",
                onAction: onRetry
            )
        }
        return BSCEmptyState(
            icon: "wifi.exclamationmark",
            title: "Couldn't load",
            messageVerbatim: message,
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
