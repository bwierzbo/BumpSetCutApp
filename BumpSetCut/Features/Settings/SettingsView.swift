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
    @State private var isDeletingAccount = false
    @State private var deleteError: String?
    @State private var subscriptionService = SubscriptionService.shared
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
                        #endif

                        // Appearance section
                        appearanceSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.15), value: hasAppeared)


                        // Privacy section
                        privacySection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.25), value: hasAppeared)

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

                        // Status section
                        statusSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.35), value: hasAppeared)

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
                    .foregroundColor(.bscPrimary)
                    .accessibilityIdentifier(AccessibilityID.Settings.done)
                }
            }
            .onAppear {
                withAnimation {
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
            iconColor: subscriptionService.isPro ? .yellow : .bscPrimary
        ) {
            VStack(spacing: BSCSpacing.md) {
                if subscriptionService.isPro {
                    // Pro status
                    VStack(spacing: BSCSpacing.sm) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.bscSuccess)
                            Text("BumpSetCut Pro Active")
                                .font(.headline)
                            Spacer()
                        }

                        Button {
                            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                                Task {
                                    try? await AppStore.showManageSubscriptions(in: scene)
                                }
                            }
                        } label: {
                            HStack {
                                Text("Manage Subscription")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Color.bscTextSecondary)
                            }
                        }
                        .foregroundStyle(Color.bscTextPrimary)
                    }
                    .padding()
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
                            value: "WiFi connection"
                        )

                        LimitRow(
                            icon: "drop.fill",
                            title: "Watermark",
                            value: "On exported videos"
                        )
                    }
                    .padding()
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
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: BSCRadius.md)
                                .fill(LinearGradient(colors: [Color.bscBlue, Color.bscBlueDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                    }
                }
            }
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
                .font(.caption)
                .foregroundStyle(Color.bscTextSecondary)
                .frame(width: 20)

            Text(title)
                .font(.subheadline)

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.bscTextSecondary)
        }
    }
}

// MARK: - Debug Section
#if DEBUG
private extension SettingsView {
    var debugSection: some View {
        @Bindable var appSettings = appSettings
        return BSCSettingsSection(title: "Debug", subtitle: "Debug builds only", icon: "ladybug.fill", iconColor: .bscTeal) {
            VStack(spacing: BSCSpacing.md) {
                BSCSettingsToggle(
                    title: "Pro Mode",
                    subtitle: "Switch between Pro and Free tier for testing",
                    icon: "crown.fill",
                    isOn: Binding(
                        get: { subscriptionService.isPro },
                        set: { subscriptionService.setProStatus($0) }
                    )
                )

                Divider()
                    .background(Color.bscSurfaceBorder)

                BSCSettingsToggle(
                    title: "Debug Features",
                    subtitle: "Enable advanced debug tools",
                    icon: "wrench.and.screwdriver.fill",
                    isOn: $appSettings.enableDebugFeatures
                )

                Divider()
                    .background(Color.bscSurfaceBorder)

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
                            .font(.system(size: 16))
                            .foregroundColor(.bscBlue)
                    }

                    VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                        Text("Theme")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.bscTextPrimary)

                        Text("Choose your preferred appearance")
                            .font(.system(size: 12))
                            .foregroundColor(.bscTextSecondary)
                    }

                    Spacer()
                }

                // Theme picker
                HStack(spacing: BSCSpacing.sm) {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                appSettings.appearanceMode = theme
                            }
                        } label: {
                            VStack(spacing: BSCSpacing.xs) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                                        .fill(theme == .dark ? Color(hex: "#0D0D0E") :
                                              theme == .light ? Color(hex: "#F8F8FA") :
                                              Color(light: Color(hex: "#F8F8FA"), dark: Color(hex: "#0D0D0E")))
                                        .frame(height: 48)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                                                .stroke(appSettings.appearanceMode == theme ? Color.bscBlue : Color.bscSurfaceBorder, lineWidth: appSettings.appearanceMode == theme ? 2 : 1)
                                        )

                                    Image(systemName: theme == .dark ? "moon.fill" :
                                            theme == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                                        .font(.system(size: 18))
                                        .foregroundColor(theme == .dark ? .white : theme == .light ? Color(hex: "#1A1A1C") : .bscBlue)
                                }

                                Text(theme.rawValue)
                                    .font(.system(size: 12, weight: appSettings.appearanceMode == theme ? .semibold : .regular))
                                    .foregroundColor(appSettings.appearanceMode == theme ? .bscBlue : .bscTextSecondary)
                            }
                            .frame(maxWidth: .infinity)
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

