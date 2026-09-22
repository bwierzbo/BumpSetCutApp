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
    @Environment(AppNavigationState.self) private var navigationState

    @State private var hasAppeared = false

    // Upload state
    @Environment(UploadCoordinator.self) private var uploadCoordinator
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingUploadItems: [PhotosPickerItem] = []
    @State private var pendingDestinationFolder: String?
    @State private var showingFolderSelection = false
    @State private var showingNamePrompt = false

    // Process state
    @State private var showingProcessPicker = false

    // Onboarding state
    @State private var showingOnboarding = false

    // Social notifications
    @State private var showingNotifications = false

    // Direct messages
    @State private var showingInbox = false

    // Account-linked stats: sign-in prompt from the stats slot
    @State private var showingStatsSignIn = false

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isLandscape: Bool { verticalSizeClass == .compact }

    // MARK: - Body
    var body: some View {
        GeometryReader { geometry in
            let contentWidth = isLandscape
                ? min(geometry.size.width * 0.45, 500)
                : min(geometry.size.width * 0.92, 500)

            ZStack {
                // Background
                backgroundGradient

                if isLandscape {
                    landscapeContent(contentWidth: contentWidth, geometry: geometry)
                } else {
                    portraitContent(contentWidth: contentWidth)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: BSCSpacing.sm) {
                    if authService.isAuthenticated {
                        messagesButton
                        notificationsButton
                    }
                    settingsButton
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environment(appSettings)
        }
        .sheet(isPresented: $showingNotifications) {
            NotificationCenterView()
        }
        .sheet(isPresented: $showingInbox) {
            if let userId = authService.currentUser?.id {
                InboxView(currentUserId: userId, mediaStore: mediaStore)
            }
        }
        // A push tap, deep link, or "Message" from a profile opens the inbox,
        // which then pushes the thread.
        .onChange(of: navigationState.pendingConversationId, initial: true) { _, id in
            guard id != nil else { return }
            showingSettings = false
            showingNotifications = false
            showingInbox = true
        }
        .onChange(of: navigationState.pendingMessageRecipientId, initial: true) { _, userId in
            guard userId != nil else { return }
            showingSettings = false
            showingNotifications = false
            showingInbox = true
        }
        .sheet(isPresented: $showingStatsSignIn) {
            AuthGateView(onSkip: { showingStatsSignIn = false })
        }
        .onChange(of: authService.isAuthenticated) { _, signedIn in
            if signedIn { showingStatsSignIn = false }
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 1,
            matching: .videos,
            preferredItemEncoding: .current, // deliver original bytes; avoid slow re-encode on import
            photoLibrary: .shared() // items carry a PhotoKit identifier → background-capable iCloud fetch
        )
        .onChange(of: selectedPhotoItems) { _, items in
            if let item = items.first {
                pendingUploadItems = [item]
                selectedPhotoItems.removeAll()
                showingFolderSelection = true
            }
        }
        .sheet(isPresented: $showingFolderSelection, onDismiss: {
            // Present the name prompt only after the sheet has fully dismissed —
            // chaining an alert while a sheet animates out is flaky in SwiftUI.
            if pendingUploadItems.first != nil && pendingDestinationFolder != nil {
                showingNamePrompt = true
            }
        }) {
            UploadFolderSelectionSheet(
                mediaStore: mediaStore,
                onFolderSelected: { folderPath in
                    pendingDestinationFolder = folderPath
                    showingFolderSelection = false
                },
                onCancel: {
                    pendingUploadItems.removeAll()
                    pendingDestinationFolder = nil
                    showingFolderSelection = false
                }
            )
        }
        .uploadNamePrompt(isPresented: $showingNamePrompt) { name in
            if let item = pendingUploadItems.first, let folder = pendingDestinationFolder {
                uploadCoordinator.handlePhotosPickerItem(item, destinationFolder: folder, customName: name)
            }
            pendingUploadItems.removeAll()
            pendingDestinationFolder = nil
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

            // Delay animation start to let view finish initial layout
            // This prevents laggy/jumpy intro animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.bscSpring) {
                    hasAppeared = true
                }

                // Present onboarding in the same settle tick so there's no window
                // where the user can tap Home actions before it appears.
                if !appSettings.hasCompletedOnboarding {
                    showingOnboarding = true
                }
            }
        }
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
                .frame(maxWidth: geometry.size.width * 0.3, maxHeight: .infinity)

            // Right side: Stats + CTAs (centered, no scroll needed — content ~276pt fits)
            VStack(spacing: BSCSpacing.sm) {
                animatedContent(contentWidth: contentWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.bottom, BSCSpacing.huge)
    }

    // MARK: - Animated Content (shared between layouts)
    @ViewBuilder
    private func animatedContent(contentWidth: CGFloat) -> some View {
        if let viewModel = viewModel {
            // Lifetime stats are account-linked: signed out, the slot invites
            // sign-in instead of showing device-local numbers.
            Group {
                if authService.isAuthenticated {
                    StatsCard(
                        stats: viewModel.stats(isPro: SubscriptionService.shared.isPro)
                    )
                } else {
                    StatsSignInCard { showingStatsSignIn = true }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Home.statsCard)
            .frame(maxWidth: contentWidth)
            .opacity(hasAppeared ? 1 : 0)
            .offset(
                x: hasAppeared || reduceMotion ? 0 : -30,
                y: hasAppeared || reduceMotion ? 0 : -30
            )
            .animation(reduceMotion ? .bscStandard : .bscSpring.delay(0.1), value: hasAppeared)
        }

        VStack(spacing: BSCSpacing.sm) {
            mainCTAButton
            favoriteRalliesCTAButton
        }
        .frame(maxWidth: contentWidth)
        .opacity(hasAppeared ? 1 : 0)
        .offset(
            x: hasAppeared || reduceMotion ? 0 : -40,
            y: hasAppeared || reduceMotion ? 0 : -40
        )
        .animation(reduceMotion ? .bscStandard : .bscSpring.delay(0.2), value: hasAppeared)

        quickActionsSection
            .frame(maxWidth: contentWidth)
            .opacity(hasAppeared ? 1 : 0)
            .offset(
                x: hasAppeared || reduceMotion ? 0 : -50,
                y: hasAppeared || reduceMotion ? 0 : -50
            )
            .animation(reduceMotion ? .bscStandard : .bscSpring.delay(0.3), value: hasAppeared)
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
        NavigationLink(destination: LibraryView(mediaStore: mediaStore, uploadCoordinator: uploadCoordinator)) {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "play.circle.fill")
                    .bscFont(size: 24, weight: .semibold)

                Text("View Library")
                    .bscFont(size: 18, weight: .bold)

                Spacer()

                Image(systemName: "chevron.right")
                    .bscFont(size: 16, weight: .semibold)
            }
            .foregroundColor(.bscOnPrimary)
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
                    .bscFont(size: 20, weight: .semibold)

                Text("Favorite Rallies")
                    .bscFont(size: 16, weight: .bold)

                Spacer()

                Image(systemName: "chevron.right")
                    .bscFont(size: 14, weight: .semibold)
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
                quickActionContent(icon: "brain.head.profile", title: "Process", color: .bscTealText)
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
        // 6pt gap is deliberate; BSCSpacing has no token between xs (4) and sm (8)
        VStack(spacing: 6) {
            Image(systemName: icon)
                .bscFont(size: 22, weight: .medium)
                .foregroundColor(color)

            Text(title)
                .bscFont(size: 12, weight: .medium)
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

    // MARK: - Messages Button
    private var messagesButton: some View {
        let unread = DirectMessageService.shared.unreadCount
        return BSCIconButton(
            icon: "envelope.fill",
            style: .glass,
            size: .compact,
            badge: unread,
            accessibilityLabel: unread > 0 ? "Messages, \(unread) unread" : "Messages"
        ) {
            showingInbox = true
        }
        .accessibilityIdentifier(AccessibilityID.Home.messages)
    }

    // MARK: - Notifications Button
    private var notificationsButton: some View {
        let unread = SocialNotificationService.shared.unreadCount
        return BSCIconButton(
            icon: "bell.fill",
            style: .glass,
            size: .compact,
            badge: unread,
            accessibilityLabel: unread > 0 ? "Notifications, \(unread) unread" : "Notifications"
        ) {
            showingNotifications = true
        }
        .accessibilityIdentifier(AccessibilityID.Home.notifications)
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
                                .bscFont(size: 16, weight: .bold)
                                .foregroundColor(.bscOnPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(LinearGradient.bscPrimaryGradient)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }

                        Button {
                            showingCreateFolder = true
                        } label: {
                            Text("Create New Folder")
                                .bscFont(size: 14, weight: .medium)
                                .foregroundColor(.bscTextSecondary)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
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
                        .bscFont(size: 18, weight: .medium)
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text(name)
                        .bscFont(size: 16, weight: .medium)
                        .foregroundColor(.bscTextPrimary)

                    if !path.isEmpty {
                        Text(path)
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)
                    }
                }

                Spacer()

                if selectedFolderPath == path {
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 22)
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
                            .bscFont(size: 14, weight: .semibold)
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
                            BSCEmptyState.allCaughtUp()
                        } else if !unprocessedVideos.isEmpty {
                            // Divider between import and existing videos
                            HStack {
                                Rectangle()
                                    .fill(Color.bscSurfaceBorder)
                                    .frame(height: 1)
                                Text("or select an existing video")
                                    .bscFont(size: 12, weight: .medium)
                                    .foregroundColor(.bscTextSecondary)
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
                    // TODO(design): modal scrim token
                    Color.bscMediaScrim.ignoresSafeArea()
                    VStack(spacing: BSCSpacing.md) {
                        ProgressView()
                            .tint(.bscPrimary)
                            .scaleEffect(1.2)
                        Text("Importing video...")
                            .bscFont(size: 14, weight: .medium)
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
                matching: .videos,
                preferredItemEncoding: .current, // deliver original bytes; avoid slow re-encode on import
                photoLibrary: .shared() // items carry a PhotoKit identifier → background-capable iCloud fetch
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
                    // Keep the results summary on screen after completion —
                    // the user dismisses it (or taps View Rallies) themselves.
                    onComplete: {}
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
                    .bscFont(size: 20, weight: .semibold)

                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text("Import New Video")
                        .bscFont(size: 16, weight: .bold)
                    Text("Add from Photos and process immediately")
                        .bscFont(size: 12)
                        .opacity(0.8)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .bscFont(size: 14, weight: .semibold)
            }
            .foregroundColor(.bscOnPrimary)
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

            // Move the Photos temp file into library storage before registering it —
            // iOS purges the temp URL, so the manifest must point at our own copy
            let fileName = "Video_\(DateFormatter.yyyyMMdd_HHmmss.string(from: Date()))_\(UUID().uuidString.prefix(4)).mp4"
            let destinationURL = StorageManager.getPersistentStorageDirectory()
                .appendingPathComponent(LibraryType.saved.rootPath)
                .appendingPathComponent(fileName)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: videoData.url, to: destinationURL)

            let success = mediaStore.addVideo(at: destinationURL, toFolder: LibraryType.saved.rootPath)

            await MainActor.run {
                isImporting = false
                if success {
                    importedVideo = ImportedVideo(url: destinationURL)
                } else {
                    // Registration failed — remove the moved copy, or it lingers
                    // on disk untracked by the manifest with no cleanup path
                    try? FileManager.default.removeItem(at: destinationURL)
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
            // Keep the results summary on screen after completion.
            onComplete: {}
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

            VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                Text(video.displayName)
                    .bscFont(size: 15, weight: .medium)
                    .foregroundColor(.bscTextPrimary)
                    .lineLimit(1)

                HStack(spacing: BSCSpacing.sm) {
                    if let duration = video.duration {
                        Text(formatDuration(duration))
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)

                        Text("\u{2022}")
                            .foregroundColor(.bscTextTertiary)
                    }

                    Text(formatFileSize(video.fileSize))
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .bscFont(size: 14, weight: .medium)
                .foregroundColor(.bscTextSecondary)
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
    let store = MediaStore()
    NavigationStack {
        HomeView(mediaStore: store, metadataStore: MetadataStore())
    }
    .environment(AppSettings.shared)
    .environment(UploadCoordinator(mediaStore: store))
}
