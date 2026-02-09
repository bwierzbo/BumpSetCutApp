//
//  SettingsView.swift
//  BumpSetCut
//
//  App settings and feature toggles interface
//

import SwiftUI

// MARK: - SettingsView
struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.bscBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.xl) {
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

                        // App info section
                        appInfoSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.4), value: hasAppeared)

                        Spacer(minLength: BSCSpacing.huge)
                    }
                    .padding(BSCSpacing.lg)
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
                    .foregroundColor(.bscOrange)
                }
            }
            .onAppear {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
    }
}

// MARK: - Debug Section
#if DEBUG
private extension SettingsView {
    var debugSection: some View {
        BSCSettingsSection(title: "Debug", subtitle: "Debug builds only", icon: "ladybug.fill", iconColor: .bscTeal) {
            VStack(spacing: BSCSpacing.md) {
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
        BSCSettingsSection(title: "Appearance", icon: "paintbrush.fill", iconColor: .bscOrange) {
            VStack(spacing: BSCSpacing.md) {
                HStack(spacing: BSCSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.bscOrange.opacity(0.15))
                            .frame(width: 36, height: 36)

                        Image(systemName: appSettings.appearanceMode == .dark ? "moon.fill" :
                                appSettings.appearanceMode == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                            .font(.system(size: 16))
                            .foregroundColor(.bscOrange)
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
                                                .stroke(appSettings.appearanceMode == theme ? Color.bscOrange : Color.bscSurfaceBorder, lineWidth: appSettings.appearanceMode == theme ? 2 : 1)
                                        )

                                    Image(systemName: theme == .dark ? "moon.fill" :
                                            theme == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                                        .font(.system(size: 18))
                                        .foregroundColor(theme == .dark ? .white : theme == .light ? Color(hex: "#1A1A1C") : .bscOrange)
                                }

                                Text(theme.rawValue)
                                    .font(.system(size: 12, weight: appSettings.appearanceMode == theme ? .semibold : .regular))
                                    .foregroundColor(appSettings.appearanceMode == theme ? .bscOrange : .bscTextSecondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Processing Section
private extension SettingsView {
    var processingSection: some View {
        BSCSettingsSection(title: "Processing", icon: "brain.head.profile", iconColor: .purple) {
            BSCSettingsToggle(
                title: "Thorough Analysis",
                subtitle: "Slower but more detailed rally detection with trajectory tracking",
                icon: "waveform.path.ecg",
                isOn: $appSettings.useThoroughAnalysis
            )
        }
    }
}

// MARK: - Privacy Section
private extension SettingsView {
    var privacySection: some View {
        BSCSettingsSection(title: "Privacy", icon: "lock.shield.fill", iconColor: .bscBlue) {
            BSCSettingsToggle(
                title: "Analytics",
                subtitle: "Help improve the app with anonymous usage data",
                icon: "chart.bar.fill",
                isOn: $appSettings.enableAnalytics
            )
        }
    }
}

// MARK: - Social & Privacy Section
private extension SettingsView {
    var socialPrivacySection: some View {
        BSCSettingsSection(title: "Social & Privacy", icon: "person.2.circle.fill", iconColor: .bscOrange) {
            VStack(spacing: BSCSpacing.md) {
                if authService.authState == .authenticated {
                    // Account row
                    HStack(spacing: BSCSpacing.md) {
                        ZStack {
                            Circle()
                                .fill(Color.bscOrange.opacity(0.15))
                                .frame(width: 36, height: 36)

                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.bscOrange)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                            Text(authService.currentUser?.displayName ?? "Account")
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

                    Divider()
                        .background(Color.bscSurfaceBorder)

                    // Delete account button
                    Button {
                        // Confirmation alert added in future iteration
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.8))
                            Text("Delete Account")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.red.opacity(0.8))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    // Not signed in state
                    HStack(spacing: BSCSpacing.md) {
                        ZStack {
                            Circle()
                                .fill(Color.bscOrange.opacity(0.15))
                                .frame(width: 36, height: 36)

                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.bscOrange)
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

// MARK: - App Info Section
private extension SettingsView {
    var appInfoSection: some View {
        BSCSettingsSection(title: "About", icon: "info.circle.fill", iconColor: .bscOrange) {
            VStack(spacing: BSCSpacing.lg) {
                // App logo
                ZStack {
                    Circle()
                        .fill(Color.bscOrange.opacity(0.15))
                        .frame(width: 64, height: 64)

                    Image(systemName: "figure.volleyball")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.bscOrange)
                }

                VStack(spacing: BSCSpacing.xs) {
                    Text("BumpSetCut")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.bscTextPrimary)

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
                .tint(.bscOrange)
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
        .environmentObject(AppSettings.shared)
        .environment(AuthenticationService())
}
