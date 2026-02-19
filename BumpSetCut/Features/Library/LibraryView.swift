//
//  LibraryView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import SwiftUI
import PhotosUI

// MARK: - LibraryView
struct LibraryView: View {
    // MARK: - Properties
    @State private var viewModel: LibraryViewModel
    @State private var hasAppeared = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var videoNameInput = ""
    @Environment(\.dismiss) private var dismiss

    init(mediaStore: MediaStore, libraryType: LibraryType = .saved) {
        self._viewModel = State(wrappedValue: LibraryViewModel(mediaStore: mediaStore, libraryType: libraryType))
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.bscBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Main content - only wrap with DropZoneView in saved library
                    if viewModel.libraryType == .saved {
                        DropZoneView(
                            uploadCoordinator: viewModel.uploadCoordinator,
                            destinationFolder: viewModel.currentPath
                        ) {
                            mainContent
                        }
                    } else {
                        mainContent
                    }

                    // Status bars
                    statusBars
                }
            }
            .sheet(isPresented: $viewModel.showingCreateFolder) {
                createFolderSheet
            }
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search videos and folders"
            )
            .onChange(of: viewModel.searchText) { _, newSearchText in
                viewModel.searchViewModel.searchText = newSearchText
            }
            .onReceive(NotificationCenter.default.publisher(for: .uploadCompleted)) { _ in
                viewModel.refresh()
            }
            .onChange(of: viewModel.folderManager.store.contentVersion) { _, _ in
                viewModel.refresh()
            }
            .onAppear {
                withAnimation(.bscSpring.delay(0.1)) {
                    hasAppeared = true
                }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 1,
                matching: .videos
            )
            .onChange(of: selectedPhotoItems) { _, items in
                if !items.isEmpty, let item = items.first {
                    viewModel.uploadCoordinator.handlePhotosPickerItem(item, destinationFolder: viewModel.currentPath)
                    selectedPhotoItems.removeAll()
                }
            }
            .alert("Storage Full", isPresented: Binding(
                get: { viewModel.uploadCoordinator.showStorageWarning },
                set: { viewModel.uploadCoordinator.showStorageWarning = $0 }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.uploadCoordinator.storageWarningMessage)
            }
            .alert("Name Your Video", isPresented: Binding(
                get: { viewModel.uploadCoordinator.showNamingDialog },
                set: { if !$0 { viewModel.uploadCoordinator.completeNaming(customName: nil) } }
            )) {
                TextField("Video name", text: $videoNameInput)
                    .onChange(of: videoNameInput) { _, newValue in
                        let stripped = String(newValue.drop(while: { $0.isWhitespace }))
                        let limited = String(stripped.prefix(100))
                        if limited != newValue {
                            videoNameInput = limited
                        }
                    }
                Button("Save") {
                    viewModel.uploadCoordinator.completeNaming(customName: videoNameInput)
                    videoNameInput = ""
                }
                .disabled(videoNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Skip", role: .cancel) {
                    viewModel.uploadCoordinator.completeNaming(customName: nil)
                    videoNameInput = ""
                }
            } message: {
                Text("Give your video a custom name")
            }
        }
    }
}

// MARK: - Main Content
private extension LibraryView {
    @ViewBuilder
    var emptyStateForLibraryType: some View {
        switch viewModel.libraryType {
        case .saved:
            BSCEmptyState.emptyFolder(onUpload: {
                showingPhotoPicker = true
            })
        case .processed:
            BSCEmptyState.noProcessedVideos(onViewLibrary: {
                dismiss()
            })
        }
    }

