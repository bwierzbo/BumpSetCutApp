//
//  EnhancedVideoManagementExample.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

/// Example showing how to use the enhanced video management components
/// This demonstrates integration with bulk operations, selection, and context menus
struct EnhancedVideoManagementExample: View {
    @StateObject private var mediaStore = MediaStore()
    @State private var selectedVideoFileNames: Set<String> = []
    @State private var isSelectionMode = false
    @State private var showingBulkMoveDialog = false
    @State private var showingBulkDeleteConfirmation = false
    @State private var viewMode: ViewMode = .list
    @State private var currentFolder = ""
    
    // Sample videos for demonstration
    @State private var videos: [VideoMetadata] = []
    @State private var folders: [FolderMetadata] = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header with selection controls
                HStack {
                    Text(currentFolder.isEmpty ? "Your Library" : currentFolder)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    // View mode toggle
                    Picker("View Mode", selection: $viewMode) {
                        Image(systemName: "list.bullet").tag(ViewMode.list)
                        Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 100)
                    
                    // Selection mode toggle
                    Button(isSelectionMode ? "Cancel" : "Select") {
                        toggleSelectionMode()
                    }
                    .foregroundColor(.blue)
                }
                .padding()
                
                Divider()
                
                // Main content
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewMode == .grid {
                            createVideosGrid()
                        } else {
                            createVideosList()
                        }
                    }
                    .padding()
                }
                
                // Bulk operations bar (shown when in selection mode)
                if isSelectionMode {
                    BulkVideoOperationsBar(
                        selectedCount: selectedVideoFileNames.count,
                        totalCount: videos.count,
                        onSelectAll: selectAllVideos,
                        onDeselectAll: deselectAllVideos,
                        onBulkMove: showBulkMoveDialog,
                        onBulkDelete: showBulkDeleteConfirmation,
                        onCancel: exitSelectionMode
                    )
                }
            }
            .navigationBarHidden(true)
        }
        .environmentObject(mediaStore)
        .onAppear {
            loadSampleData()
        }
        .sheet(isPresented: $showingBulkMoveDialog) {
            BulkVideoMoveDialog(
                videoFileNames: Array(selectedVideoFileNames),
                currentFolder: currentFolder,
                onMove: handleBulkMove,
                onCancel: {
                    showingBulkMoveDialog = false
                }
            )
        }
        .alert("Delete \(selectedVideoFileNames.count) Videos", isPresented: $showingBulkDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                handleBulkDelete()
            }
        } message: {
            Text("Are you sure you want to delete \(selectedVideoFileNames.count) selected videos? This action cannot be undone.")
        }
    }
    
    // MARK: - Content Views
    
    private func createVideosList() -> some View {
        VStack(spacing: 8) {
            ForEach(videos, id: \.id) { video in
                StoredVideo(
                    videoURL: video.originalURL,
                    onDelete: {
                        handleVideoDelete(video)
                    },
                    onRefresh: {
                        // Refresh logic here
                    },
                    onRename: { newName in
                        handleVideoRename(video, newName: newName)
                    },
                    onMove: { folderPath in
                        handleVideoMove(video, toFolder: folderPath)
                    },
                    isSelectable: isSelectionMode,
                    isSelected: selectedVideoFileNames.contains(video.fileName),
                    onSelectionToggle: {
                        toggleVideoSelection(video)
                    }
                )
            }
        }
    }
    
    private func createVideosGrid() -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
            ForEach(videos, id: \.id) { video in
                VideoCardView(
                    video: video,
                    onDelete: {
                        handleVideoDelete(video)
                    },
                    onRefresh: {
                        // Refresh logic here
                    },
                    onRename: { newName in
                        handleVideoRename(video, newName: newName)
                    },
                    onMove: { folderPath in
                        handleVideoMove(video, toFolder: folderPath)
                    },
                    isSelectable: isSelectionMode,
                    isSelected: selectedVideoFileNames.contains(video.fileName),
                    onSelectionToggle: {
                        toggleVideoSelection(video)
                    }
                )
            }
        }
    }
    
    // MARK: - Selection Management
    
    private func toggleSelectionMode() {
        withAnimation {
            isSelectionMode.toggle()
            if !isSelectionMode {
                selectedVideoFileNames.removeAll()
            }
        }
    }
    
    private func exitSelectionMode() {
        withAnimation {
            isSelectionMode = false
            selectedVideoFileNames.removeAll()
        }
    }
    
    private func toggleVideoSelection(_ video: VideoMetadata) {
        if selectedVideoFileNames.contains(video.fileName) {
            selectedVideoFileNames.remove(video.fileName)
        } else {
            selectedVideoFileNames.insert(video.fileName)
        }
    }
    
    private func selectAllVideos() {
        selectedVideoFileNames = Set(videos.map { $0.fileName })
    }
    
    private func deselectAllVideos() {
        selectedVideoFileNames.removeAll()
    }
    
    // MARK: - Video Operations
    
    private func handleVideoDelete(_ video: VideoMetadata) {
        // Delete single video
        if mediaStore.deleteVideo(fileName: video.fileName) {
            videos.removeAll { $0.fileName == video.fileName }
        }
    }
    
    private func handleVideoRename(_ video: VideoMetadata, newName: String) {
        // Rename video
        if mediaStore.renameVideo(fileName: video.fileName, to: newName) {
            // Update local list
            if let index = videos.firstIndex(where: { $0.fileName == video.fileName }) {
                videos[index] = VideoMetadata(
                    originalURL: video.originalURL,
                    customName: newName,
                    folderPath: video.folderPath,
                    createdDate: video.createdDate,
                    fileSize: video.fileSize,
                    duration: video.duration
                )
            }
        }
    }
    
    private func handleVideoMove(_ video: VideoMetadata, toFolder folderPath: String) {
        // Move single video
        if mediaStore.moveVideo(fileName: video.fileName, toFolder: folderPath) {
            // Update local list or reload
            loadSampleData()
        }
    }
    
    // MARK: - Bulk Operations
    
    private func showBulkMoveDialog() {
        showingBulkMoveDialog = true
    }
    
    private func showBulkDeleteConfirmation() {
        showingBulkDeleteConfirmation = true
    }
    
    private func handleBulkMove(toFolder folderPath: String) {
        Task {
            for fileName in selectedVideoFileNames {
                _ = mediaStore.moveVideo(fileName: fileName, toFolder: folderPath)
            }
            
            await MainActor.run {
                selectedVideoFileNames.removeAll()
                showingBulkMoveDialog = false
                exitSelectionMode()
                loadSampleData()
            }
        }
    }
    
    private func handleBulkDelete() {
        Task {
            for fileName in selectedVideoFileNames {
                _ = mediaStore.deleteVideo(fileName: fileName)
            }
            
            await MainActor.run {
                // Remove deleted videos from local list
                videos.removeAll { selectedVideoFileNames.contains($0.fileName) }
                selectedVideoFileNames.removeAll()
                exitSelectionMode()
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadSampleData() {
        // Load videos from current folder
        videos = mediaStore.getVideos(in: currentFolder)
        folders = mediaStore.getFolders(in: currentFolder)
    }
}

// MARK: - Supporting Types

// MARK: - Preview

#Preview {
    EnhancedVideoManagementExample()
}