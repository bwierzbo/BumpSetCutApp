//
//  StoredVideo.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import SwiftUI
import AVKit

struct StoredVideo: View {
    let videoMetadata: VideoMetadata
    let mediaStore: MediaStore
    let onDelete: () -> ()
    let onRefresh: () -> ()
    let onRename: ((String) -> Void)?
    let onMove: ((String) -> Void)?
    let isSelectable: Bool
    let isSelected: Bool
    let onSelectionToggle: (() -> Void)?
    
    // Computed properties for backward compatibility
    var videoURL: URL { videoMetadata.originalURL }
    var displayName: String? { videoMetadata.customName }
    var folderPath: String { videoMetadata.folderPath }
    
    @State private var showingVideoPlayer = false
    @State private var showingDeleteConfirmation = false
    @State private var showingProcessVideo = false
    @State private var showingRenameDialog = false
    @State private var showingMoveDialog = false
    @State private var thumbnail: UIImage?
    @State private var isLongPressing = false

    var body: some View {
        HStack(spacing: 16) {
            // Selection checkbox
            if isSelectable {
                Button {
                    onSelectionToggle?()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
            }
            
            createThumbnail()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isLongPressing ? Color.black.opacity(0.2) : Color.clear)
                )
            
            createText()
            
            Spacer()
            
            // Three-dot menu button
            Menu {
                if videoMetadata.canBeProcessed {
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
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(width: 30, height: 30)
            }
            
            if videoMetadata.canBeProcessed {
                createProcessButton()
            }
            createDeleteButton()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectable {
                onSelectionToggle?()
            } else {
                presentVideoPlayer()
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            // Long press handled via contextMenu
        } onPressingChanged: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isLongPressing = pressing
            }
        }
        .contextMenu {
            if videoMetadata.canBeProcessed {
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
        .onAppear(perform: generateThumbnail)
        .sheet(isPresented: $showingVideoPlayer, content: createVideoPlayerSheet)
        .sheet(isPresented: $showingProcessVideo, content: createProcessVideoSheet)
        .sheet(isPresented: $showingRenameDialog) {
            VideoRenameDialog(
                currentName: displayName ?? videoURL.deletingPathExtension().lastPathComponent,
                onRename: { newName in
                    onRename?(newName)
                    showingRenameDialog = false
                },
                onCancel: {
                    showingRenameDialog = false
                }
            )
        }
        .sheet(isPresented: $showingMoveDialog) {
            VideoMoveDialog(
                mediaStore: mediaStore,
                currentFolder: "", // StoredVideo doesn't know its folder path - this needs to be passed in
                onMove: { folderPath in
                    onMove?(folderPath)
                    showingMoveDialog = false
                },
                onCancel: {
                    showingMoveDialog = false
                }
            )
        }
        .alert("Delete Video", isPresented: $showingDeleteConfirmation, actions: createDeleteAlert)
    }
}

// MARK: - Thumbnail
private extension StoredVideo {
    func createThumbnail() -> some View {
        Group {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.gray)
            }
        }
    }
    
    func generateThumbnail() {
        Task {
            let thumbnailImage = await createVideoThumbnail(from: videoURL)
            await MainActor.run {
                thumbnail = thumbnailImage
            }
        }
    }
    
    func createVideoThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 200, height: 200)
        
        do {
            let cgImage = try await imageGenerator.image(at: .zero).image
            return UIImage(cgImage: cgImage)
        } catch {
            print("Failed to generate thumbnail: \(error)")
            return nil
        }
    }
}

// MARK: - Text Content
private extension StoredVideo {
    func createText() -> some View {
        VStack(alignment: .leading, spacing: 3) {
            createTitleText()
            createProcessingStatusText()
            Spacer(minLength: 2)
            HStack {
                createDateText()
                Spacer()
                createExtensionText()
            }
            createMetadataText()
        }
        .frame(height: 72, alignment: .top)
    }

    func createTitleText() -> some View {
        Text(videoMetadata.displayName)
            .font(.headline)
            .foregroundColor(.primary)
            .lineLimit(1)
    }
    
    func createProcessingStatusText() -> some View {
        HStack(spacing: 4) {
            statusIcon
            Text(statusText)
                .font(.caption)
                .foregroundColor(statusColor)
        }
    }
    
    private var statusIcon: some View {
        Image(systemName: statusIconName)
            .font(.caption)
            .foregroundColor(statusColor)
    }
    
    private var statusIconName: String {
        if videoMetadata.isProcessed {
            return "checkmark.seal.fill"
        } else if !videoMetadata.processedVideoIds.isEmpty {
            return "arrow.branch"
        } else {
            return "video.circle"
        }
    }
    
    private var statusText: String {
        if videoMetadata.isProcessed {
            return "Processed"
        } else if !videoMetadata.processedVideoIds.isEmpty {
            let count = videoMetadata.processedVideoIds.count
            return "\(count) version\(count == 1 ? "" : "s")"
        } else {
            return "Original"
        }
    }
    
    private var statusColor: Color {
        if videoMetadata.isProcessed {
            return .orange
        } else if !videoMetadata.processedVideoIds.isEmpty {
            return .blue
        } else {
            return .secondary
        }
    }

    func createDateText() -> some View {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
           let modifiedDate = attrs[.modificationDate] as? Date {
            return Text(modifiedDate.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            return Text("Unknown date")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    func createMetadataText() -> some View {
        HStack {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
               let fileSize = attrs[.size] as? Int64 {
                Text(formatFileSize(fileSize))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Duration display temporarily removed due to API deprecation
        }
    }

    func createExtensionText() -> some View {
        Text(videoURL.pathExtension.uppercased())
            .font(.caption2)
            .foregroundColor(.secondary)
    }
    
    // Helper functions for metadata
    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func getVideoDuration() -> TimeInterval? {
        // Duration functionality temporarily disabled due to API deprecation
        // The modern API requires async/await which doesn't fit this sync method
        return nil
    }
}

// MARK: - Delete Button
private extension StoredVideo {
    func createProcessButton() -> some View {
        Button(action: presentProcessVideo) {
            Image(systemName: "brain.head.profile.fill")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundColor(.blue)
                .frame(width: 40, height: 30)
        }
        .onTapGesture {} // Prevents tap from propagating to parent
    }
    
    func createDeleteButton() -> some View {
        Button(action: presentDeleteConfirmation) {
            Image(systemName: "trash.fill")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundColor(.red)
                .frame(width: 40, height: 30)
        }
        .onTapGesture {} // Prevents tap from propagating to parent
    }
    
    func presentDeleteConfirmation() {
        showingDeleteConfirmation = true
    }
    
    func presentProcessVideo() {
        showingProcessVideo = true
    }
    
    func createDeleteAlert() -> some View {
        Group {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Video Player
private extension StoredVideo {
    func presentVideoPlayer() {
        showingVideoPlayer = true
    }
    
    func createVideoPlayerSheet() -> some View {
        VideoPlayerView(videoURL: videoURL)
    }
    
    func createProcessVideoSheet() -> some View {
        ProcessVideoView(videoURL: videoURL, mediaStore: mediaStore, folderPath: folderPath, onComplete: onRefresh)
    }
}