    var mainContent: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: BSCSpacing.lg) {
                    // Header
                    contentHeader(geometry: geometry)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(.bscSpring, value: hasAppeared)

                    // Content
                    contentBody(geometry: geometry)
                }
                .padding(geometry.size.width > geometry.size.height ? BSCSpacing.xl : BSCSpacing.lg)
            }
            .background(Color.bscBackground)
            .toolbar { toolbarContent }
            .navigationBarBackButtonHidden(!viewModel.isAtRoot)  // Hide default back when in folder
            .refreshable {
                viewModel.refresh()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        // Swipe right to go back
                        let horizontalDistance = value.translation.width
                        let verticalDistance = abs(value.translation.height)

                        // Trigger if swiped right and mostly horizontal (reduced threshold for easier swipe)
                        if horizontalDistance > 60 && horizontalDistance > verticalDistance * 1.5 {
                            if !viewModel.isAtRoot {
                                // In folder: go to parent folder
                                withAnimation(.bscSpring) {
                                    viewModel.navigateToParent()
                                }
                            } else {
                                // At root: dismiss to main screen
                                dismiss()
                            }
                        }
                    }
            )
        }
    }

    func contentHeader(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height

        return HStack {
            VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                Text(viewModel.title)
                    .font(.system(size: isLandscape ? 24 : 28, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                if !viewModel.subtitle.isEmpty {
                    Text(viewModel.subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.bscTextSecondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    func contentBody(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height

        if viewModel.isEmpty {
            if viewModel.searchText.isEmpty {
                emptyStateForLibraryType
                    .padding(.top, BSCSpacing.xxl)
            } else {
                BSCEmptyState.noSearchResults(query: viewModel.searchText, onClear: {
                    viewModel.clearSearch()
                })
                    .padding(.top, BSCSpacing.xxl)
            }
        } else {
            VStack(spacing: isLandscape ? BSCSpacing.md : BSCSpacing.lg) {
                // Folders section
                if !viewModel.filteredFolders.isEmpty {
                    foldersSection(geometry: geometry)
                }

                // Videos section
                if !viewModel.filteredVideos.isEmpty {
                    videosSection(geometry: geometry)
                }
            }
        }
    }
}

// MARK: - Folders Section
private extension LibraryView {
    func foldersSection(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height

        return VStack(alignment: .leading, spacing: BSCSpacing.md) {
            if viewModel.videoCount > 0 {
                sectionHeader("Folders", isLandscape: isLandscape)
            }

            if viewModel.viewMode == .grid {
                foldersGrid(geometry: geometry)
            } else {
                foldersList
            }
        }
    }

    var foldersList: some View {
        VStack(spacing: BSCSpacing.sm) {
            ForEach(viewModel.filteredFolders, id: \.id) { folder in
                BSCFolderCard(
                    folder: folder,
                    displayMode: .list,
                    onTap: {
                        withAnimation(.bscSpring) {
                            viewModel.navigateToFolder(folder.path)
                        }
                    },
                    onRename: { newName in
                        Task { try await viewModel.renameFolder(folder, to: newName) }
                    },
                    onDelete: {
                        Task { try await viewModel.deleteFolder(folder) }
                    }
                )
                .dropDestination(for: VideoMetadata.self) { videos, _ in
                    // Move dragged video to this folder
                    guard let video = videos.first else { return false }
                    Task {
                        try await viewModel.moveVideo(video, to: folder.path)
                    }
                    return true
                }
            }
        }
    }

    func foldersGrid(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let columns = Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.md), count: isLandscape ? 3 : 2)

        return LazyVGrid(columns: columns, spacing: BSCSpacing.md) {
            ForEach(viewModel.filteredFolders, id: \.id) { folder in
                BSCFolderCard(
                    folder: folder,
                    displayMode: .grid,
                    onTap: {
                        withAnimation(.bscSpring) {
                            viewModel.navigateToFolder(folder.path)
                        }
                    },
                    onRename: { newName in
                        Task { try await viewModel.renameFolder(folder, to: newName) }
                    },
                    onDelete: {
                        Task { try await viewModel.deleteFolder(folder) }
                    }
                )
                .dropDestination(for: VideoMetadata.self) { videos, _ in
                    // Move dragged video to this folder
                    guard let video = videos.first else { return false }
                    Task {
                        try await viewModel.moveVideo(video, to: folder.path)
                    }
                    return true
                }
            }
        }
    }
}

// MARK: - Videos Section
private extension LibraryView {
    func videosSection(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height

        return VStack(alignment: .leading, spacing: BSCSpacing.md) {
            if viewModel.folderCount > 0 {
                sectionHeader("Videos", isLandscape: isLandscape)
            }

            if viewModel.viewMode == .grid {
                videosGrid(geometry: geometry)
            } else {
                videosList
            }
        }
    }

    var videosList: some View {
        VStack(spacing: BSCSpacing.sm) {
            ForEach(viewModel.filteredVideos, id: \.id) { video in
                BSCVideoCard(
                    video: video,
                    mediaStore: viewModel.folderManager.store,
                    displayMode: .list,
                    onDelete: {
                        Task { try await viewModel.deleteVideo(video) }
                    },
                    onRefresh: { viewModel.refresh() },
                    onRename: { newName in
                        Task { try await viewModel.renameVideo(video, to: newName) }
                    },
                    onMove: { targetFolder in
                        Task { try await viewModel.moveVideo(video, to: targetFolder) }
                    },
                    libraryType: viewModel.libraryType
                )
                .draggable(video)  // Make videos draggable
            }
        }
    }

    func videosGrid(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let columns = Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.md), count: isLandscape ? 3 : 2)

        return LazyVGrid(columns: columns, spacing: BSCSpacing.md) {
            ForEach(viewModel.filteredVideos, id: \.id) { video in
                BSCVideoCard(
                    video: video,
                    mediaStore: viewModel.folderManager.store,
                    displayMode: .grid,
                    onDelete: {
                        Task { try await viewModel.deleteVideo(video) }
                    },
                    onRefresh: { viewModel.refresh() },
                    onRename: { newName in
                        Task { try await viewModel.renameVideo(video, to: newName) }
                    },
                    onMove: { targetFolder in
                        Task { try await viewModel.moveVideo(video, to: targetFolder) }
                    },
                    libraryType: viewModel.libraryType
                )
                .draggable(video)  // Make videos draggable
            }
        }
    }

    func sectionHeader(_ title: String, isLandscape: Bool) -> some View {
        Text(title)
            .font(.system(size: isLandscape ? 14 : 16, weight: .semibold))
            .foregroundColor(.bscTextSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - Status Bars
private extension LibraryView {
    var statusBars: some View {
        VStack(spacing: 0) {
            UploadStatusBar(uploadCoordinator: viewModel.uploadCoordinator)

            LoadingStatusBar(
                isLoading: viewModel.isLoading,
                message: "Loading content..."
            )
        }
    }
}

// MARK: - Toolbar
private extension LibraryView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // Custom back button when inside a folder
        if !viewModel.isAtRoot {
            ToolbarItem(placement: .navigationBarLeading) {
                BSCIconButton(icon: "chevron.left", style: .ghost, size: .compact) {
                    withAnimation(.bscSpring) {
                        viewModel.navigateToParent()
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: BSCSpacing.md) {
                // Sort/View menu
                Menu {
                    Picker("Sort", selection: $viewModel.sortOption) {
                        ForEach(ContentSortOption.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: option.icon)
                                .tag(option)
                        }
                    }

                    Divider()

                    Picker("View", selection: $viewModel.viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.bscTextSecondary)
                        .frame(width: 32, height: 32)
                }

                // Create folder - only at root (max depth = 1)
                if viewModel.isAtRoot {
                    BSCIconButton(icon: "folder.badge.plus", style: .ghost, size: .compact) {
                        viewModel.showingCreateFolder = true
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                // Upload - only in saved library
                if viewModel.libraryType == .saved {
                    EnhancedUploadButton(
                        uploadCoordinator: viewModel.uploadCoordinator,
                        destinationFolder: viewModel.currentPath
                    )
                }
            }
        }
    }
}

// MARK: - Create Folder Sheet
private extension LibraryView {
    var createFolderSheet: some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xl) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Folder Name")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.bscTextSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    TextField("Enter folder name", text: $viewModel.newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            createFolder()
                        }
                }

                Spacer()
            }
            .padding(BSCSpacing.xl)
            .background(Color.bscBackground)
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        viewModel.showingCreateFolder = false
                        viewModel.newFolderName = ""
                    }
                    .foregroundColor(.bscTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createFolder()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.bscOrange)
                    .disabled(viewModel.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    func createFolder() {
        Task {
            try await viewModel.createFolder()
        }
    }
}

// MARK: - Preview
#Preview("Saved Games Library") {
    LibraryView(mediaStore: MediaStore(), libraryType: .saved)
        .environmentObject(AppSettings.shared)
}

#Preview("Processed Games Library") {
    LibraryView(mediaStore: MediaStore(), libraryType: .processed)
        .environmentObject(AppSettings.shared)
}
