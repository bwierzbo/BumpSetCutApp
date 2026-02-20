import SwiftUI
import PhotosUI

// MARK: - HomeView
/// Main home screen with hero section, stats, and navigation
struct HomeView: View {
    // MARK: - Properties
    let mediaStore: MediaStore
    let metadataStore: MetadataStore

    @State private var viewModel: HomeViewModel?
    @State private var showingSettings = false
    @Environment(AppSettings.self) private var appSettings
    @Environment(AuthenticationService.self) private var authService

    @State private var hasAppeared = false

    // Upload state
    @State private var uploadCoordinator: UploadCoordinator?
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingUploadItems: [PhotosPickerItem] = []
    @State private var showingFolderSelection = false
    @State private var videoNameInput = ""

    // Process state
    @State private var showingProcessPicker = false

    // Onboarding state
    @State private var showingOnboarding = false

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isLandscape: Bool { verticalSizeClass == .compact }

    // MARK: - Body
    var body: some View {
        GeometryReader { geometry in
            let contentWidth = isLandscape
                ? min(geometry.size.width * 0.45, 500)
                : min(geometry.size.width * 0.85, 400)

            ZStack {
                // Background
                backgroundGradient

                if isLandscape {
                    landscapeContent(contentWidth: contentWidth, geometry: geometry)
                } else {
                    portraitContent(contentWidth: contentWidth)
                }

                // Upload progress overlay
                if let coordinator = uploadCoordinator, coordinator.isUploadInProgress {
                    uploadProgressOverlay(coordinator)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsButton
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environment(appSettings)
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 1,
            matching: .videos
        )
        .onChange(of: selectedPhotoItems) { _, items in
            if let item = items.first {
                pendingUploadItems = [item]
                selectedPhotoItems.removeAll()
                showingFolderSelection = true
            }
        }
        .sheet(isPresented: $showingFolderSelection) {
            UploadFolderSelectionSheet(
                mediaStore: mediaStore,
                onFolderSelected: { folderPath in
                    if let coordinator = uploadCoordinator, let item = pendingUploadItems.first {
                        coordinator.handlePhotosPickerItem(item, destinationFolder: folderPath)
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
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                showingOnboarding = false
                appSettings.hasCompletedOnboarding = true
            }
        }
        .onAppear {
            // Initialize dependencies asynchronously to avoid blocking
            if viewModel == nil {
                viewModel = HomeViewModel(mediaStore: mediaStore, metadataStore: metadataStore)
            }
            if uploadCoordinator == nil {
                uploadCoordinator = UploadCoordinator(mediaStore: mediaStore)
            }

            // Delay animation start to let view finish initial layout
            // This prevents laggy/jumpy intro animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    hasAppeared = true
                }
            }

            // Show onboarding on first launch
            if !appSettings.hasCompletedOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingOnboarding = true
                }
            }
        }
        .alert("Storage Full", isPresented: Binding(
            get: { uploadCoordinator?.showStorageWarning ?? false },
            set: { uploadCoordinator?.showStorageWarning = $0 }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadCoordinator?.storageWarningMessage ?? "Not enough storage space")
        }
        .alert("Name Your Video", isPresented: Binding(
            get: { uploadCoordinator?.showNamingDialog ?? false },
            set: { if !$0 && (uploadCoordinator?.showNamingDialog ?? false) { uploadCoordinator?.completeNaming(customName: nil) } }
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
                uploadCoordinator?.completeNaming(customName: videoNameInput)
                videoNameInput = ""
            }
            .disabled(videoNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Skip", role: .cancel) {
                uploadCoordinator?.completeNaming(customName: nil)
                videoNameInput = ""
            }
        } message: {
            Text("Give your video a custom name")
        }
    }

    // MARK: - Upload Progress Overlay

