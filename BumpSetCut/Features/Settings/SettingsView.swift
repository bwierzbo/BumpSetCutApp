//
//  SettingsView.swift
//  BumpSetCut
//
//  App settings and feature toggles interface
//

import SwiftUI
import StoreKit

// MARK: - SettingsView
struct SettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss
    @State private var hasAppeared = false
    @State private var showPaywall = false
    @State private var showFlywheelConsent = false
    @State private var flywheelService = FlywheelCaptureService.shared
    @State private var showDeleteConfirmation = false
    @State private var showBlockedUsers = false
    @State private var isDeletingAccount = false
    @State private var deleteError: String?
    @State private var subscriptionService = SubscriptionService.shared
    @State private var isRestoringPurchases = false
    @State private var restoreResultMessage: String?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.bscBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.xl) {
                        // Subscription section
                        subscriptionSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.05), value: hasAppeared)

                        // Debug section (debug builds only)
                        #if DEBUG
                        debugSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.1), value: hasAppeared)
                        #else
                        // TestFlight testers get the tier toggle debug builds have
                        if SubscriptionService.isTestFlight {
                            testerSection
                                .opacity(hasAppeared ? 1 : 0)
                                .offset(y: hasAppeared ? 0 : 20)
                                .animation(.bscSpring.delay(0.1), value: hasAppeared)
                        }
                        #endif

                        // Appearance section
                        appearanceSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.15), value: hasAppeared)


                        // Data flywheel (opt-in model improvement)
                        dataFlywheelSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.27), value: hasAppeared)

                        // Social & Privacy section
                        socialPrivacySection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.3), value: hasAppeared)

                        // Status section (debug-only rows)
                        #if DEBUG
                        statusSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.35), value: hasAppeared)
                        #endif

                        // Legal section
                        legalSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.4), value: hasAppeared)

                        // App info section
                        appInfoSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.45), value: hasAppeared)

                        Spacer(minLength: BSCSpacing.huge)
                    }
                    .padding(BSCSpacing.lg)
                    .frame(maxWidth: isLandscape ? 600 : .infinity)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.bscPrimaryText)
                    .accessibilityIdentifier(AccessibilityID.Settings.done)
                }
            }
            .onAppear {
                withAnimation(.bscSpring) {
                    hasAppeared = true
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showFlywheelConsent) {
                FlywheelConsentSheet(
                    onAccept: {
                        appSettings.flywheelConsentVersion = FlywheelConsent.currentVersion
                        appSettings.flywheelOptInDate = Date()
                        appSettings.enableDataFlywheel = true
                        showFlywheelConsent = false
                    },
                    onCancel: { showFlywheelConsent = false }
                )
            }
        }
    }
}

