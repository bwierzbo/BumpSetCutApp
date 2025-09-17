//
//  SettingsView.swift
//  BumpSetCut
//
//  App settings and feature toggles interface
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(.blue)
                                .font(.title2)
                            Text("Rally Player Interface")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }

                        Text("Choose between the new swipeable rally player or the classic interface.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)

                    Toggle(isOn: $appSettings.useTikTokRallyView) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TikTok-Style Rally Player")
                                .font(.body)
                            Text("Swipe through rallies with automatic looping")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.blue)

                } header: {
                    Text("Video Playback")
                }

                #if DEBUG
                Section {
                    Toggle("Debug Features", isOn: $appSettings.enableDebugFeatures)
                    Toggle("Performance Metrics", isOn: $appSettings.showPerformanceMetrics)
                } header: {
                    Text("Debug (Debug Builds Only)")
                } footer: {
                    Text("Debug features are only available in development builds.")
                }
                #endif

                Section {
                    Toggle("Analytics", isOn: $appSettings.enableAnalytics)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Analytics help improve the app by tracking usage patterns. No personal data is collected.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Settings")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 4) {
                            SettingStatusRow(
                                title: "Rally Player",
                                value: appSettings.useTikTokRallyView ? "TikTok-Style" : "Classic",
                                color: appSettings.useTikTokRallyView ? .blue : .orange
                            )

                            SettingStatusRow(
                                title: "Analytics",
                                value: appSettings.enableAnalytics ? "Enabled" : "Disabled",
                                color: appSettings.enableAnalytics ? .green : .gray
                            )

                            #if DEBUG
                            SettingStatusRow(
                                title: "Debug Features",
                                value: appSettings.enableDebugFeatures ? "Enabled" : "Disabled",
                                color: appSettings.enableDebugFeatures ? .purple : .gray
                            )
                            #endif
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Status")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct SettingStatusRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)

                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(color)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppSettings.shared)
    }
}
#endif