    private func uploadProgressOverlay(_ coordinator: UploadCoordinator) -> some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: BSCSpacing.lg) {
                if coordinator.showCompleted {
                    // Completion state
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.bscSuccess)
                        .transition(.scale.combined(with: .opacity))

                    Text("Upload Complete!")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.bscTextPrimary)
                } else {
                    // Progress state
                    ProgressView()
                        .scaleEffect(1.3)
                        .tint(.bscPrimary)

                    VStack(spacing: BSCSpacing.sm) {
                        if !coordinator.uploadProgressText.isEmpty {
                            Text(coordinator.uploadProgressText)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.bscTextPrimary)
                        } else {
                            Text("Importing video...")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.bscTextPrimary)
                        }

                        if !coordinator.currentFileSize.isEmpty {
                            Text(coordinator.currentFileSize)
                                .font(.system(size: 12))
                                .foregroundColor(.bscTextTertiary)
                        }

                        if coordinator.elapsedTime > 2 {
                            Text(formatElapsedTime(coordinator.elapsedTime))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.bscTextTertiary)
                        }
                    }
                }
            }
            .padding(BSCSpacing.xl)
            .padding(.horizontal, BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                    .fill(Color.bscBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .animation(.bscSpring, value: coordinator.showCompleted)
    }

    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Portrait Layout
    private func portraitContent(contentWidth: CGFloat) -> some View {
        VStack(spacing: BSCSpacing.lg) {
            Spacer()

            HeroSection()

            Spacer()

            animatedContent(contentWidth: contentWidth)

            Spacer(minLength: BSCSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Landscape Layout
    private func landscapeContent(contentWidth: CGFloat, geometry: GeometryProxy) -> some View {
        HStack(spacing: BSCSpacing.xl) {
            // Left side: Hero
            HeroSection()
                .frame(maxWidth: geometry.size.width * 0.35, maxHeight: .infinity)

            // Right side: Stats + CTAs (scrollable)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: BSCSpacing.md) {
                    Spacer(minLength: BSCSpacing.md)
                    animatedContent(contentWidth: contentWidth)
                    Spacer(minLength: BSCSpacing.md)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Animated Content (shared between layouts)
    @ViewBuilder
    private func animatedContent(contentWidth: CGFloat) -> some View {
        if let viewModel = viewModel {
            StatsCard(
                stats: viewModel.stats(isPro: SubscriptionService.shared.isPro),
                isLoading: viewModel.isLoading
            )
            .accessibilityIdentifier(AccessibilityID.Home.statsCard)
            .frame(maxWidth: contentWidth)
            .opacity(hasAppeared ? 1 : 0)
            .offset(
                x: hasAppeared ? 0 : -30,
                y: hasAppeared ? 0 : -30
            )
            .animation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.1), value: hasAppeared)
        }

        VStack(spacing: BSCSpacing.sm) {
            mainCTAButton
            favoriteRalliesCTAButton
        }
        .frame(maxWidth: contentWidth)
        .opacity(hasAppeared ? 1 : 0)
        .offset(
            x: hasAppeared ? 0 : -40,
            y: hasAppeared ? 0 : -40
        )
        .animation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.2), value: hasAppeared)

        quickActionsSection
            .frame(maxWidth: contentWidth)
            .opacity(hasAppeared ? 1 : 0)
            .offset(
                x: hasAppeared ? 0 : -50,
                y: hasAppeared ? 0 : -50
            )
            .animation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.3), value: hasAppeared)
    }

    // MARK: - Background
    private var backgroundGradient: some View {
        ZStack {
            Color.bscBackground
                .ignoresSafeArea()

            // Subtle gradient orbs (hidden when reduce motion is on)
            if !reduceMotion {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.bscPrimary.opacity(0.08), Color.clear],
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
    }

    // MARK: - Main CTA Button
    private var mainCTAButton: some View {
        NavigationLink(destination: LibraryView(mediaStore: mediaStore)) {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24, weight: .semibold))

                Text("View Library")
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
            .bscShadow(BSCShadow.glowPrimary)
        }
        .buttonStyle(MainCTAButtonStyle())
        .accessibilityIdentifier(AccessibilityID.Home.viewLibrary)
        .accessibilityLabel("View Library")
        .accessibilityHint("Navigate to your video library")
    }

    // MARK: - Favorite Rallies CTA Button
    private var favoriteRalliesCTAButton: some View {
        NavigationLink(destination: FavoritesGridView(mediaStore: mediaStore)) {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "star.fill")
                    .font(.system(size: 20, weight: .semibold))

                Text("Favorite Rallies")
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
                    .stroke(Color.bscWarmAccent.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(MainCTAButtonStyle())
        .accessibilityIdentifier(AccessibilityID.Home.favoriteRallies)
        .accessibilityLabel("View Favorite Rallies")
        .accessibilityHint("Navigate to your favorite rally clips")
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
            .accessibilityLabel("Upload video")
            .accessibilityHint("Import a video from your photo library")
            .accessibilityIdentifier(AccessibilityID.Home.upload)

            // Process button - shows unprocessed video picker
            Button {
                showingProcessPicker = true
            } label: {
                quickActionContent(icon: "brain.head.profile", title: "Process", color: .bscTeal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Process video")
            .accessibilityHint("Detect rallies in an unprocessed video")
            .accessibilityIdentifier(AccessibilityID.Home.process)

            // Help button - shows onboarding tutorial
            Button {
                showingOnboarding = true
            } label: {
                quickActionContent(icon: "questionmark.circle", title: "Help", color: .bscTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help")
            .accessibilityHint("Show the onboarding tutorial")
            .accessibilityIdentifier(AccessibilityID.Home.help)
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
        .accessibilityIdentifier(AccessibilityID.Home.settings)
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

    @State private var selectedFolderPath: String
    @State private var folders: [FolderMetadata] = []
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""

    init(mediaStore: MediaStore, onFolderSelected: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.mediaStore = mediaStore
        self.onFolderSelected = onFolderSelected
        self.onCancel = onCancel
        // Start with library root selected
        self._selectedFolderPath = State(initialValue: LibraryType.saved.rootPath)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Folder list
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.xs) {
                            // Library root option
                            folderRow(name: "Library", path: LibraryType.saved.rootPath, icon: "house.fill", color: .bscBlue)

                            if !folders.isEmpty {
                                Divider()
                                    .background(Color.bscSurfaceBorder)
                                    .padding(.vertical, BSCSpacing.sm)

                                ForEach(folders, id: \.id) { folder in
                                    folderRow(name: folder.name, path: folder.path, icon: "folder.fill", color: .bscPrimary)
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
                            Text("Upload to \(selectedFolderPath == LibraryType.saved.rootPath ? "Library" : selectedFolderPath.components(separatedBy: "/").last ?? "Folder")")
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
                        .foregroundColor(.bscPrimary)
                }
            }
            .padding(BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(selectedFolderPath == path ? Color.bscPrimary.opacity(0.1) : Color.bscSurfaceGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(selectedFolderPath == path ? Color.bscPrimary.opacity(0.3) : Color.bscSurfaceBorder, lineWidth: 1)
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
                    .foregroundColor(.bscPrimary)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func loadFolders() {
        folders = getAllFoldersRecursively()
    }

    private func getAllFoldersRecursively() -> [FolderMetadata] {
        // Get all folders in the Saved Games library
        var allFolders: [FolderMetadata] = []
        var foldersToProcess: [String] = [LibraryType.saved.rootPath]

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

        // Create folder in Saved Games library root
        let success = mediaStore.createFolder(name: sanitizedName, parentPath: LibraryType.saved.rootPath)

        if success {
            selectedFolderPath = "\(LibraryType.saved.rootPath)/\(sanitizedName)"
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
    @State private var showingImportPicker = false
    @State private var selectedImportItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importedVideo: ImportedVideo?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.lg) {
                        // Import & Process button — always visible at top
                        importAndProcessButton

                        if unprocessedVideos.isEmpty && !isImporting {
                            VStack(spacing: BSCSpacing.lg) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(.bscTeal)

                                Text("All Caught Up!")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.bscTextPrimary)

                                Text("No unprocessed videos. Import a new one above.")
                                    .font(.system(size: 14))
                                    .foregroundColor(.bscTextSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, BSCSpacing.xl)
                        } else if !unprocessedVideos.isEmpty {
                            // Divider between import and existing videos
                            HStack {
                                Rectangle()
                                    .fill(Color.bscSurfaceBorder)
                                    .frame(height: 1)
                                Text("or select an existing video")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.bscTextTertiary)
                                Rectangle()
                                    .fill(Color.bscSurfaceBorder)
                                    .frame(height: 1)
                            }

                            LazyVStack(spacing: BSCSpacing.sm) {
                                ForEach(unprocessedVideos, id: \.id) { video in
                                    NavigationLink(destination: processVideoDestination(for: video)) {
                                        videoRow(video)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(BSCSpacing.lg)
                }

                if isImporting {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: BSCSpacing.md) {
                        ProgressView()
                            .tint(.bscPrimary)
                            .scaleEffect(1.2)
                        Text("Importing video...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.bscTextPrimary)
                    }
                    .padding(BSCSpacing.xl)
                    .background(Color.bscBackgroundElevated)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
                }
            }
            .navigationTitle("Process Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.bscTextSecondary)
                }
            }
            .photosPicker(
                isPresented: $showingImportPicker,
                selection: $selectedImportItems,
                maxSelectionCount: 1,
                matching: .videos
            )
            .onChange(of: selectedImportItems) { _, items in
                guard let item = items.first else { return }
                selectedImportItems.removeAll()
                Task { await importAndNavigate(item: item) }
            }
            .navigationDestination(item: $importedVideo) { video in
                ProcessVideoView(
                    videoURL: video.url,
                    mediaStore: mediaStore,
                    folderPath: LibraryType.saved.rootPath,
                    onComplete: { dismiss() }
                )
            }
            .onAppear {
                loadUnprocessedVideos()
            }
            .onChange(of: mediaStore.contentVersion) { _, _ in
                loadUnprocessedVideos()
            }
        }
    }

    // MARK: - Import & Process

    private var importAndProcessButton: some View {
        Button {
            showingImportPicker = true
        } label: {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 20, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Import New Video")
                        .font(.system(size: 16, weight: .bold))
                    Text("Add from Photos and process immediately")
                        .font(.system(size: 12))
                        .opacity(0.8)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.bscTextInverse)
            .padding(.vertical, BSCSpacing.md)
            .padding(.horizontal, BSCSpacing.lg)
            .background(LinearGradient.bscPrimaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .bscShadow(BSCShadow.glowPrimary)
        }
        .buttonStyle(MainCTAButtonStyle())
        .disabled(isImporting)
    }

    private func importAndNavigate(item: PhotosPickerItem) async {
        await MainActor.run { isImporting = true }

        do {
            guard let videoData = try await item.loadTransferable(type: VideoTransferable.self) else {
                await MainActor.run { isImporting = false }
                return
            }

            // Save to Saved Games root
            let success = mediaStore.addVideo(at: videoData.url, toFolder: LibraryType.saved.rootPath)

            await MainActor.run {
                isImporting = false
                if success {
                    // Find the just-added video and navigate to process it
                    if let added = mediaStore.getAllVideos(in: .saved)
                        .filter({ $0.canBeProcessed })
                        .last {
                        importedVideo = ImportedVideo(url: mediaStore.getVideoURL(for: added))
                    }
                }
            }
        } catch {
            await MainActor.run { isImporting = false }
        }
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
            // Video thumbnail
            VideoThumbnailView(
                thumbnailURL: nil,
                videoURL: mediaStore.getVideoURL(for: video)
            )
            .frame(width: 80, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

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

                        Text("\u{2022}")
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
        // Get IDs of originals that have processed versions pointing back to them
        let processedOriginalIds = Set(
            mediaStore.getAllVideos()
                .compactMap { $0.originalVideoId }
        )
        // Filter to truly unprocessed videos: canBeProcessed AND no processed video references this original
        unprocessedVideos = mediaStore.getAllVideos(in: .saved).filter {
            $0.canBeProcessed && !processedOriginalIds.contains($0.id)
        }
    }
}

// MARK: - Imported Video (Identifiable wrapper for navigation)
struct ImportedVideo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

// MARK: - Preview
#Preview("HomeView") {
    NavigationStack {
        HomeView(mediaStore: MediaStore(), metadataStore: MetadataStore())
    }
    .environment(AppSettings.shared)
}
