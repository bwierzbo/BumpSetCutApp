import SwiftUI
import PhotosUI

// MARK: - HomeView
/// Main home screen with hero section, stats, and navigation
struct HomeView: View {
    // MARK: - Properties
    @State private var mediaStore = MediaStore()
    @State private var metadataStore = MetadataStore()
    @State private var viewModel: HomeViewModel?
    @State private var showingSettings = false
    @EnvironmentObject private var appSettings: AppSettings

    @State private var hasAppeared = false

    // Upload state
    @State private var uploadCoordinator: UploadCoordinator?
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingUploadItems: [PhotosPickerItem] = []
    @State private var showingFolderSelection = false

    // Process state
    @State private var showingProcessPicker = false

    // MARK: - Body
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let contentWidth = min(geometry.size.width * 0.85, 400)

                ZStack {
                    // Background
                    backgroundGradient

                    // Content
                    VStack(spacing: BSCSpacing.lg) {
                        Spacer()

                        // Hero section
                        HeroSection()

                        Spacer()

                        // Stats card
                        if let viewModel = viewModel {
                            StatsCard(
                                stats: viewModel.stats,
                                isLoading: viewModel.isLoading
                            )
                            .frame(maxWidth: contentWidth)
                            .opacity(hasAppeared ? 1 : 0)
                            .animation(.bscSpring.delay(0.1), value: hasAppeared)
                        }

                        // Main CTAs
                        VStack(spacing: BSCSpacing.sm) {
                            mainCTAButton
                            processedGamesCTAButton
                        }
                        .frame(maxWidth: contentWidth)
                        .opacity(hasAppeared ? 1 : 0)
                        .animation(.bscSpring.delay(0.2), value: hasAppeared)

                        // Quick actions
                        quickActionsSection
                            .frame(maxWidth: contentWidth)
                            .opacity(hasAppeared ? 1 : 0)
                            .animation(.bscSpring.delay(0.3), value: hasAppeared)

                        Spacer(minLength: BSCSpacing.lg)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    settingsButton
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(appSettings)
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .videos
        )
        .onChange(of: selectedPhotoItems) { _, items in
            if !items.isEmpty {
                pendingUploadItems = items
                selectedPhotoItems.removeAll()
                showingFolderSelection = true
            }
        }
        .sheet(isPresented: $showingFolderSelection) {
            UploadFolderSelectionSheet(
                mediaStore: mediaStore,
                onFolderSelected: { folderPath in
                    if let coordinator = uploadCoordinator {
                        coordinator.handleMultiplePhotosPickerItems(pendingUploadItems, destinationFolder: folderPath)
                    }
                    pendingUploadItems.removeAll()
                    showingFolderSelection = false
                },
                onCancel: {
                    pendingUploadItems.removeAll()
                    showingFolderSelection = false
                }
            )
        }
        .sheet(isPresented: $showingProcessPicker) {
            UnprocessedVideoPickerSheet(mediaStore: mediaStore)
        }
        .onAppear {
            if viewModel == nil {
                viewModel = HomeViewModel(mediaStore: mediaStore, metadataStore: metadataStore)
            }
            if uploadCoordinator == nil {
                uploadCoordinator = UploadCoordinator(mediaStore: mediaStore)
            }
            withAnimation {
                hasAppeared = true
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Background
    private var backgroundGradient: some View {
        ZStack {
            Color.bscBackground
                .ignoresSafeArea()

            // Subtle gradient orbs
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscOrange.opacity(0.08), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .frame(width: 600, height: 600)
                .offset(x: -100, y: -200)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscBlue.opacity(0.05), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 250
                    )
                )
                .frame(width: 500, height: 500)
                .offset(x: 150, y: 300)
        }
    }

    // MARK: - Main CTA Button
    private var mainCTAButton: some View {
        NavigationLink(destination: LibraryView(mediaStore: mediaStore)) {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24, weight: .semibold))

                Text("View Saved Games")
                    .font(.system(size: 18, weight: .bold))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.bscTextInverse)
            .padding(.vertical, BSCSpacing.lg)
            .padding(.horizontal, BSCSpacing.xl)
            .background(LinearGradient.bscPrimaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .bscShadow(BSCShadow.glowOrange)
        }
        .buttonStyle(MainCTAButtonStyle())
        .accessibilityLabel("View Saved Games")
        .accessibilityHint("Navigate to your video library")
    }

    // MARK: - Processed Games CTA Button
    private var processedGamesCTAButton: some View {
        NavigationLink(destination: LibraryView(mediaStore: mediaStore, filterMode: .processedOnly)) {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .semibold))

                Text("View Processed Games")
                    .font(.system(size: 16, weight: .bold))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.bscTextPrimary)
            .padding(.vertical, BSCSpacing.md)
            .padding(.horizontal, BSCSpacing.lg)
            .background(Color.bscSurfaceGlass)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .stroke(Color.bscTeal.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(MainCTAButtonStyle())
        .accessibilityLabel("View Processed Games")
        .accessibilityHint("Navigate to processed videos")
    }

    // MARK: - Quick Actions
    private var quickActionsSection: some View {
        HStack(spacing: BSCSpacing.md) {
            // Upload button - opens photo picker
            Button {
                showingPhotoPicker = true
            } label: {
                quickActionContent(icon: "square.and.arrow.up", title: "Upload", color: .bscBlue)
            }
            .buttonStyle(.plain)

            // Process button - shows unprocessed video picker
            Button {
                showingProcessPicker = true
            } label: {
                quickActionContent(icon: "brain.head.profile", title: "Process", color: .bscTeal)
            }
            .buttonStyle(.plain)

            // Help button - will show onboarding (placeholder for now)
            Button {
                // TODO: Show onboarding tutorial
            } label: {
                quickActionContent(icon: "questionmark.circle", title: "Help", color: .bscTextSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func quickActionContent(
        icon: String,
        title: String,
        color: Color
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(color)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.bscTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BSCSpacing.md)
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        )
    }

    // MARK: - Settings Button
    private var settingsButton: some View {
        BSCIconButton(icon: "gearshape.fill", style: .glass, size: .compact) {
            showingSettings = true
        }
        .accessibilityLabel("Settings")
    }
}

// MARK: - Main CTA Button Style
private struct MainCTAButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.bscBounce, value: configuration.isPressed)
    }
}

