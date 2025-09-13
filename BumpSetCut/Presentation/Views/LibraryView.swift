//
//  LibraryView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import SwiftUI
import PhotosUI

struct LibraryView: View {
    @StateObject private var folderManager: FolderManager
    @StateObject private var uploadCoordinator: UploadCoordinator
    @StateObject private var searchViewModel: SearchViewModel
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var sortOption: ContentSortOption = .name
    @State private var viewMode: ViewMode = .list
    @State private var searchText = ""
    
    init(mediaStore: MediaStore) {
        self._folderManager = StateObject(wrappedValue: FolderManager(mediaStore: mediaStore))
        self._uploadCoordinator = StateObject(wrappedValue: UploadCoordinator(mediaStore: mediaStore))
        self._searchViewModel = StateObject(wrappedValue: SearchViewModel(mediaStore: mediaStore))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Normal library view with search
                if !folderManager.currentPath.isEmpty {
                    createBreadcrumbView()
                }
                
                DropZoneView(uploadCoordinator: uploadCoordinator, destinationFolder: folderManager.currentPath) {
                    createScrollableView()
                }
                .onReceive(uploadCoordinator.uploadCompletedPublisher) { _ in
                    // Refresh the folder contents when upload completes
                    print("🔄 Upload completed, refreshing LibraryView contents")
                    folderManager.loadContents()
                }
                
                // Bottom progress indicators
                VStack(spacing: 0) {
                    // Upload status bar
                    UploadStatusBar(uploadCoordinator: uploadCoordinator)
                    
                    // General loading indicator
                    LoadingStatusBar(
                        isLoading: folderManager.isLoading,
                        message: "Loading content..."
                    )
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showingCreateFolder) {
                createFolderSheet()
            }
            .searchable(
                text: $searchText, 
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search videos and folders"
            )
            .onChange(of: searchText) { _, newSearchText in
                searchViewModel.searchText = newSearchText
            }
            .onReceive(NotificationCenter.default.publisher(for: .uploadCompleted)) { _ in
                folderManager.refreshContents()
            }
        }
    }
}

// MARK: - Content Options

enum ContentSortOption: String, CaseIterable {
    case name = "Name"
    case dateCreated = "Date Created"
    case fileSize = "File Size"
    
    var folderSort: FolderSortOption {
        switch self {
        case .name: return .name
        case .dateCreated: return .dateCreated
        case .fileSize: return .videoCount
        }
    }
    
    var videoSort: VideoSortOption {
        switch self {
        case .name: return .name
        case .dateCreated: return .dateCreated
        case .fileSize: return .fileSize
        }
    }
}

enum ViewMode: String, CaseIterable {
    case list = "List"
    case grid = "Grid"
}

