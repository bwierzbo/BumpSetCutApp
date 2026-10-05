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

// MARK: - BallModelPicker
/// Which ball model processes videos, for comparing new models on device.
/// New models get every frame letterboxed (BallModel.needsLetterbox).
struct BallModelPicker: View {
    @AppStorage(BallModel.defaultsKey) private var selection = BallModel.shipping.rawValue

    var body: some View {
        DebugChoiceRow(title: "Ball Model", icon: "volleyball.fill",
                       options: BallModel.allCases.map { ($0.rawValue, $0.title) },
                       selection: $selection, accessibilityID: "settings.ballModel")
    }
}

// MARK: - BallFinderPicker
/// YOLO alone, YOLO plus the bundled multi-frame model, or the multi-frame
/// model alone (BallFinder), for comparing them on device.
struct BallFinderPicker: View {
    @AppStorage(BallFinder.defaultsKey) private var selection = BallFinder.yolo.rawValue

    var body: some View {
        DebugChoiceRow(title: "Ball Finder", icon: "scope",
                       options: BallFinder.allCases.map { ($0.rawValue, $0.title) },
                       selection: $selection, accessibilityID: "settings.ballFinder")
    }
}

// MARK: - DebugChoiceRow
/// A processing choice for testers: applies to videos processed from now on.
struct DebugChoiceRow: View {
    let title: LocalizedStringResource
    let icon: String
    let options: [(value: String, title: String)]
    @Binding var selection: String
    let accessibilityID: String

    var body: some View {
        HStack(spacing: BSCSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.bscBlue.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .bscFont(size: 16)
                    .foregroundColor(.bscBlue)
            }

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(title)
                    .bscFont(size: 16, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)

                Text("Used for videos processed from now on")
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextSecondary)
            }

            Spacer(minLength: BSCSpacing.sm)

            Picker(selection: $selection) {
                ForEach(options, id: \.value) { option in
                    // Model names are tester-facing identifiers, not copy.
                    Text(verbatim: option.title).tag(option.value)
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.bscPrimary)
            .accessibilityIdentifier(accessibilityID)
        }
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