// MARK: - Upload Folder Selection Sheet
struct UploadFolderSelectionSheet: View {
    let mediaStore: MediaStore
    let onFolderSelected: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedFolderPath: String = ""
    @State private var folders: [FolderMetadata] = []
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Folder list
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.xs) {
                            // Library root option
                            folderRow(name: "Library", path: "", icon: "house.fill", color: .bscBlue)

                            if !folders.isEmpty {
                                Divider()
                                    .background(Color.bscSurfaceBorder)
                                    .padding(.vertical, BSCSpacing.sm)

                                ForEach(folders, id: \.id) { folder in
                                    folderRow(name: folder.name, path: folder.path, icon: "folder.fill", color: .bscOrange)
                                }
                            }
                        }
                        .padding(BSCSpacing.lg)
                    }

                    // Action buttons
                    VStack(spacing: BSCSpacing.sm) {
                        Button {
                            onFolderSelected(selectedFolderPath)
                        } label: {
                            Text("Upload to \(selectedFolderPath.isEmpty ? "Library" : selectedFolderPath.components(separatedBy: "/").last ?? "Folder")")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.bscTextInverse)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(LinearGradient.bscPrimaryGradient)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }

                        Button {
                            showingCreateFolder = true
                        } label: {
                            Text("Create New Folder")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.bscTextSecondary)
                        }
                    }
                    .padding(BSCSpacing.lg)
                    .background(Color.bscBackgroundElevated)
                }
            }
            .navigationTitle("Choose Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(.bscTextSecondary)
                }
            }
            .sheet(isPresented: $showingCreateFolder) {
                createFolderSheet
            }
            .onAppear {
                loadFolders()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func folderRow(name: String, path: String, icon: String, color: Color) -> some View {
        Button {
            selectedFolderPath = path
        } label: {
            HStack(spacing: BSCSpacing.md) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.bscTextPrimary)

                    if !path.isEmpty {
                        Text(path)
                            .font(.system(size: 12))
                            .foregroundColor(.bscTextTertiary)
                    }
                }

                Spacer()

                if selectedFolderPath == path {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.bscOrange)
                }
            }
            .padding(BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(selectedFolderPath == path ? Color.bscOrange.opacity(0.1) : Color.bscSurfaceGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(selectedFolderPath == path ? Color.bscOrange.opacity(0.3) : Color.bscSurfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var createFolderSheet: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: BSCSpacing.xl) {
                    VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                        Text("Folder Name")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.bscTextSecondary)
                            .textCase(.uppercase)

                        TextField("Enter folder name", text: $newFolderName)
                            .textFieldStyle(.roundedBorder)
                    }

                    Spacer()
                }
                .padding(BSCSpacing.xl)
            }
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
                    Button("Create") {
                        createFolder()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.bscOrange)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func loadFolders() {
        folders = getAllFoldersRecursively()
    }

    private func getAllFoldersRecursively() -> [FolderMetadata] {
        var allFolders: [FolderMetadata] = []
        var foldersToProcess: [String] = [""]

        while !foldersToProcess.isEmpty {
            let currentPath = foldersToProcess.removeFirst()
            let foundFolders = mediaStore.getFolders(in: currentPath)

            allFolders.append(contentsOf: foundFolders)
            foldersToProcess.append(contentsOf: foundFolders.map { $0.path })
        }

        return allFolders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func createFolder() {
        let sanitizedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else { return }

        let success = mediaStore.createFolder(name: sanitizedName, parentPath: "")

        if success {
            selectedFolderPath = sanitizedName
            loadFolders()
        }

        showingCreateFolder = false
        newFolderName = ""
    }
}

