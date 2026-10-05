//
//  FavoritesGridView.swift
//  BumpSetCut
//
//  Profile-style grid of favorited rally clips with folder support.
//  Tap a thumbnail to enter full-screen vertical feed.
//

import SwiftUI
import AVFoundation
import CoreMedia

struct FavoritesGridView: View {
    let mediaStore: MediaStore

    @State private var folderManager: FolderManager
    @State private var selectedIndex: Int?
    @State private var videoToDelete: VideoMetadata?
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var moveTarget: VideoMetadata?
    // Persisted across launches (String-backed enum works with @AppStorage).
    @AppStorage("favorites.sortOption") private var sortOption: ContentSortOption = .dateCreated
    @State private var renameTarget: VideoMetadata?
    // Surfaces failures from fire-and-forget library mutations (rename/move/delete).
    @State private var mutationToast: BSCToastMessage?
    // Non-nil presents the stitched highlight-video export sheet.
    @State private var reelTarget: ReelTarget?
    // Non-nil presents the multi-rally community post sheet.
    @State private var carouselTarget: CarouselTarget?
    // Non-nil presents the clip picker (folders with more than 10 clips).
    @State private var clipPickerTarget: ClipPickerTarget?
    // Grid ⇄ list, persisted like the library's toggle.
    @AppStorage("favorites.viewMode") private var viewMode: ViewMode = .grid
    // First-visit feature tour.
    @State private var showOnboarding = false
    // Path of the folder pushed onto the enclosing navigation stack.
    @State private var openedFolderPath: String?

    struct ReelTarget: Identifiable {
        let id = UUID()
        let folderName: String
        let clips: [VideoExporter.StitchClip]
    }

    struct CarouselTarget: Identifiable {
        let id = UUID()
        let title: String
        let clips: [FavoriteShareClip]
    }

    struct ClipPickerTarget: Identifiable {
        let id = UUID()
        let title: String
        let clips: [FavoriteShareClip]
    }

    /// `folderPath` nil shows the favorites root; a folder opens as another
    /// pushed FavoritesGridView, so back/edge-swipe are the system's.
    init(mediaStore: MediaStore, folderPath: String? = nil) {
        self.mediaStore = mediaStore
        let manager = FolderManager(mediaStore: mediaStore, libraryType: .favorites)
        if let folderPath {
            // Contents load lazily on appear (loadInitialContentsIfNeeded).
            manager.currentPath = folderPath
        }
        self._folderManager = State(wrappedValue: manager)
    }

    private var folders: [FolderMetadata] {
        folderManager.getSortedFolders(by: sortOption.folderSort)
    }

    private var videos: [VideoMetadata] {
        folderManager.getSortedVideos(by: sortOption.videoSort)
    }

