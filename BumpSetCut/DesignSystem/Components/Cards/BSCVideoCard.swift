import SwiftUI
import AVKit

// MARK: - BSCVideoCard
/// A unified video card component that replaces StoredVideo and VideoCardView
/// Supports both list and grid display modes with consistent styling
struct BSCVideoCard: View {
    // MARK: - Types
    enum DisplayMode {
        case list   // Horizontal layout with thumbnail on left
        case grid   // Vertical layout with thumbnail on top
    }

    // MARK: - Properties
    let video: VideoMetadata
    let mediaStore: MediaStore
    let displayMode: DisplayMode
    let onDelete: () -> Void
    let onRefresh: () -> Void
    var onRename: ((String) -> Void)? = nil
    var onMove: ((String) -> Void)? = nil
    var isSelectable: Bool = false
    var isSelected: Bool = false
    var onSelectionToggle: (() -> Void)? = nil
    var libraryType: LibraryType? = nil  // Determines video playback behavior

    // MARK: - State
    @State private var thumbnail: UIImage?
    @State private var showingVideoPlayer = false
    @State private var showingProcessVideo = false
    @State private var showingDeleteConfirmation = false
    @State private var showingRenameDialog = false
    @State private var showingMoveDialog = false
    @State private var isPressed = false

    // MARK: - Body
    var body: some View {
        Group {
            switch displayMode {
            case .list:
                listLayout
            case .grid:
                gridLayout
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .contextMenu { contextMenuContent }
        .onAppear(perform: generateThumbnail)
        .fullScreenCover(isPresented: $showingVideoPlayer) {
            // Saved Games: Always play full original video
            // Other libraries: Use factory to decide based on metadata
            if libraryType == .saved {
                VideoPlayerView(videoURL: video.originalURL)
            } else {
                RallyPlayerFactory.createRallyPlayer(for: video)
            }
        }
        .sheet(isPresented: $showingProcessVideo) {
            ProcessVideoView(
                videoURL: video.originalURL,
                mediaStore: mediaStore,
                folderPath: video.folderPath,
                onComplete: onRefresh,
                onShowPlayer: { showingVideoPlayer = true }
            )
        }
        .sheet(isPresented: $showingRenameDialog) {
            VideoRenameDialog(
                currentName: video.displayName,
                onRename: { newName in
                    onRename?(newName)
                    showingRenameDialog = false
                },
                onCancel: { showingRenameDialog = false }
            )
        }
        .sheet(isPresented: $showingMoveDialog) {
            VideoMoveDialog(
                mediaStore: mediaStore,
                currentFolder: video.folderPath,
                onMove: { folderPath in
                    onMove?(folderPath)
                    showingMoveDialog = false
                },
                onCancel: { showingMoveDialog = false }
            )
        }
        .alert("Delete Video", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("Are you sure you want to delete this video? This action cannot be undone.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(isSelectable ? "Double tap to select" : "Double tap to play")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - List Layout
    private var listLayout: some View {
        HStack(spacing: BSCSpacing.lg) {
            // Selection checkbox
            if isSelectable {
                selectionCheckbox
            }

            // Thumbnail
            thumbnailView
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                .overlay(thumbnailBorder)

            // Info
            listInfoView

            Spacer()

            // Menu button
            menuButton

            // Quick action buttons
            if video.canBeProcessed {
                quickProcessButton
            }
            quickDeleteButton
        }
        .padding(.vertical, BSCSpacing.sm)
        .background(isSelected ? Color.bscBlue.opacity(0.1) : Color.clear)
        .bscInteractive(isSelected: isSelected, cornerRadius: BSCRadius.md)
    }

    // MARK: - Grid Layout
    private var gridLayout: some View {
        VStack(spacing: BSCSpacing.sm) {
            // Thumbnail with overlays
            ZStack {
                thumbnailView
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))

                // Gradient overlay for better text readability
                thumbnailGradientOverlay

                // Selection checkbox
                if isSelectable {
                    selectionOverlay
                }

                // Play button
                playButtonOverlay
            }
            .overlay(gridThumbnailBorder)

            // Info section
            gridInfoView
        }
        .frame(maxWidth: .infinity, maxHeight: 200)
        .bscInteractive(isSelected: isSelected, cornerRadius: BSCRadius.lg)
    }

    // MARK: - Thumbnail Views
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            // Skeleton loader with shimmer effect
            BSCSkeletonView()
        }
    }

    private var thumbnailGradientOverlay: some View {
        LinearGradient(
            colors: [Color.clear, Color.black.opacity(0.3)],
            startPoint: .center,
            endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
    }

    private var thumbnailBorder: some View {
        RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
            .stroke(isSelected ? Color.bscBlue : Color.bscSurfaceBorder, lineWidth: isSelected ? 2 : 1)
    }

    private var gridThumbnailBorder: some View {
        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
            .stroke(isSelected ? Color.bscBlue : Color.clear, lineWidth: 3)
    }

    // MARK: - Selection Views
    private var selectionCheckbox: some View {
        Button {
            onSelectionToggle?()
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(isSelected ? .bscBlue : .bscTextSecondary)
        }
    }

    private var selectionOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    onSelectionToggle?()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .bscBlue : .white)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.6))
                                .frame(width: 28, height: 28)
                        )
                }
                .padding(BSCSpacing.sm)
            }
            Spacer()
        }
    }

    private var playButtonOverlay: some View {
        Circle()
            .fill(Color.black.opacity(0.6))
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            )
    }

    // MARK: - Info Views
    private var listInfoView: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
            // Title
            Text(video.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.bscTextPrimary)
                .lineLimit(1)

            // Status badge
            statusBadge

            Spacer(minLength: BSCSpacing.xxs)

            // Metadata row
            HStack {
                dateText
                Spacer()
                extensionBadge
            }

            // Size
            fileSizeText
        }
        .frame(height: 72, alignment: .top)
    }

    private var gridInfoView: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            // Title
            Text(video.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.bscTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Status badge
            statusBadge

            // Duration and size
            HStack {
                durationText
                Spacer()
                fileSizeText
            }

            // Date
            dateText
        }
        .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70, alignment: .topLeading)
        .padding(.horizontal, BSCSpacing.xs)
    }

    // MARK: - Status Badge
    private var statusBadge: some View {
        HStack(spacing: BSCSpacing.xs) {
            Image(systemName: statusIconName)
                .font(.caption2)
                .foregroundColor(statusColor)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(statusColor)
        }
    }

    private var statusIconName: String {
        if video.isProcessed {
            return "checkmark.seal.fill"
        } else if !video.processedVideoIds.isEmpty {
            return "arrow.branch"
        } else {
            return "video.circle"
        }
    }

    private var statusText: String {
        if video.isProcessed {
            return "Processed"
        } else if !video.processedVideoIds.isEmpty {
            let count = video.processedVideoIds.count
            return "\(count) version\(count == 1 ? "" : "s")"
        } else {
            return "Original"
        }
    }

    private var statusColor: Color {
        if video.isProcessed {
            return .bscStatusProcessed
        } else if !video.processedVideoIds.isEmpty {
            return .bscStatusVersioned
        } else {
            return .bscStatusOriginal
        }
    }

    // MARK: - Metadata Views
    private var dateText: some View {
        Text(video.createdDate.formatted(date: .abbreviated, time: .omitted))
            .font(.caption2)
            .foregroundColor(.bscTextTertiary)
    }

    private var durationText: some View {
        Group {
            if let duration = video.duration {
                Text(formatDuration(duration))
            } else {
                Text("--:--")
            }
        }
        .font(.caption2)
        .foregroundColor(.bscTextSecondary)
    }

    private var fileSizeText: some View {
        Text(formatFileSize(video.fileSize))
            .font(.caption2)
            .foregroundColor(.bscTextTertiary)
    }

    private var extensionBadge: some View {
        Text(video.originalURL.pathExtension.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.bscTextTertiary)
            .padding(.horizontal, BSCSpacing.xs)
            .padding(.vertical, BSCSpacing.xxs)
            .background(Color.bscSurfaceGlass)
            .clipShape(Capsule())
    }

    // MARK: - Action Buttons
    private var menuButton: some View {
        Menu {
            contextMenuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.bscTextSecondary)
                .frame(width: 32, height: 32)
                .background(Color.bscSurfaceGlass)
                .clipShape(Circle())
        }
    }

    private var quickProcessButton: some View {
        Button {
            showingProcessVideo = true
        } label: {
            Image(systemName: "brain.head.profile.fill")
                .font(.system(size: 16))
                .foregroundColor(.bscBlue)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Process with AI")
    }

    private var quickDeleteButton: some View {
        Button {
            showingDeleteConfirmation = true
        } label: {
            Image(systemName: "trash.fill")
                .font(.system(size: 16))
                .foregroundColor(.bscError)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Delete video")
    }

    // MARK: - Context Menu
    @ViewBuilder
    private var contextMenuContent: some View {
        if video.canBeProcessed {
            Button {
                showingProcessVideo = true
            } label: {
                Label("Process with AI", systemImage: "brain.head.profile")
            }
            Divider()
        }

        if onRename != nil {
            Button {
                showingRenameDialog = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }

        if onMove != nil {
            Button {
                showingMoveDialog = true
            } label: {
                Label("Move", systemImage: "folder")
            }
        }

        Divider()

        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions
    private func handleTap() {
        if isSelectable {
            onSelectionToggle?()
        } else {
            showingVideoPlayer = true
        }
    }

    private func generateThumbnail() {
        Task {
            let image = await createThumbnail(from: video.originalURL)
            await MainActor.run {
                thumbnail = image
            }
        }
    }

    private func createThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 400, height: 400)

        do {
            let cgImage = try await imageGenerator.image(at: CMTime(seconds: 1.0, preferredTimescale: 600)).image
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    // MARK: - Formatters
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Accessibility
    private var accessibilityLabelText: String {
        var label = video.displayName
        label += ", \(statusText)"
        if let duration = video.duration {
            label += ", \(formatDuration(duration))"
        }
        label += ", \(formatFileSize(video.fileSize))"
        return label
    }
}

// MARK: - Preview
#Preview("BSCVideoCard") {
    ScrollView {
        VStack(spacing: BSCSpacing.lg) {
            Text("List Mode")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)

            // Note: Preview requires actual MediaStore and VideoMetadata
            // This is a placeholder structure for preview purposes

            Text("Grid Mode")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)
        }
        .padding()
    }
    .background(Color.bscBackground)
}