// MARK: - Scrollable View
private extension LibraryView {
    func createScrollableView() -> some View {
        GeometryReader { geometry in
            ScrollView {
                createMediaView(geometry: geometry)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(content: createToolbar)
            .refreshable {
                folderManager.refreshContents()
            }
        }
    }
}


// MARK: - Toolbar
private extension LibraryView {
    func createToolbar() -> some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Menu {
                        Picker("Sort", selection: $sortOption) {
                            ForEach(ContentSortOption.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        
                        Picker("View", selection: $viewMode) {
                            ForEach(ViewMode.allCases, id: \.self) { mode in
                                Label(mode.rawValue, systemImage: mode == .list ? "list.bullet" : "square.grid.2x2")
                                    .tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    
                    Button {
                        showingCreateFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    
                    EnhancedUploadButton(
                        uploadCoordinator: uploadCoordinator,
                        destinationFolder: folderManager.currentPath
                    )
                }
                .padding(.trailing, 4)
            }
        }
    }
}

// MARK: - Media View
private extension LibraryView {
    func createMediaView(geometry: GeometryProxy) -> some View {
        LazyVStack(spacing: 16) {
            createMediaHeader(geometry: geometry)
            
            createContent(geometry: geometry)
        }
        .padding(geometry.size.width > geometry.size.height ? 20 : 16) // More padding in landscape
    }
}

// MARK: - Header
private extension LibraryView {
    func createMediaHeader(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(folderManager.currentPath.isEmpty ? "Your Library" : "Contents")
                    .font(isLandscape ? .title3 : .title2) // Smaller title in landscape
                    .fontWeight(.bold)
                
                let folderCount = folderManager.folders.count
                let videoCount = folderManager.videos.count
                if folderCount > 0 || videoCount > 0 {
                    Text("\(folderCount) folders, \(videoCount) videos")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Content Display
private extension LibraryView {
    func createContent(geometry: GeometryProxy) -> some View {
        let filteredFolders = getFilteredFolders()
        let filteredVideos = getFilteredVideos()
        let isLandscape = geometry.size.width > geometry.size.height
        
        if filteredFolders.isEmpty && filteredVideos.isEmpty && !folderManager.isLoading {
            return AnyView(createEmptyState())
        }
        
        return AnyView(
            VStack(spacing: isLandscape ? 12 : 16) { // Tighter spacing in landscape
                // Display folders first
                if !filteredFolders.isEmpty {
                    createFoldersSection(filteredFolders, geometry: geometry)
                }
                
                // Then display videos
                if !filteredVideos.isEmpty {
                    createVideosSection(filteredVideos, geometry: geometry)
                }
            }
        )
    }
    
    func createFoldersSection(_ folders: [FolderMetadata], geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        
        return VStack(alignment: .leading, spacing: 12) {
            if !folderManager.videos.isEmpty {
                HStack {
                    Text("Folders")
                        .font(isLandscape ? .subheadline : .headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            
            if viewMode == .grid {
                createFoldersGrid(folders, geometry: geometry)
            } else {
                createFoldersList(folders)
            }
        }
    }
    
    func createVideosSection(_ videos: [VideoMetadata], geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        
        return VStack(alignment: .leading, spacing: 12) {
            if !folderManager.folders.isEmpty {
                HStack {
                    Text("Videos")
                        .font(isLandscape ? .subheadline : .headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            
            if viewMode == .grid {
                createVideosGrid(videos, geometry: geometry)
            } else {
                createVideosList(videos)
            }
        }
    }
    
    // MARK: - Folder Views
    
    func createFoldersList(_ folders: [FolderMetadata]) -> some View {
        VStack(spacing: 8) {
            ForEach(folders, id: \.id) { folder in
                FolderRowView(
                    folder: folder,
                    onTap: { folderManager.navigateToFolder(folder.path) },
                    onRename: { newName in
                        Task {
                            try await folderManager.renameFolder(folder, to: newName)
                        }
                    },
                    onDelete: {
                        Task {
                            try await folderManager.deleteFolder(folder)
                        }
                    }
                )
            }
        }
    }
    
    func createFoldersGrid(_ folders: [FolderMetadata], geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let columnCount = isLandscape ? 3 : 2 // More columns in landscape
        
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 12) {
            ForEach(folders, id: \.id) { folder in
                FolderCardView(
                    folder: folder,
                    onTap: { folderManager.navigateToFolder(folder.path) },
                    onRename: { newName in
                        Task {
                            try await folderManager.renameFolder(folder, to: newName)
                        }
                    },
                    onDelete: {
                        Task {
                            try await folderManager.deleteFolder(folder)
                        }
                    }
                )
            }
        }
    }
    
    // MARK: - Video Views
    
    func createVideosList(_ videos: [VideoMetadata]) -> some View {
        VStack(spacing: 8) {
            ForEach(videos, id: \.id) { video in
                StoredVideo(
                    videoMetadata: video,
                    mediaStore: folderManager.store,
                    onDelete: {
                        Task {
                            try await folderManager.deleteVideo(video)
                        }
                    },
                    onRefresh: {
                        folderManager.refreshContents()
                    },
                    onRename: { newName in
                        Task {
                            try await folderManager.renameVideo(video, to: newName)
                        }
                    },
                    onMove: { targetFolder in
                        Task {
                            try await folderManager.moveVideoToFolder(video, targetFolderPath: targetFolder)
                        }
                    },
                    isSelectable: false,
                    isSelected: false,
                    onSelectionToggle: nil
                )
            }
        }
    }
    
    func createVideosGrid(_ videos: [VideoMetadata], geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let columnCount = isLandscape ? 3 : 2 // More columns in landscape
        
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 12) {
            ForEach(videos, id: \.id) { video in
                VideoCardView(
                    video: video,
                    mediaStore: folderManager.store,
                    onDelete: {
                        Task {
                            try await folderManager.deleteVideo(video)
                        }
                    },
                    onRefresh: {
                        folderManager.refreshContents()
                    },
                    onRename: { newName in
                        Task {
                            try await folderManager.renameVideo(video, to: newName)
                        }
                    },
                    onMove: { targetFolder in
                        Task {
                            try await folderManager.moveVideoToFolder(video, targetFolderPath: targetFolder)
                        }
                    },
                    isSelectable: false,
                    isSelected: false,
                    onSelectionToggle: nil
                )
            }
        }
    }

    func createEmptyState() -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text(searchText.isEmpty ? "No content in this folder yet." : "No matching content found.")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
    }
    
    // MARK: - Filtering Functions
    
    func getFilteredFolders() -> [FolderMetadata] {
        if searchText.isEmpty {
            // No search - show folders from current directory
            return folderManager.getSortedFolders(by: sortOption.folderSort)
        } else {
            // Search active - search across ALL folders
            return folderManager.store.searchFolders(query: searchText)
                .sorted { folder1, folder2 in
                    switch sortOption.folderSort {
                    case .name:
                        return folder1.name.localizedCaseInsensitiveCompare(folder2.name) == .orderedAscending
                    case .dateCreated:
                        return folder1.createdDate < folder2.createdDate
                    case .dateModified:
                        return folder1.modifiedDate < folder2.modifiedDate
                    case .videoCount:
                        return folder1.videoCount < folder2.videoCount
                    }
                }
        }
    }
    
    func getFilteredVideos() -> [VideoMetadata] {
        if searchText.isEmpty {
            // No search - show only videos from current folder
            return folderManager.getSortedVideos(by: sortOption.videoSort)
        } else {
            // Search active - search across ALL folders
            return folderManager.store.searchVideos(query: searchText)
                .sorted { video1, video2 in
                    switch sortOption.videoSort {
                    case .name:
                        return video1.displayName.localizedCaseInsensitiveCompare(video2.displayName) == .orderedAscending
                    case .dateCreated:
                        return video1.createdDate < video2.createdDate
                    case .fileSize:
                        return video1.fileSize < video2.fileSize
                    }
                }
        }
    }
}

// MARK: - Breadcrumb Navigation
private extension LibraryView {
    func createBreadcrumbView() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(folderManager.getFolderHierarchy(), id: \.id) { breadcrumb in
                    Button {
                        folderManager.navigateToFolder(breadcrumb.path)
                    } label: {
                        HStack(spacing: 6) {
                            if breadcrumb.isRoot {
                                Image(systemName: "house.fill")
                                    .font(.subheadline)
                            }
                            Text(breadcrumb.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(breadcrumb.path == folderManager.currentPath ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            breadcrumb.path == folderManager.currentPath ? 
                            Color.blue.opacity(0.2) : Color.clear
                        )
                        .clipShape(Capsule())
                    }
                    
                    if breadcrumb.id != folderManager.getFolderHierarchy().last?.id {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Folder Creation
private extension LibraryView {
    func createFolderSheet() -> some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folder Name")
                        .font(.headline)
                    
                    TextField("Enter folder name", text: $newFolderName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit {
                            createFolder()
                        }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingCreateFolder = false
                        newFolderName = ""
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createFolder()
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    func createFolder() {
        Task {
            do {
                try await folderManager.createFolder(name: newFolderName.trimmingCharacters(in: .whitespacesAndNewlines))
                await MainActor.run {
                    showingCreateFolder = false
                    newFolderName = ""
                }
            } catch {
                // Handle error - could add error state here
                print("Failed to create folder: \(error)")
            }
        }
    }
}