    private var title: String {
        if folderManager.isAtLibraryRoot {
            return "Favorite Rallies"
        }
        return folderManager.currentPath.components(separatedBy: "/").last ?? "Favorites"
    }

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: BSCSpacing.md) {
                    header

                    if folders.isEmpty && videos.isEmpty {
                        BSCEmptyState(
                            icon: "star",
                            title: "No Favorites Yet",
                            message: "Favorite rallies from the rally viewer to see them here."
                        )
                        .accessibilityIdentifier(AccessibilityID.Favorites.emptyState)
                        .padding(.top, BSCSpacing.xxl)
                    } else {
                        // Same structure as the library: labeled sections,
                        // "Rallies" standing in for "Videos".
                        if !folders.isEmpty {
                            sectionHeader("Folders")
                            foldersSection
                        }
                        if !videos.isEmpty {
                            sectionHeader("Rallies")
                            if viewMode == .grid {
                                videosGrid
                                    .transition(.opacity)
                            } else {
                                videosList
                                    .transition(.opacity)
                            }
                        }
                    }
                }
                .padding(.top, BSCSpacing.md)
                .animation(.bscStandard, value: viewMode)
            }

            // First-visit feature tour
            if showOnboarding {
                FavoritesTipsOverlay {
                    showOnboarding = false
                    AppSettings.shared.hasSeenFavoritesOnboarding = true
                }
                .zIndex(100)
                .transition(.opacity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .bscToast($mutationToast)
        .navigationDestination(item: $openedFolderPath) { path in
            FavoritesGridView(mediaStore: mediaStore, folderPath: path)
        }
        .onAppear {
            folderManager.loadInitialContentsIfNeeded()
            if !AppSettings.shared.hasSeenFavoritesOnboarding {
                withAnimation(.bscStandard.delay(0.4)) {
                    showOnboarding = true
                }
            }
        }
        .onChange(of: mediaStore.contentVersion) { _, _ in
            folderManager.refreshContents()
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedIndex != nil },
            set: { if !$0 { selectedIndex = nil } }
        )) {
            if let index = selectedIndex {
                FavoritesFeedView(
                    videos: videos,
                    startIndex: index,
                    onDismiss: { selectedIndex = nil }
                )
            }
        }
        .sheet(isPresented: $showingCreateFolder) {
            createFolderSheet
        }
        .sheet(item: $moveTarget) { video in
            folderPickerSheet(for: video)
        }
        .sheet(item: $reelTarget) { target in
            FolderReelExportSheet(
                folderName: target.folderName,
                clips: target.clips
            )
        }
        .sheet(item: $carouselTarget) { target in
            ShareRallySheet(favoriteClips: target.clips, title: target.title)
        }
        .sheet(item: $clipPickerTarget) { target in
            ClipPickerSheet(
                title: target.title,
                items: target.clips.map { clip in
                    ClipPickerItem(
                        id: clip.id,
                        payload: clip,
                        url: clip.url,
                        timeRange: clip.timeRange,
                        displayName: clip.displayName,
                        duration: clip.duration
                    )
                },
                maxSelection: ShareRallyViewModel.maxClipsPerPost,
                confirmTitle: { "Post \($0) \($0 == 1 ? "Rally" : "Rallies")" },
                onConfirm: { selected in
                    clipPickerTarget = nil
                    guard !selected.isEmpty else { return }
                    // Let the picker sheet finish dismissing before presenting
                    // the next sheet (same pattern as alert-after-sheet).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        carouselTarget = CarouselTarget(title: target.title, clips: selected)
                    }
                },
                onCancel: { clipPickerTarget = nil }
            )
        }
        .alert("Remove Favorite?", isPresented: Binding(
            get: { videoToDelete != nil },
            set: { if !$0 { videoToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { videoToDelete = nil }
            Button("Remove", role: .destructive) {
                if let video = videoToDelete {
                    Task {
                        do {
                            // Sync unfavorite back to source video's review selections
                            if let srcVideoId = video.sourceVideoId,
                               let srcRallyIndex = video.sourceRallyIndex {
                                let metadataStore = MetadataStore.shared
                                var selections = metadataStore.loadReviewSelections(for: srcVideoId)
                                selections.favorited.remove(srcRallyIndex)
                                try metadataStore.saveReviewSelections(selections, for: srcVideoId)
                            }
                            try await folderManager.deleteVideo(video)
                        } catch {
                            mutationToast = BSCToastMessage(text: "Couldn't remove favorite", style: .error)
                        }
                    }
                    videoToDelete = nil
                }
            }
        } message: {
            Text("This rally will be removed from your favorites.")
        }
        .bscNameAlert(
            title: "Rename",
            message: "Enter a new name for this rally.",
            placeholder: "Name",
            initialText: renameTarget?.displayName ?? "",
            confirmTitle: "Rename",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ),
            onCommit: { name in
                if let video = renameTarget, let name {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Task {
                            do { try await folderManager.renameVideo(video, to: trimmed) }
                            catch { mutationToast = BSCToastMessage(text: "Couldn't rename video", style: .error) }
                        }
                    }
                }
                renameTarget = nil
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()
            Text("\(videos.count) \(videos.count == 1 ? "rally" : "rallies")")
                .bscFont(size: 13)
                .foregroundColor(.bscTextSecondary)
                .accessibilityIdentifier(AccessibilityID.Favorites.rallyCount)
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Section Header (library-style)

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .bscFont(size: 16, weight: .semibold)
            .foregroundColor(.bscTextSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Folders

    @ViewBuilder
    private var foldersSection: some View {
        if viewMode == .grid {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.sm), count: 2),
                spacing: BSCSpacing.sm
            ) {
                ForEach(folders, id: \.id) { folder in
                    folderCard(folder, displayMode: .grid)
                }
            }
            .padding(.horizontal, BSCSpacing.lg)
        } else {
            LazyVStack(spacing: BSCSpacing.sm) {
                ForEach(folders, id: \.id) { folder in
                    folderCard(folder, displayMode: .list)
                }
            }
            .padding(.horizontal, BSCSpacing.lg)
        }
    }

    private func folderCard(_ folder: FolderMetadata, displayMode: BSCFolderCard.DisplayMode) -> some View {
        BSCFolderCard(
            folder: folder,
            displayMode: displayMode,
            onTap: { openedFolderPath = folder.path },
            onRename: { newName in
                Task {
                    do { try await folderManager.renameFolder(folder, to: newName) }
                    catch { mutationToast = BSCToastMessage(text: "Couldn't rename folder", style: .error) }
                }
            },
            onDelete: {
                Task {
                    do { try await folderManager.deleteFolder(folder) }
                    catch { mutationToast = BSCToastMessage(text: "Couldn't delete folder", style: .error) }
                }
            },
            onExportHighlight: folder.videoCount > 0 ? {
                presentStitchExport(folderName: folder.name, videos: mediaStore.getVideos(in: folder.path))
            } : nil,
            onPostToCommunity: folder.videoCount > 0 ? {
                preparePost(title: folder.name, videos: mediaStore.getVideos(in: folder.path))
            } : nil
        )
        .dropDestination(for: VideoMetadata.self) { droppedVideos, _ in
            guard let video = droppedVideos.first else { return false }
            Task {
                do { try await folderManager.moveVideoToFolder(video, targetFolderPath: folder.path) }
                catch { mutationToast = BSCToastMessage(text: "Couldn't move video", style: .error) }
            }
            return true
        }
    }

    // MARK: - Videos Grid

    private var videosGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.xs), count: 3),
            spacing: BSCSpacing.xs
        ) {
            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                Button {
                    selectedIndex = index
                } label: {
                    gridCell(video)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(video.displayName)
                .accessibilityIdentifier("favorites.gridCell.\(index)")
                .draggable(video)
                .contextMenu {
                    clipContextMenu(for: video)
                }
            }
        }
        .padding(.horizontal, BSCSpacing.xs)
    }

    // MARK: - Videos List

    private var videosList: some View {
        LazyVStack(spacing: BSCSpacing.sm) {
            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                Button {
                    selectedIndex = index
                } label: {
                    listRow(video)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(video.displayName)
                .accessibilityIdentifier("favorites.listRow.\(index)")
                .draggable(video)
                .contextMenu {
                    clipContextMenu(for: video)
                }
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    private func listRow(_ video: VideoMetadata) -> some View {
        HStack(spacing: BSCSpacing.md) {
            VideoThumbnailView(thumbnailURL: nil, videoURL: video.originalURL)
                .frame(width: 88, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(video.displayName)
                    .bscFont(size: 15, weight: .medium)
                    .foregroundColor(.bscTextPrimary)
                    .lineLimit(1)

                HStack(spacing: BSCSpacing.xs) {
                    if let duration = video.duration {
                        Text(formatDuration(duration))
                            .bscFont(size: 12, design: .monospaced)
                    }
                    Text(video.createdDate.formatted(date: .abbreviated, time: .omitted))
                        .bscFont(size: 12)
                }
                .foregroundColor(.bscTextSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
        .padding(BSCSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .fill(Color.bscSurfaceGlass)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Clip Context Menu

    /// Shared clip actions (grid + list): manage, post as a single-rally
    /// community post, or save the clip (trim + watermark applied) to Photos.
    @ViewBuilder
    private func clipContextMenu(for video: VideoMetadata) -> some View {
        Button {
            renameTarget = video
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            moveTarget = video
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }

        Divider()

        Button {
            preparePost(title: video.displayName, videos: [video])
        } label: {
            Label("Post to Community", systemImage: "paperplane")
        }
        Button {
            presentStitchExport(folderName: video.displayName, videos: [video])
        } label: {
            Label("Save to Photos", systemImage: "square.and.arrow.down")
        }

        Divider()

        Button(role: .destructive) {
            videoToDelete = video
        } label: {
            Label("Remove Favorite", systemImage: "star.slash")
        }
    }

    private func gridCell(_ video: VideoMetadata) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                VideoThumbnailView(
                    thumbnailURL: nil,
                    videoURL: video.originalURL
                )
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()

                if let duration = video.duration {
                    Text(formatDuration(duration))
                        .bscFont(size: 10, weight: .medium, design: .monospaced)
                        .foregroundColor(.bscOnMedia)
                        .padding(.horizontal, BSCSpacing.xs)
                        .padding(.vertical, BSCSpacing.xxs)
                        .background(Color.bscMediaScrim)
                        .clipShape(Capsule())
                        .padding(BSCSpacing.xs)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: BSCSpacing.md) {
                // Sort + view menu, matching the library's control
                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(ContentSortOption.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: option.icon)
                                .tag(option)
                        }
                    }

                    Divider()

                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }
                } label: {
                    BSCIconButton(icon: "slider.horizontal.3", style: .ghost, size: .compact, accessibilityLabel: "Sort and view options") {}
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier(AccessibilityID.Favorites.sortMenu)

                if folderManager.isAtLibraryRoot {
                    BSCIconButton(icon: "folder.badge.plus", style: .ghost, size: .compact, accessibilityLabel: "Create new folder") {
                        showingCreateFolder = true
                    }
                    .accessibilityIdentifier(AccessibilityID.Favorites.createFolder)
                }

                // Folder actions — only inside a folder; the favorites root is
                // never posted or exported wholesale.
                if !folderManager.isAtLibraryRoot {
                    Menu {
                        Button {
                            preparePost(title: title, videos: videos)
                        } label: {
                            Label("Post to Community", systemImage: "paperplane")
                        }
                        Button {
                            presentStitchExport(folderName: title, videos: videos)
                        } label: {
                            Label("Export Highlight Video", systemImage: "film.stack")
                        }
                    } label: {
                        BSCIconButton(icon: "ellipsis", style: .ghost, size: .compact, accessibilityLabel: "Folder actions") {}
                            .allowsHitTesting(false)
                    }
                    .disabled(videos.isEmpty)
                    .accessibilityIdentifier(AccessibilityID.Favorites.folderMenu)
                }
            }
        }
    }

    // MARK: - Create Folder Sheet

    private var createFolderSheet: some View {
        NavigationStack {
            VStack(spacing: BSCSpacing.xl) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Folder Name")
                        .bscFont(size: 14, weight: .semibold)
                        .foregroundColor(.bscTextSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    TextField("Enter folder name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createFolder() }
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
                        showingCreateFolder = false
                        newFolderName = ""
                    }
                    .foregroundColor(.bscTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") { createFolder() }
                        .fontWeight(.semibold)
                        .foregroundColor(.bscPrimaryText)
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Folder Picker Sheet

    private func folderPickerSheet(for video: VideoMetadata) -> some View {
        NavigationStack {
            List {
                // Root option
                Button {
                    Task {
                        do { try await folderManager.moveVideoToFolder(video, targetFolderPath: LibraryType.favorites.rootPath) }
                        catch { mutationToast = BSCToastMessage(text: "Couldn't move video", style: .error) }
                        moveTarget = nil
                    }
                } label: {
                    Label("Favorites (Root)", systemImage: "star")
                }
                .disabled(video.folderPath == LibraryType.favorites.rootPath)

                // All folders in favorites library
                ForEach(mediaStore.getAllFolders(in: .favorites), id: \.id) { folder in
                    Button {
                        Task {
                            do { try await folderManager.moveVideoToFolder(video, targetFolderPath: folder.path) }
                            catch { mutationToast = BSCToastMessage(text: "Couldn't move video", style: .error) }
                            moveTarget = nil
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                    .disabled(video.folderPath == folder.path)
                }
            }
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { moveTarget = nil }
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
    }

    // MARK: - Highlight Reel & Posting

    /// Export Highlight Video: stitch everything into ONE video for Photos.
    /// No clip-count or duration caps.
    private func presentStitchExport(folderName: String, videos: [VideoMetadata]) {
        Task {
            let clips = await FavoriteClipResolver.resolve(videos).map {
                VideoExporter.StitchClip(url: $0.video.originalURL, timeRange: $0.timeRange)
            }
            guard !clips.isEmpty else {
                mutationToast = BSCToastMessage(text: "No clips to stitch", style: .error)
                return
            }
            reelTarget = ReelTarget(folderName: folderName, clips: clips)
        }
    }

    /// Post to Community: ONE swipeable multi-rally post. Clips over the
    /// single-rally limit are skipped with a notice; folders with more than
    /// the per-post maximum open a picker to choose which clips to include.
    private func preparePost(title: String, videos: [VideoMetadata]) {
        Task {
            let all = await FavoriteClipResolver.shareClips(from: videos)
            let eligible = all.filter { $0.duration <= ShareRallyViewModel.maxDurationSeconds }
            let skipped = all.count - eligible.count

            guard !eligible.isEmpty else {
                mutationToast = BSCToastMessage(
                    text: all.isEmpty ? "No clips to post" : "All clips are over 1 minute",
                    style: .error
                )
                return
            }
            if skipped > 0 {
                mutationToast = BSCToastMessage(
                    text: "\(skipped) \(skipped == 1 ? "clip" : "clips") over 1 minute skipped",
                    style: .info
                )
            }

            // Folder posts always go through the picker (with Select All when
            // everything fits); a single clip posts directly.
            if eligible.count == 1 {
                carouselTarget = CarouselTarget(title: title, clips: eligible)
            } else {
                clipPickerTarget = ClipPickerTarget(title: title, clips: eligible)
            }
        }
    }

    // MARK: - Actions

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do { try await folderManager.createFolder(name: trimmed) }
            catch { mutationToast = BSCToastMessage(text: "Couldn't create folder", style: .error) }
            showingCreateFolder = false
            newFolderName = ""
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
