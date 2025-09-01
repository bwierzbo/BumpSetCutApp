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
    @State private var isShowingAdvancedSearch = false
    
    init(mediaStore: MediaStore) {
        self._folderManager = StateObject(wrappedValue: FolderManager(mediaStore: mediaStore))
        self._uploadCoordinator = StateObject(wrappedValue: UploadCoordinator(mediaStore: mediaStore))
        self._searchViewModel = StateObject(wrappedValue: SearchViewModel(mediaStore: mediaStore))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isShowingAdvancedSearch {
                    // Advanced search interface
                    AdvancedSearchView(
                        searchViewModel: searchViewModel,
                        onNavigateToFolder: { path in
                            folderManager.navigateToFolder(path)
                            isShowingAdvancedSearch = false
                        },
                        onNavigateToVideo: { video in
                            // Navigate to the video's folder first
                            folderManager.navigateToFolder(video.folderPath)
                            isShowingAdvancedSearch = false
                        }
                    )
                } else {
                    // Normal library view
                    if !folderManager.currentPath.isEmpty {
                        createBreadcrumbView()
                    }
                    
                    DropZoneView(uploadCoordinator: uploadCoordinator, destinationFolder: folderManager.currentPath) {
                        createScrollableView()
                    }
                    
                    // Upload status bar
                    UploadStatusBar(uploadCoordinator: uploadCoordinator)
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showingCreateFolder) {
                createFolderSheet()
            }
            .searchable(
                text: $searchText, 
                isPresented: $isShowingAdvancedSearch,
                prompt: "Search videos and folders"
            )
            .onChange(of: isShowingAdvancedSearch) { isShowing in
                if isShowing {
                    searchViewModel.searchText = searchText
                } else {
                    searchText = ""
                    searchViewModel.clearSearch()
                }
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
        ScrollView {
            createMediaView()
        }
        .navigationTitle(folderManager.currentPath.isEmpty ? "Library" : folderManager.currentPath.split(separator: "/").last?.description ?? "Library")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbar(content: createToolbar)
        .refreshable {
            folderManager.refreshContents()
        }
    }
}

// MARK: - Breadcrumb Navigation
private extension LibraryView {
    func createBreadcrumbView() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(folderManager.getFolderHierarchy(), id: \.id) { breadcrumb in
                    Button {
                        folderManager.navigateToFolder(breadcrumb.path)
                    } label: {
                        HStack(spacing: 4) {
                            if breadcrumb.isRoot {
                                Image(systemName: "house.fill")
                                    .font(.caption)
                            }
                            Text(breadcrumb.name)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(breadcrumb.path == folderManager.currentPath ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            breadcrumb.path == folderManager.currentPath ? 
                            Color.blue.opacity(0.2) : Color.clear
                        )
                        .clipShape(Capsule())
                    }
                    
                    if breadcrumb.id != folderManager.getFolderHierarchy().last?.id {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Toolbar
private extension LibraryView {
    func createToolbar() -> some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarLeading) {
                if folderManager.canNavigateUp() {
                    Button {
                        folderManager.navigateToParent()
                    } label: {
                        Image(systemName: "chevron.left")
                            .fontWeight(.medium)
                    }
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Advanced search button
                    Button {
                        isShowingAdvancedSearch.toggle()
                    } label: {
                        Image(systemName: isShowingAdvancedSearch ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                            .fontWeight(.medium)
                            .foregroundColor(isShowingAdvancedSearch ? .blue : .primary)
                    }
                    
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
                            .fontWeight(.medium)
                    }
                    
                    Button {
                        showingCreateFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .fontWeight(.medium)
                    }
                    
                    EnhancedUploadButton(
                        uploadCoordinator: uploadCoordinator,
                        destinationFolder: folderManager.currentPath
                    )
                }
            }
        }
    }
}

// MARK: - Media View
private extension LibraryView {
    func createMediaView() -> some View {
        LazyVStack(spacing: 16) {
            createMediaHeader()
            
            if folderManager.isLoading {
                ProgressView("Loading...")
                    .padding()
            } else {
                createContent()
            }
        }
        .padding()
    }
}

// MARK: - Header
private extension LibraryView {
    func createMediaHeader() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(folderManager.currentPath.isEmpty ? "Your Library" : "Contents")
                    .font(.title2)
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
    func createContent() -> some View {
        let filteredFolders = getFilteredFolders()
        let filteredVideos = getFilteredVideos()
        
        if filteredFolders.isEmpty && filteredVideos.isEmpty {
            return AnyView(createEmptyState())
        }
        
        return AnyView(
            VStack(spacing: 16) {
                // Display folders first
                if !filteredFolders.isEmpty {
                    createFoldersSection(filteredFolders)
                }
                
                // Then display videos
                if !filteredVideos.isEmpty {
                    createVideosSection(filteredVideos)
                }
            }
        )
    }
    
    func createFoldersSection(_ folders: [FolderMetadata]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !folderManager.videos.isEmpty {
                HStack {
                    Text("Folders")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            
            if viewMode == .grid {
                createFoldersGrid(folders)
            } else {
                createFoldersList(folders)
            }
        }
    }
    
    func createVideosSection(_ videos: [VideoMetadata]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !folderManager.folders.isEmpty {
                HStack {
                    Text("Videos")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            
            if viewMode == .grid {
                createVideosGrid(videos)
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
    
    func createFoldersGrid(_ folders: [FolderMetadata]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
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
                    videoURL: video.originalURL,
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
    
    func createVideosGrid(_ videos: [VideoMetadata]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
            ForEach(videos, id: \.id) { video in
                VideoCardView(
                    video: video,
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
        let sorted = folderManager.getSortedFolders(by: sortOption.folderSort)
        
        if searchText.isEmpty {
            return sorted
        }
        
        return sorted.filter { folder in
            folder.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    func getFilteredVideos() -> [VideoMetadata] {
        let sorted = folderManager.getSortedVideos(by: sortOption.videoSort)
        
        if searchText.isEmpty {
            return sorted
        }
        
        return sorted.filter { video in
            video.displayName.localizedCaseInsensitiveContains(searchText) ||
            video.fileName.localizedCaseInsensitiveContains(searchText)
        }
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

