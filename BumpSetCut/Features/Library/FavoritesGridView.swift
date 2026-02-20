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
    @State private var sortOption: ContentSortOption = .dateCreated
    @State private var renameTarget: VideoMetadata?
    @State private var renameText: String = ""
    @Environment(\.dismiss) private var dismiss

    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        self._folderManager = State(wrappedValue: FolderManager(mediaStore: mediaStore, libraryType: .favorites))
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
                        if !folders.isEmpty {
                            foldersSection
                        }
                        if !videos.isEmpty {
                            videosGrid
                        }
                    }
                }
                .padding(.top, BSCSpacing.md)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!folderManager.isAtLibraryRoot)
        .toolbar { toolbarContent }
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
        .alert("Remove Favorite?", isPresented: Binding(
            get: { videoToDelete != nil },
            set: { if !$0 { videoToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { videoToDelete = nil }
            Button("Remove", role: .destructive) {
                if let video = videoToDelete {
                    Task {
                        // Sync unfavorite back to source video's review selections
                        if let srcVideoId = video.sourceVideoId,
                           let srcRallyIndex = video.sourceRallyIndex {
                            let metadataStore = MetadataStore()
                            var selections = metadataStore.loadReviewSelections(for: srcVideoId)
                            selections.favorited.remove(srcRallyIndex)
                            try? metadataStore.saveReviewSelections(selections, for: srcVideoId)
                        }
                        try? await folderManager.deleteVideo(video)
                    }
                    videoToDelete = nil
                }
            }
        } message: {
            Text("This rally will be removed from your favorites.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let video = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Task { try? await folderManager.renameVideo(video, to: trimmed) }
                    }
                    renameTarget = nil
                }
            }
        } message: {
            Text("Enter a new name for this rally.")
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let h = value.translation.width
                    let v = abs(value.translation.height)
                    if h > 60 && h > v * 1.5 && !folderManager.isAtLibraryRoot {
                        withAnimation(.bscSpring) { folderManager.navigateToParent() }
                    }
                }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()
            Text("\(videos.count) \(videos.count == 1 ? "rally" : "rallies")")
                .font(.system(size: 13))
                .foregroundColor(.bscTextSecondary)
                .accessibilityIdentifier(AccessibilityID.Favorites.rallyCount)
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Folders

    private var foldersSection: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.sm), count: 2),
            spacing: BSCSpacing.sm
        ) {
            ForEach(folders, id: \.id) { folder in
                BSCFolderCard(
                    folder: folder,
                    displayMode: .grid,
                    onTap: {
                        withAnimation(.bscSpring) {
                            folderManager.navigateToFolder(folder.path)
                        }
                    },
                    onRename: { newName in
                        Task { try? await folderManager.renameFolder(folder, to: newName) }
                    },
                    onDelete: {
                        Task { try? await folderManager.deleteFolder(folder) }
                    }
                )
                .dropDestination(for: VideoMetadata.self) { droppedVideos, _ in
                    guard let video = droppedVideos.first else { return false }
                    Task {
                        try? await folderManager.moveVideoToFolder(video, targetFolderPath: folder.path)
                    }
                    return true
                }
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
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
                .draggable(video)
                .contextMenu {
                    Button {
                        renameText = video.displayName
                        renameTarget = video
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        moveTarget = video
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        videoToDelete = video
                    } label: {
                        Label("Remove Favorite", systemImage: "star.slash")
                    }
                }
            }
        }
        .padding(.horizontal, BSCSpacing.xs)
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
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(4)
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
        if !folderManager.isAtLibraryRoot {
            ToolbarItem(placement: .navigationBarLeading) {
                BSCIconButton(icon: "chevron.left", style: .ghost, size: .compact) {
                    withAnimation(.bscSpring) { folderManager.navigateToParent() }
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: BSCSpacing.md) {
                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(ContentSortOption.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: option.icon)
                                .tag(option)
                        }
                    }
                } label: {
                    BSCIconButton(icon: "arrow.up.arrow.down", style: .ghost, size: .compact) {}
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier(AccessibilityID.Favorites.sortMenu)

                BSCIconButton(icon: "folder.badge.plus", style: .ghost, size: .compact) {
                    showingCreateFolder = true
                }
                .accessibilityIdentifier(AccessibilityID.Favorites.createFolder)
            }
        }
    }

    // MARK: - Create Folder Sheet

    private var createFolderSheet: some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xl) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Folder Name")
                        .font(.system(size: 14, weight: .semibold))
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
                        .foregroundColor(.bscPrimary)
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Folder Picker Sheet

    private func folderPickerSheet(for video: VideoMetadata) -> some View {
        NavigationView {
            List {
                // Root option
                Button {
                    Task {
                        try? await folderManager.moveVideoToFolder(video, targetFolderPath: LibraryType.favorites.rootPath)
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
                            try? await folderManager.moveVideoToFolder(video, targetFolderPath: folder.path)
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

    // MARK: - Actions

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            try? await folderManager.createFolder(name: trimmed)
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

// MARK: - Full-Screen Feed

struct FavoritesFeedView: View {
    let videos: [VideoMetadata]
    let startIndex: Int
    let onDismiss: () -> Void

    @State private var currentIndex: Int?
    @State private var hasScrolledToStart = false
    @State private var players: [Int: AVPlayer] = [:]
    @State private var loopObservers: [Int: Any] = [:]
    @State private var boundaryObservers: [Int: Any] = [:]

    // Tap-to-pause
    @State private var isPaused = false

    // Trim
    @State private var isTrimmingMode = false
    @State private var trimBefore: Double = 0
    @State private var trimAfter: Double = 0
    @State private var clipDuration: Double = 0
    @State private var savedTrims: [Int: RallyTrimAdjustment] = [:]

    var body: some View {
        ZStack {
            Color.bscMediaBackground.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                        videoCard(video: video, index: index)
                            .containerRelativeFrame(.vertical)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentIndex)
            .ignoresSafeArea()
            .allowsHitTesting(!isTrimmingMode)

            // Overlay
            if !isTrimmingMode {
                VStack {
                    HStack {
                        if videos.count > 1 {
                            Text("\((currentIndex ?? startIndex) + 1)/\(videos.count)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, BSCSpacing.sm)
                                .padding(.vertical, BSCSpacing.xs)
                                .background(.ultraThinMaterial.opacity(0.8))
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Button { onDismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.8))
                                .shadow(radius: 4)
                        }
                    }
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.top, BSCSpacing.md)

                    Spacer()

                    // Bottom: video name
                    HStack {
                        if let idx = currentIndex, idx < videos.count {
                            Text(videos[idx].displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.bottom, BSCSpacing.huge)
                }
            }

            // Pause icon
            if isPaused && !isTrimmingMode {
                Image(systemName: "play.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(radius: 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Trim overlay
            if isTrimmingMode {
                if let idx = currentIndex, idx < videos.count {
                    RallyTrimOverlay(
                        trimBefore: $trimBefore,
                        trimAfter: $trimAfter,
                        rallyStartTime: 0,
                        rallyEndTime: clipDuration,
                        videoURL: videos[idx].originalURL,
                        videoDuration: clipDuration,
                        onScrub: { time in
                            if let player = players[idx] {
                                player.seek(to: CMTimeMakeWithSeconds(time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        },
                        onConfirm: { confirmTrim() },
                        onCancel: { cancelTrim() }
                    )
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            if !hasScrolledToStart {
                currentIndex = startIndex
                hasScrolledToStart = true
            }
        }
        .onChange(of: currentIndex) { oldIdx, newIdx in
            if let old = oldIdx { players[old]?.pause() }
            isPaused = false
            isTrimmingMode = false
            if let new = newIdx { setupPlayer(at: new) }
        }
        .onDisappear { teardownAll() }
    }

    // MARK: - Video Card

    private func videoCard(video: VideoMetadata, index: Int) -> some View {
        ZStack {
            VideoThumbnailView(
                thumbnailURL: nil,
                videoURL: video.originalURL,
                contentMode: .fit
            )

            if let player = players[index] {
                CustomVideoPlayerView(
                    player: player,
                    gravity: .resizeAspect,
                    onReadyForDisplay: { _ in }
                )
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isTrimmingMode, currentIndex == index else { return }
            togglePause()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard !isTrimmingMode, currentIndex == index else { return }
                    enterTrimMode(at: index)
                }
        )
        .onAppear { if currentIndex == index { setupPlayer(at: index) } }
    }

    // MARK: - Pause

    private func togglePause() {
        guard let idx = currentIndex, let player = players[idx] else { return }
        if isPaused {
            player.play()
        } else {
            player.pause()
        }
        withAnimation(.easeInOut(duration: 0.2)) { isPaused.toggle() }
    }

    // MARK: - Trim

    private func enterTrimMode(at index: Int) {
        guard index < videos.count else { return }

        // Pause playback
        players[index]?.pause()
        isPaused = false

        // Load clip duration
        let asset = AVURLAsset(url: videos[index].originalURL)
        Task {
            let duration = try? await asset.load(.duration)
            let secs = duration.map { CMTimeGetSeconds($0) } ?? 0
            clipDuration = max(secs, 0.1)

            // Load saved trim
            let videoId = videos[index].id
            let store = MetadataStore()
            let trims = store.loadTrimAdjustments(for: videoId)
            if let adj = trims[0] {
                trimBefore = adj.before
                trimAfter = adj.after
            } else {
                trimBefore = 0
                trimAfter = 0
            }

            withAnimation(.easeInOut(duration: 0.2)) { isTrimmingMode = true }
        }
    }

    private func confirmTrim() {
        guard let idx = currentIndex, idx < videos.count else { return }
        let videoId = videos[idx].id
        let adjustment = RallyTrimAdjustment(before: trimBefore, after: trimAfter)
        let store = MetadataStore()
        try? store.saveTrimAdjustments([0: adjustment], for: videoId)
        savedTrims[idx] = adjustment

        withAnimation(.easeInOut(duration: 0.2)) { isTrimmingMode = false }
        applyTrimAndPlay(at: idx)
    }

    private func cancelTrim() {
        withAnimation(.easeInOut(duration: 0.2)) { isTrimmingMode = false }
        if let idx = currentIndex {
            applyTrimAndPlay(at: idx)
        }
    }

    private func applyTrimAndPlay(at index: Int) {
        guard let player = players[index] else { return }
        let trim = savedTrims[index]

        // trimBefore > 0 means extend before start (not applicable for favorites clips starting at 0)
        // trimBefore < 0 means cut into clip from start
        // trimAfter > 0 means extend after end (not applicable)
        // trimAfter < 0 means cut from end
        let startTime = max(0, -(trim?.before ?? 0))
        let endTime = clipDuration + (trim?.after ?? 0)

        // Remove old boundary observer
        if let obs = boundaryObservers[index] {
            player.removeTimeObserver(obs)
            boundaryObservers[index] = nil
        }

        // Seek to trim start
        player.seek(to: CMTimeMakeWithSeconds(startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)

        // Add boundary observer for trim end
        if endTime < clipDuration - 0.05 {
            let boundary = CMTimeMakeWithSeconds(endTime, preferredTimescale: 600)
            let obs = player.addBoundaryTimeObserver(forTimes: [NSValue(time: boundary)], queue: .main) { [weak player] in
                player?.seek(to: CMTimeMakeWithSeconds(startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                player?.play()
            }
            boundaryObservers[index] = obs
        }

        player.play()
        isPaused = false
    }

    // MARK: - Player Management

    private func setupPlayer(at index: Int) {
        guard index < videos.count else { return }

        // Load saved trim for this clip
        if savedTrims[index] == nil {
            let store = MetadataStore()
            let trims = store.loadTrimAdjustments(for: videos[index].id)
            if let adj = trims[0] {
                savedTrims[index] = adj
            }
        }

        if let existing = players[index] {
            applyTrimAndPlay(at: index)
            return
        }

        let player = AVPlayer(url: videos[index].originalURL)
        player.isMuted = false
        player.automaticallyWaitsToMinimizeStalling = false

        // Load clip duration for trim
        let asset = AVURLAsset(url: videos[index].originalURL)
        Task {
            let duration = try? await asset.load(.duration)
            let secs = duration.map { CMTimeGetSeconds($0) } ?? 0
            if secs > 0 { clipDuration = secs }
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            let trim = savedTrims[index]
            let startTime = max(0, -(trim?.before ?? 0))
            player?.seek(to: CMTimeMakeWithSeconds(startTime, preferredTimescale: 600))
            player?.play()
        }
        loopObservers[index] = observer
        players[index] = player

        applyTrimAndPlay(at: index)
    }

    private func teardownAll() {
        for (idx, player) in players {
            if let obs = loopObservers[idx] {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = boundaryObservers[idx] {
                player.removeTimeObserver(obs)
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players.removeAll()
        loopObservers.removeAll()
        boundaryObservers.removeAll()
    }
}