// MARK: - Privacy Section
private extension SettingsView {
    var privacySection: some View {
        @Bindable var appSettings = appSettings
        return BSCSettingsSection(title: "Privacy", icon: "lock.shield.fill", iconColor: .bscBlue) {
            BSCSettingsToggle(
                title: "Analytics",
                subtitle: "Help improve the app with anonymous usage data",
                icon: "chart.bar.fill",
                isOn: $appSettings.enableAnalytics
            )
            .accessibilityIdentifier(AccessibilityID.Settings.analytics)
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
                    Divider().background(Color.bscSurfaceBorder)

                    HStack {
                        Text("Contributed")
                            .font(.system(size: 14))
                            .foregroundColor(.bscTextSecondary)
                        Spacer()
                        Text("\(flywheelService.lifetimeContributedCount)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.bscTextPrimary)
                    }

                    if flywheelService.pendingCount > 0 {
                        HStack {
                            Text("Pending upload")
                                .font(.system(size: 14))
                                .foregroundColor(.bscTextSecondary)
                            Spacer()
                            Button("Clear (\(flywheelService.pendingCount))") {
                                flywheelService.clearPending()
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.bscPrimary)
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
                                .font(.system(size: 16))
                                .foregroundColor(.bscPrimary)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                            Text(authService.currentUser?.username ?? "Account")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.bscTextPrimary)

                            Text("Signed in")
                                .font(.system(size: 12))
                                .foregroundColor(.bscTextSecondary)
                        }

                        Spacer()
                    }

                    Divider()
                        .background(Color.bscSurfaceBorder)

                    // Sign out button
                    Button {
                        authService.signOut()
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.bscTextSecondary)
                            Text("Sign Out")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.bscTextSecondary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Settings.signOut)

                    Divider()
                        .background(Color.bscSurfaceBorder)

                    // Delete account button
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            if isDeletingAccount {
                                ProgressView()
                                    .tint(.bscError)
                            } else {
                                Image(systemName: "trash")
                                    .foregroundColor(.bscError)
                            }
                            Text("Delete Account")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.bscError)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeletingAccount)
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
                                .font(.system(size: 16))
                                .foregroundColor(.bscPrimary)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                            Text("Not signed in")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.bscTextPrimary)

                            Text("Sign in to access community features")
                                .font(.system(size: 12))
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
        BSCSettingsSection(title: "Current Status", icon: "checkmark.circle.fill", iconColor: .bscSuccess) {
            VStack(spacing: BSCSpacing.md) {
                BSCStatusRow(
                    title: "Analytics",
                    isEnabled: appSettings.enableAnalytics
                )

                #if DEBUG
                Divider()
                    .background(Color.bscSurfaceBorder)

                BSCStatusRow(
                    title: "Debug Features",
                    isEnabled: appSettings.enableDebugFeatures
                )

                Divider()
                    .background(Color.bscSurfaceBorder)

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
                Button {
                    if let url = URL(string: "https://bumpsetcut.com/privacy") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("Privacy Policy")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(Color.bscTextSecondary)
                    }
                }
                .foregroundStyle(Color.bscTextPrimary)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.md)
                        .fill(Color.bscSurfaceGlass)
                )
                .accessibilityHint("Opens in browser")
                .accessibilityIdentifier(AccessibilityID.Settings.privacyPolicy)

                Button {
                    if let url = URL(string: "https://bumpsetcut.com/terms") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("Terms of Service")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(Color.bscTextSecondary)
                    }
                }
                .foregroundStyle(Color.bscTextPrimary)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.md)
                        .fill(Color.bscSurfaceGlass)
                )
                .accessibilityHint("Opens in browser")
                .accessibilityIdentifier(AccessibilityID.Settings.termsOfService)

                Button {
                    if let url = URL(string: "https://bumpsetcut.com/community-guidelines") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("Community Guidelines")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(Color.bscTextSecondary)
                    }
                }
                .foregroundStyle(Color.bscTextPrimary)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.md)
                        .fill(Color.bscSurfaceGlass)
                )
                .accessibilityHint("Opens in browser")
                .accessibilityIdentifier(AccessibilityID.Settings.communityGuidelines)
            }
        }
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
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.bscPrimary)
                }

                VStack(spacing: BSCSpacing.xs) {
                    Text("BumpSetCut")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.bscTextPrimary)
                        .accessibilityIdentifier(AccessibilityID.Settings.appName)

                    Text("Rally Detection AI")
                        .font(.system(size: 14))
                        .foregroundColor(.bscTextSecondary)
                }

                // Version info
                HStack(spacing: BSCSpacing.xl) {
                    VStack(spacing: BSCSpacing.xxs) {
                        Text("Version")
                            .font(.system(size: 11))
                            .foregroundColor(.bscTextTertiary)
                            .textCase(.uppercase)
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.bscTextPrimary)
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.appVersion)

                    Rectangle()
                        .fill(Color.bscSurfaceBorder)
                        .frame(width: 1, height: 30)

                    VStack(spacing: BSCSpacing.xxs) {
                        Text("Build")
                            .font(.system(size: 11))
                            .foregroundColor(.bscTextTertiary)
                            .textCase(.uppercase)
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(iconColor)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.bscTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let subtitle = subtitle {
                    Text("(\(subtitle))")
                        .font(.system(size: 11))
                        .foregroundColor(.bscTextTertiary)
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
        HStack(spacing: BSCSpacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.bscBlue.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.bscBlue)
            }

            // Text
            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.bscTextPrimary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.bscTextSecondary)
            }

            Spacer()

            // Toggle
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.bscPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - BSCStatusRow
private struct BSCStatusRow: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(.bscTextSecondary)

            Spacer()

            HStack(spacing: BSCSpacing.xs) {
                Circle()
                    .fill(isEnabled ? Color.bscSuccess : Color.bscTextTertiary)
                    .frame(width: 8, height: 8)

                Text(isEnabled ? "Enabled" : "Disabled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEnabled ? .bscSuccess : .bscTextTertiary)
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
                        .font(.system(size: 28))
                        .foregroundColor(.bscError)
                }
                .padding(.top, BSCSpacing.xl)

                Text("Delete Account")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("This permanently deletes your account and all associated data. This cannot be undone.")
                    .font(.system(size: 15))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BSCSpacing.lg)

                VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                    (Text("Type ").foregroundColor(.bscTextSecondary)
                     + Text(username).fontWeight(.bold).foregroundColor(.bscTextPrimary)
                     + Text(" to confirm").foregroundColor(.bscTextSecondary))
                        .font(.system(size: 13))

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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(matches ? Color.bscError : Color.bscError.opacity(0.4))
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
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.bscTextPrimary)
                            Text("Contribute training clips so the volleyball model gets better over time.")
                                .font(.system(size: 15))
                                .foregroundColor(.bscTextSecondary)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.md) {
                            ForEach(bullets, id: \.icon) { bullet in
                                HStack(alignment: .top, spacing: BSCSpacing.md) {
                                    Image(systemName: bullet.icon)
                                        .font(.system(size: 16))
                                        .foregroundColor(.bscPrimary)
                                        .frame(width: 24)
                                    Text(bullet.text)
                                        .font(.system(size: 14))
                                        .foregroundColor(.bscTextPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Link("Privacy Policy", destination: URL(string: "https://bumpsetcut.com/privacy")!)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.bscPrimary)

                        Button {
                            onAccept()
                        } label: {
                            Text("Turn On Contributions")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(Color.bscPrimary)
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