// MARK: - Subscription Section
private extension SettingsView {
    var subscriptionSection: some View {
        BSCSettingsSection(
            title: subscriptionService.isPro ? "Pro" : "Free Plan",
            subtitle: subscriptionService.isPro ? "You have unlimited access" : "Upgrade to unlock all features",
            icon: subscriptionService.isPro ? "crown.fill" : "crown",
            iconColor: subscriptionService.isPro ? .bscWarningText : .bscPrimary
        ) {
            VStack(spacing: BSCSpacing.md) {
                if subscriptionService.isPro {
                    // Pro status
                    VStack(spacing: BSCSpacing.sm) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.bscSuccessText)
                            Text("BumpSetCut Pro Active")
                                .bscFont(size: 17, weight: .semibold)
                            Spacer()
                        }

                        Button {
                            showManageSubscriptions()
                        } label: {
                            manageSubscriptionLabel
                        }
                        .foregroundStyle(Color.bscTextPrimary)
                    }
                    .bscCardPadding()
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.md)
                            .fill(Color.bscSurfaceGlass)
                    )
                } else {
                    // Free tier limits
                    VStack(spacing: BSCSpacing.sm) {
                        if let remaining = subscriptionService.remainingProcessingMinutes() {
                            LimitRow(
                                icon: "waveform",
                                title: "Weekly Processing",
                                value: "\(Int(remaining)) min of \(Int(SubscriptionService.weeklyProcessingDurationMinutes)) min remaining"
                            )
                        }

                        LimitRow(
                            icon: "wifi",
                            title: "Processing Requires",
                            value: "Internet connection"
                        )

                        LimitRow(
                            icon: "drop.fill",
                            title: "Watermark",
                            value: "On exported videos"
                        )
                    }
                    .bscCardPadding()
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.md)
                            .fill(Color.bscSurfaceGlass)
                    )

                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Image(systemName: "crown.fill")
                            Text("Upgrade to Pro")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(Color.bscOnPrimary)
                        .frame(maxWidth: .infinity)
                        .bscCardPadding()
                        .background(
                            RoundedRectangle(cornerRadius: BSCRadius.md)
                                .fill(LinearGradient.bscPrimaryGradient)
                        )
                    }

                    // A lapsed subscriber still needs restore + management
                    // without going through the paywall.
                    Button {
                        Task { await restorePurchasesFromSettings() }
                    } label: {
                        HStack {
                            Text(isRestoringPurchases ? "Restoring…" : "Restore Purchases")
                            Spacer()
                        }
                        .foregroundStyle(Color.bscTextSecondary)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .disabled(isRestoringPurchases)

                    Button {
                        showManageSubscriptions()
                    } label: {
                        manageSubscriptionLabel
                            .foregroundStyle(Color.bscTextSecondary)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreResultMessage != nil },
            set: { if !$0 { restoreResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreResultMessage ?? "")
        }
    }

    var manageSubscriptionLabel: some View {
        HStack {
            Text("Manage Subscription")
            Spacer()
            Image(systemName: "chevron.right")
                .bscFont(size: 12)
                .foregroundStyle(Color.bscTextSecondary)
        }
    }

    func showManageSubscriptions() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        Task {
            try? await AppStore.showManageSubscriptions(in: scene)
        }
    }

    func restorePurchasesFromSettings() async {
        isRestoringPurchases = true
        defer { isRestoringPurchases = false }
        do {
            try await StoreManager.shared.restorePurchases()
            await subscriptionService.refreshSubscriptionStatus()
            restoreResultMessage = subscriptionService.isPro
                ? "Your BumpSetCut Pro subscription has been restored."
                : "No active subscriptions found for this Apple ID."
        } catch {
            restoreResultMessage = error.localizedDescription
        }
    }
}

// MARK: - Limit Row
struct LimitRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .bscFont(size: 12)
                .foregroundStyle(Color.bscTextSecondary)
                .frame(width: BSCIconSize.md)

            Text(title)
                .bscFont(size: 15)

            Spacer()

            Text(value)
                .bscFont(size: 15)
                .foregroundStyle(Color.bscTextSecondary)
        }
    }
}

// MARK: - Pro Mode Toggle
private extension SettingsView {
    /// Tier override shared by the debug section and the TestFlight tester section.
    var proModeToggle: some View {
        BSCSettingsToggle(
            title: "Pro Mode",
            subtitle: "Switch between Pro and Free tier for testing",
            icon: "crown.fill",
            isOn: Binding(
                get: { subscriptionService.isPro },
                set: { subscriptionService.setProStatus($0) }
            )
        )
    }
}

// MARK: - Tester Section (TestFlight release builds)
#if !DEBUG
private extension SettingsView {
    var testerSection: some View {
        BSCSettingsSection(title: "TestFlight", subtitle: "Visible to beta testers only", icon: "hammer.fill", iconColor: .bscTealText) {
            proModeToggle
        }
    }
}
#endif

// MARK: - Debug Section
#if DEBUG
private extension SettingsView {
    var debugSection: some View {
        @Bindable var appSettings = appSettings
        return BSCSettingsSection(title: "Debug", subtitle: "Debug builds only", icon: "ladybug.fill", iconColor: .bscTealText) {
            VStack(spacing: BSCSpacing.md) {
                proModeToggle

                Divider()
                    .overlay(Color.bscSurfaceBorder)

                BSCSettingsToggle(
                    title: "Debug Features",
                    subtitle: "Enable advanced debug tools",
                    icon: "wrench.and.screwdriver.fill",
                    isOn: $appSettings.enableDebugFeatures
                )

                Divider()
                    .overlay(Color.bscSurfaceBorder)

                BSCSettingsToggle(
                    title: "Performance Metrics",
                    subtitle: "Show frame rate and memory usage",
                    icon: "gauge.with.needle.fill",
                    isOn: $appSettings.showPerformanceMetrics
                )
            }
        }
    }
}
#endif

