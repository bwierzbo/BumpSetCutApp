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

                        // Processing section
                        processingSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.2), value: hasAppeared)

                        // Privacy section
                        privacySection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.25), value: hasAppeared)

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
                        if let remaining = subscriptionService.remainingProcessingCredits() {
                            LimitRow(
                                icon: "waveform",
                                title: "Weekly Processing",
                                value: "\(remaining) of \(SubscriptionService.weeklyProcessingLimit) remaining"
                            )
                        }

                        LimitRow(
                            icon: "arrow.up.doc",
                            title: "Max Video Size",
                            value: "\(SubscriptionService.maxVideoSizeMB)MB"
                        )

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

// MARK: - Processing Section
private extension SettingsView {
    var processingSection: some View {
        @Bindable var appSettings = appSettings
        return BSCSettingsSection(title: "Processing", icon: "brain.head.profile", iconColor: .purple) {
            BSCSettingsToggle(
                title: "Thorough Analysis",
                subtitle: "Slower but more detailed rally detection with trajectory tracking",
                icon: "waveform.path.ecg",
                isOn: $appSettings.useThoroughAnalysis
            )
            .accessibilityIdentifier(AccessibilityID.Settings.thoroughAnalysis)
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
                    .alert("Delete Account", isPresented: $showDeleteConfirmation) {
                        Button("Cancel", role: .cancel) { }
                        Button("Delete", role: .destructive) {
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
                    } message: {
                        Text("This will permanently delete your account and all associated data. This cannot be undone.")
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
                    title: "Thorough Analysis",
                    isEnabled: appSettings.useThoroughAnalysis
                )

                Divider()
                    .background(Color.bscSurfaceBorder)

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

// MARK: - Preview
#Preview("SettingsView") {
    SettingsView()
        .environment(AppSettings.shared)
        .environment(AuthenticationService())
}
