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

    @State private var isAnimating = false

    // MARK: - Body
    var body: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Animated icon
            animatedIcon

            // Text content
            VStack(spacing: BSCSpacing.sm) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action buttons
            if actionTitle != nil || secondaryActionTitle != nil {
                VStack(spacing: BSCSpacing.md) {
                    if let actionTitle = actionTitle, let onAction = onAction {
                        BSCButton(title: actionTitle, style: .primary, action: onAction)
                            .frame(maxWidth: UIScreen.main.bounds.width - 64)
                    }

                    if let secondaryActionTitle = secondaryActionTitle, let onSecondaryAction = onSecondaryAction {
                        BSCButton(title: secondaryActionTitle, style: .ghost, action: onSecondaryAction)
                            .frame(maxWidth: UIScreen.main.bounds.width - 64)
                    }
                }
            }
        }
        .padding(BSCSpacing.xxl)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }

    // MARK: - Animated Icon
    private var animatedIcon: some View {
        ZStack {
            // Glow circle
            Circle()
                .fill(Color.bscOrange.opacity(0.1))
                .frame(width: 120, height: 120)
                .scaleEffect(isAnimating ? 1.1 : 0.95)

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
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(LinearGradient.bscPrimaryGradient)
                .offset(y: isAnimating ? -4 : 0)
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