// MARK: - Unprocessed Video Picker Sheet
struct UnprocessedVideoPickerSheet: View {
    let mediaStore: MediaStore

    @Environment(\.dismiss) private var dismiss
    @State private var unprocessedVideos: [VideoMetadata] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                if unprocessedVideos.isEmpty {
                    VStack(spacing: BSCSpacing.lg) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.bscTeal)

                        Text("All Caught Up!")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.bscTextPrimary)

                        Text("All your videos have been processed.")
                            .font(.system(size: 14))
                            .foregroundColor(.bscTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(BSCSpacing.xl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.sm) {
                            ForEach(unprocessedVideos, id: \.id) { video in
                                NavigationLink(destination: processVideoDestination(for: video)) {
                                    videoRow(video)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(BSCSpacing.lg)
                    }
                }
            }
            .navigationTitle("Select Video to Process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.bscTextSecondary)
                }
            }
            .onAppear {
                loadUnprocessedVideos()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func processVideoDestination(for video: VideoMetadata) -> some View {
        let videoURL = mediaStore.getVideoURL(for: video)
        return ProcessVideoView(
            videoURL: videoURL,
            mediaStore: mediaStore,
            folderPath: video.folderPath,
            onComplete: { dismiss() }
        )
    }

    private func videoRow(_ video: VideoMetadata) -> some View {
        HStack(spacing: BSCSpacing.md) {
            // Thumbnail placeholder
            ZStack {
                RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                    .fill(Color.bscSurfaceGlass)
                    .frame(width: 80, height: 50)

                Image(systemName: "video.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.bscTextTertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(video.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscTextPrimary)
                    .lineLimit(1)

                HStack(spacing: BSCSpacing.sm) {
                    if let duration = video.duration {
                        Text(formatDuration(duration))
                            .font(.system(size: 12))
                            .foregroundColor(.bscTextSecondary)

                        Text("•")
                            .foregroundColor(.bscTextTertiary)
                    }

                    Text(formatFileSize(video.fileSize))
                        .font(.system(size: 12))
                        .foregroundColor(.bscTextSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.bscTextTertiary)
        }
        .padding(BSCSpacing.md)
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        )
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func loadUnprocessedVideos() {
        unprocessedVideos = mediaStore.getAllVideos().filter { !$0.isProcessed }
    }
}

// MARK: - Preview
#Preview("HomeView") {
    HomeView()
        .environmentObject(AppSettings.shared)
}