// MARK: - Appearance Section
private extension SettingsView {
    var appearanceSection: some View {
        BSCSettingsSection(title: "Appearance", icon: "paintbrush.fill", iconColor: .bscBlue) {
            VStack(spacing: BSCSpacing.md) {
                HStack(spacing: BSCSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.bscBlue.opacity(0.15))
                            .frame(width: 36, height: 36)

                        Image(systemName: appSettings.appearanceMode == .dark ? "moon.fill" :
                                appSettings.appearanceMode == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                            .bscFont(size: 16)
                            .foregroundColor(.bscBlue)
                    }

                    VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                        Text("Theme")
                            .bscFont(size: 16, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)

                        Text("Choose your preferred appearance")
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)
                    }

                    Spacer()
                }

                // Theme picker
                HStack(spacing: BSCSpacing.sm) {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            withAnimation(.bscStandard) {
                                appSettings.appearanceMode = theme
                            }
                        } label: {
                            VStack(spacing: BSCSpacing.xs) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                                        // Swatches preview each theme's background regardless of the
                                        // current mode: dark = bscMediaBackground (fixed dark bg value),
                                        // light = bscBackground's light value (no fixed-light token),
                                        // system = the adaptive background itself.
                                        .fill(theme == .dark ? Color.bscMediaBackground :
                                              theme == .light ? Color(hex: "#F8F8FA") :
                                              Color.bscBackground)
                                        .frame(height: 48)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                                                .stroke(appSettings.appearanceMode == theme ? Color.bscBlue : Color.bscSurfaceBorder, lineWidth: appSettings.appearanceMode == theme ? 2 : 1)
                                        )

                                    Image(systemName: theme == .dark ? "moon.fill" :
                                            theme == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                                        .bscFont(size: 18)
                                        // Mode-invariant on purpose: each glyph must stay legible on its
                                        // own swatch. #1A1A1C is bscTextPrimary's light value, which has
                                        // no fixed (non-adaptive) token.
                                        .foregroundColor(theme == .dark ? .white : theme == .light ? Color(hex: "#1A1A1C") : .bscBlue)
                                }

