//
//  SettingsComponents.swift
//  BumpSetCut
//
//  Rows and containers the Settings screen is built from.
//

import SwiftUI

// MARK: - Limit Row
struct LimitRow: View {
    let icon: String
    let title: LocalizedStringResource
    let value: LocalizedStringResource

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

// MARK: - BSCSettingsSection
struct BSCSettingsSection<Content: View>: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource? = nil
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
                    // A localized Text exposes .textCase to accessibility;
                    // a verbatim label keeps the written case.
                    .accessibilityLabel(Text(verbatim: String(localized: title)))

                if let subtitle = subtitle {
                    (Text(verbatim: "(") + Text(subtitle) + Text(verbatim: ")"))
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
struct BSCSettingsToggle: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
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
        .accessibilityLabel(Text(title) + Text(verbatim: ", ") + Text(subtitle))
    }
}

// MARK: - BSCStatusRow
struct BSCStatusRow: View {
    let title: LocalizedStringResource
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
