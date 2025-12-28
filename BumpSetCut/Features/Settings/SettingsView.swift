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

                        // Privacy section
                        privacySection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.15), value: hasAppeared)

                        // Status section
                        statusSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.2), value: hasAppeared)

                        // App info section
                        appInfoSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.25), value: hasAppeared)

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
        .preferredColorScheme(.dark)
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
}