                                Text(theme.rawValue)
                                    .bscFont(size: 12, weight: appSettings.appearanceMode == theme ? .semibold : .regular)
                                    .foregroundColor(appSettings.appearanceMode == theme ? .bscBlue : .bscTextSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            // The swatch is a filled shape and hit-tests itself, but
                            // the name under it and the gap beside it did not.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(theme.rawValue) theme\(appSettings.appearanceMode == theme ? ", selected" : "")")
                        .accessibilityAddTraits(appSettings.appearanceMode == theme ? .isSelected : [])
                        .accessibilityIdentifier(
                            theme == .light ? AccessibilityID.Settings.themeLight :
                            theme == .dark ? AccessibilityID.Settings.themeDark :
                            AccessibilityID.Settings.themeSystem
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Data Flywheel Section
private extension SettingsView {
    var dataFlywheelSection: some View {
        // Intercept turning the toggle ON to require consent; turning OFF disables
        // immediately and clears anything still staged for upload.
        let toggle = Binding<Bool>(
            get: { appSettings.enableDataFlywheel },
            set: { newValue in
                if newValue {
                    showFlywheelConsent = true
                } else {
                    appSettings.enableDataFlywheel = false
                    flywheelService.clearPending()
                }
            }
        )

        return BSCSettingsSection(title: "Improve Detection", icon: "wand.and.stars", iconColor: .bscPrimary) {
            VStack(spacing: BSCSpacing.md) {
                BSCSettingsToggle(
                    title: "Contribute Training Clips",
                    subtitle: "Share clips of rallies the model struggled with so detection can improve",
                    icon: "brain.head.profile",
                    isOn: toggle
                )

                if appSettings.enableDataFlywheel {
                    Divider().overlay(Color.bscSurfaceBorder)

                    HStack {
                        Text("Contributed")
                            .bscFont(size: 14)
                            .foregroundColor(.bscTextSecondary)
                        Spacer()
                        Text("\(flywheelService.lifetimeContributedCount)")
                            .bscFont(size: 14, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                    }

                    if flywheelService.pendingCount > 0 {
                        HStack {
                            Text("Pending upload")
                                .bscFont(size: 14)
                                .foregroundColor(.bscTextSecondary)
                            Spacer()
                            Button {
                                flywheelService.clearPending()
                            } label: {
                                Text("Clear (\(flywheelService.pendingCount))")
                                    .bscFont(size: 14, weight: .medium)
                                    .foregroundColor(.bscPrimaryText)
                                    .frame(minHeight: BSCTouchTarget.standard)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Social & Privacy Section
private extension SettingsView {
    var socialPrivacySection: some View {
        BSCSettingsSection(title: "Social & Privacy", icon: "person.2.circle.fill", iconColor: .bscPrimary) {
            VStack(spacing: BSCSpacing.md) {
                if authService.authState == .authenticated {
                    // Account row
                    HStack(spacing: BSCSpacing.md) {
                        ZStack {
                            Circle()
                                .fill(Color.bscPrimary.opacity(0.15))
                                .frame(width: 36, height: 36)

                            Image(systemName: "person.fill")
                                .bscFont(size: 16)
                                .foregroundColor(.bscPrimary)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                            Text(authService.currentUser?.username ?? "Account")
                                .bscFont(size: 16, weight: .semibold)
                                .foregroundColor(.bscTextPrimary)

                            Text("Signed in")
                                .bscFont(size: 12)
                                .foregroundColor(.bscTextSecondary)
                        }

                        Spacer()
                    }

                    Divider()
                        .overlay(Color.bscSurfaceBorder)

                    // Blocked users management (unblock lives here)
                    Button {
                        showBlockedUsers = true
                    } label: {
                        HStack {
                            Image(systemName: "hand.raised")
                                .foregroundColor(.bscTextSecondary)
                            Text("Blocked Users")
                                .bscFont(size: 14, weight: .medium)
                                .foregroundColor(.bscTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .bscFont(size: 12)
                                .foregroundColor(.bscTextSecondary)
                        }
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Settings.blockedUsers)
                    .sheet(isPresented: $showBlockedUsers) {
                        BlockedUsersView()
                    }

                    Divider()
                        .overlay(Color.bscSurfaceBorder)

                    // Sign out button
                    Button {
                        authService.signOut()
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.bscTextSecondary)
                            Text("Sign Out")
                                .bscFont(size: 14, weight: .medium)
                                .foregroundColor(.bscTextSecondary)
                            Spacer()
                        }
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Settings.signOut)

                    Divider()
                        .overlay(Color.bscSurfaceBorder)

                    // Delete account button
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            if isDeletingAccount {
                                ProgressView()
                                    .tint(.bscErrorText)
                            } else {
                                Image(systemName: "trash")
                                    .foregroundColor(.bscErrorText)
                            }
                            Text("Delete Account")
                                .bscFont(size: 14, weight: .medium)
                                .foregroundColor(.bscErrorText)
                            Spacer()
                        }
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeletingAccount)
                    .accessibilityIdentifier(AccessibilityID.Settings.deleteAccount)
                    .accessibilityHint("Permanently deletes your account and data")
                    .sheet(isPresented: $showDeleteConfirmation) {
                        DeleteAccountConfirmationView(
                            username: authService.currentUser?.username ?? ""
                        ) {
                            Task {
                                isDeletingAccount = true
                                deleteError = nil
                                do {
                                    try await authService.deleteAccount()
                                } catch {
                                    deleteError = error.localizedDescription
                                }
                                isDeletingAccount = false
                            }
                        }
                    }
                    .alert("Delete Failed", isPresented: .init(
                        get: { deleteError != nil },
                        set: { if !$0 { deleteError = nil } }
                    )) {
                        Button("OK") { deleteError = nil }
                    } message: {
                        Text(deleteError ?? "")
                    }
                } else {
                    // Not signed in state
                    HStack(spacing: BSCSpacing.md) {
                        ZStack {
                            Circle()
                                .fill(Color.bscPrimary.opacity(0.15))
                                .frame(width: 36, height: 36)

                            Image(systemName: "person.fill")
                                .bscFont(size: 16)
                                .foregroundColor(.bscPrimary)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                            Text("Not signed in")
                                .bscFont(size: 16, weight: .semibold)
                                .foregroundColor(.bscTextPrimary)

                            Text("Sign in to access community features")
                                .bscFont(size: 12)
                                .foregroundColor(.bscTextSecondary)
                        }

                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - Status Section
private extension SettingsView {
    var statusSection: some View {
        BSCSettingsSection(title: "Current Status", icon: "checkmark.circle.fill", iconColor: .bscSuccessText) {
            VStack(spacing: BSCSpacing.md) {
                #if DEBUG
                BSCStatusRow(
                    title: "Debug Features",
                    isEnabled: appSettings.enableDebugFeatures
                )

                Divider()
                    .overlay(Color.bscSurfaceBorder)

                BSCStatusRow(
                    title: "Performance Metrics",
                    isEnabled: appSettings.showPerformanceMetrics
                )
                #endif
            }
        }
    }
}

// MARK: - Legal Section
private extension SettingsView {
    var legalSection: some View {
        BSCSettingsSection(title: "Legal", icon: "doc.text.fill", iconColor: .bscTextSecondary) {
            VStack(spacing: BSCSpacing.sm) {
                legalLinkRow(
                    title: "Privacy Policy",
                    icon: "arrow.up.right",
                    urlString: "https://bumpsetcut.com/privacy",
                    hint: "Opens in browser",
                    accessibilityID: AccessibilityID.Settings.privacyPolicy
                )

                legalLinkRow(
                    title: "Terms of Service",
                    icon: "arrow.up.right",
                    urlString: "https://bumpsetcut.com/terms",
                    hint: "Opens in browser",
                    accessibilityID: AccessibilityID.Settings.termsOfService
                )

                legalLinkRow(
                    title: "Community Guidelines",
                    icon: "arrow.up.right",
                    urlString: "https://bumpsetcut.com/community-guidelines",
                    hint: "Opens in browser",
                    accessibilityID: AccessibilityID.Settings.communityGuidelines
                )

                // Developer contact — required alongside the UGC report/block
                // tooling so users can reach a human.
                legalLinkRow(
                    title: "Contact Support",
                    icon: "envelope",
                    urlString: "mailto:support@bumpsetcut.com",
                    hint: "Opens your email app",
                    accessibilityID: AccessibilityID.Settings.contactSupport
                )
            }
        }
    }

    func legalLinkRow(
        title: String,
        icon: String,
        urlString: String,
        hint: String,
        accessibilityID: String
    ) -> some View {
        Button {
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack {
                Text(title)
                    .bscFont(size: 15)
                Spacer()
                Image(systemName: icon)
                    .bscFont(size: 12)
                    .foregroundStyle(Color.bscTextSecondary)
            }
            .foregroundStyle(Color.bscTextPrimary)
            .bscCardPadding()
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md)
                    .fill(Color.bscSurfaceGlass)
            )
            .contentShape(Rectangle())
        }
        .accessibilityHint(hint)
        .accessibilityIdentifier(accessibilityID)
    }
}

// MARK: - App Info Section
private extension SettingsView {
    var appInfoSection: some View {
        BSCSettingsSection(title: "About", icon: "info.circle.fill", iconColor: .bscPrimary) {
            VStack(spacing: BSCSpacing.lg) {
                // App logo
                ZStack {
                    Circle()
                        .fill(Color.bscPrimary.opacity(0.15))
                        .frame(width: 64, height: 64)

                    Image(systemName: "figure.volleyball")
                        .bscFont(size: 28, weight: .medium)
                        .foregroundColor(.bscPrimary)
                }

                VStack(spacing: BSCSpacing.xs) {
                    Text("BumpSetCut")
                        .bscFont(size: 20, weight: .bold)
                        .foregroundColor(.bscTextPrimary)
                        .accessibilityIdentifier(AccessibilityID.Settings.appName)

                    Text("Rally Detection AI")
                        .bscFont(size: 14)
                        .foregroundColor(.bscTextSecondary)
                }

                // Version info
                HStack(spacing: BSCSpacing.xl) {
                    VStack(spacing: BSCSpacing.xxs) {
                        Text("Version")
                            .bscFont(size: 11)
                            .foregroundColor(.bscTextSecondary)
                            .textCase(.uppercase)
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .bscFont(size: 14, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.appVersion)

                    Divider()
                        .overlay(Color.bscSurfaceBorder)
                        .frame(height: 30)

                    VStack(spacing: BSCSpacing.xxs) {
                        Text("Build")
                            .bscFont(size: 11)
                            .foregroundColor(.bscTextSecondary)
                            .textCase(.uppercase)
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .bscFont(size: 14, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                    }
                }
                .padding(.top, BSCSpacing.sm)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - BSCSettingsSection
private struct BSCSettingsSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.md) {
            // Header
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: icon)
                    .bscFont(size: 14, weight: .medium)
                    .foregroundColor(iconColor)

                Text(title)
                    .bscFont(size: 13, weight: .semibold)
                    .foregroundColor(.bscTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let subtitle = subtitle {
                    Text("(\(subtitle))")
                        .bscFont(size: 11)
                        .foregroundColor(.bscTextSecondary)
                }
            }
            .padding(.horizontal, BSCSpacing.xs)

            // Content
            content()
                .padding(BSCSpacing.lg)
                .background(Color.bscSurfaceGlass)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                )
        }
    }
}

// MARK: - BSCSettingsToggle
private struct BSCSettingsToggle: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        // The whole row is the Toggle's label, so tapping anywhere flips it.
        Toggle(isOn: $isOn) {
            HStack(spacing: BSCSpacing.md) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.bscBlue.opacity(0.15))
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .bscFont(size: 16)
                        .foregroundColor(.bscBlue)
                }

                // Text
                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text(title)
                        .bscFont(size: 16, weight: .semibold)
                        .foregroundColor(.bscTextPrimary)

                    Text(subtitle)
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
        .tint(.bscPrimary)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

// MARK: - BSCStatusRow
private struct BSCStatusRow: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        HStack {
            Text(title)
                .bscFont(size: 14)
                .foregroundColor(.bscTextSecondary)

            Spacer()

            HStack(spacing: BSCSpacing.xs) {
                Circle()
                    .fill(isEnabled ? Color.bscSuccessText : Color.bscTextSecondary)
                    .frame(width: 8, height: 8)

                Text(isEnabled ? "Enabled" : "Disabled")
                    .bscFont(size: 13, weight: .medium)
                    .foregroundColor(isEnabled ? .bscSuccessText : .bscTextSecondary)
            }
        }
    }
}

// MARK: - Delete Account Confirmation

/// Requires the user to type their exact username before the destructive action
/// is enabled — guards against accidental account deletion.
private struct DeleteAccountConfirmationView: View {
    let username: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var matches: Bool {
        !username.isEmpty && typed.trimmingCharacters(in: .whitespacesAndNewlines) == username
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: BSCSpacing.lg) {
                ZStack {
                    Circle()
                        .fill(Color.bscError.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .bscFont(size: 28)
                        .foregroundColor(.bscErrorText)
                }
                .padding(.top, BSCSpacing.xl)

                Text("Delete Account")
                    .bscFont(size: 22, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text("This permanently deletes your account and all associated data. This cannot be undone.")
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BSCSpacing.lg)

                VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                    (Text("Type ").foregroundColor(.bscTextSecondary)
                     + Text(username).fontWeight(.bold).foregroundColor(.bscTextPrimary)
                     + Text(" to confirm").foregroundColor(.bscTextSecondary))
                        .bscFont(size: 13)

                    TextField("Username", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.done)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.top, BSCSpacing.sm)

                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text("Delete Account")
                        .bscFont(size: 16, weight: .semibold)
                        .foregroundColor(.bscOnPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .background(matches ? Color.bscErrorFill : Color.bscErrorFill.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                }
                .disabled(!matches)
                .padding(.horizontal, BSCSpacing.lg)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bscBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Flywheel Consent Sheet

struct FlywheelConsentSheet: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    private let bullets: [(icon: String, text: String)] = [
        ("scissors", "We upload short clips of rallies the model struggled with — not your whole library."),
        ("chart.bar.doc.horizontal", "Each clip includes the detector's per-frame data so the frames can be relabeled."),
        ("person.crop.circle.badge.checkmark", "Clips are tied to your account and used only to improve detection."),
        ("hand.raised", "You can turn this off any time; pending clips are deleted when you do.")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: BSCSpacing.lg) {
                        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                            Text("Help Improve Detection")
                                .bscFont(size: 22, weight: .bold)
                                .foregroundColor(.bscTextPrimary)
                            Text("Contribute training clips so the volleyball model gets better over time.")
                                .bscFont(size: 15)
                                .foregroundColor(.bscTextSecondary)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.md) {
                            ForEach(bullets, id: \.icon) { bullet in
                                HStack(alignment: .top, spacing: BSCSpacing.md) {
                                    Image(systemName: bullet.icon)
                                        .bscFont(size: 16)
                                        .foregroundColor(.bscPrimary)
                                        .frame(width: BSCIconSize.lg)
                                    Text(bullet.text)
                                        .bscFont(size: 14)
                                        .foregroundColor(.bscTextPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Link("Privacy Policy", destination: URL(string: "https://bumpsetcut.com/privacy")!)
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscPrimaryText)

                        Button {
                            onAccept()
                        } label: {
                            Text("Turn On Contributions")
                                .bscFont(size: 16, weight: .semibold)
                                .foregroundColor(.bscOnPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(Color.bscPrimaryFill)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }
                        .padding(.top, BSCSpacing.sm)
                    }
                    .padding(BSCSpacing.lg)
                }
            }
            .navigationTitle("Data Flywheel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
    }
}

// MARK: - Preview
#Preview("SettingsView") {
    SettingsView()
        .environment(AppSettings.shared)
        .environment(AuthenticationService())
}
