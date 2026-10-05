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

    // Badge counts for the toolbar (app-wide observable services).
    private let messageService = DirectMessageService.shared
    private let notificationService = SocialNotificationService.shared

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
                InboxView(currentUserId: userId)
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
            if let viewModel {
                UnprocessedVideoPickerSheet(mediaStore: mediaStore, viewModel: viewModel)
            }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                showingOnboarding = false
                appSettings.hasCompletedOnboarding = true
            }
        }
        .task {
            if viewModel == nil {
                viewModel = HomeViewModel(mediaStore: mediaStore, metadataStore: metadataStore)
            }

            // Let the view finish its initial layout before starting the intro
            // animation — starting immediately makes it laggy/jumpy.
            try? await Task.sleep(for: .milliseconds(50))
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
                    StatsCard(stats: viewModel.stats)
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

                Image(systemName: "chevron.forward")
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

                Image(systemName: "chevron.forward")
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
        title: LocalizedStringResource,
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
        let unread = messageService.unreadCount
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
        let unread = notificationService.unreadCount
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
struct MainCTAButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.bscBounce, value: configuration.isPressed)
    }
}

// MARK: - Preview
#Preview("HomeView") {
    let store = MediaStore()
    NavigationStack {
        HomeView(mediaStore: store, metadataStore: MetadataStore.shared)
    }
    .environment(AppSettings.shared)
    .environment(UploadCoordinator(mediaStore: store))
}
