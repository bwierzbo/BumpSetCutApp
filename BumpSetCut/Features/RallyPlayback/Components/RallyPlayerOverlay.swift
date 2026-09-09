import SwiftUI

// MARK: - Rally Player Overlay
struct RallyPlayerOverlay: View {
    let currentIndex: Int
    let totalCount: Int
    let isSaved: Bool
    let isRemoved: Bool
    var isFavorited: Bool = false
    let onDismiss: () -> Void
    var onShowTips: () -> Void = {}
    var onShowOverview: () -> Void = {}
    var onShare: () -> Void = {}
    var isPreparingShare: Bool = false

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                // Back button
                backButton

                Spacer()

                // Rally counter with status + quick actions
                HStack(spacing: BSCSpacing.sm) {
                    shareButton

                    rallyCounter

                    // Help/Tips button
                    helpButton
                }
            }
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.top, BSCSpacing.md)

            Spacer()
        }
    }

    // MARK: - Share Button
    private var shareButton: some View {
        Button(action: onShare) {
            Group {
                if isPreparingShare {
                    ProgressView()
                        .tint(.bscOnMedia)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .bscFont(size: 16, weight: .medium)
                        .foregroundColor(.bscOnMedia)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                Circle()
                    .fill(Color.bscMediaScrim)
                    .overlay(
                        Circle()
                            .stroke(Color.bscOnMedia.opacity(0.4), lineWidth: 1)
                    )
            )
        }
        .disabled(isPreparingShare)
        .accessibilityLabel("Share rally")
        .accessibilityIdentifier("rallyPlayer.share")
    }

    // MARK: - Help Button
    private var helpButton: some View {
        Button(action: onShowTips) {
            Image(systemName: "questionmark.circle")
                .bscFont(size: 16, weight: .medium)
                .foregroundColor(.bscOnMediaSecondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.bscOnMedia.opacity(0.1))
                        .overlay(
                            Circle()
                                .stroke(Color.bscOnMedia.opacity(0.4), lineWidth: 1)
                        )
                )
        }
        .accessibilityLabel("Help")
        .accessibilityHint("Show gesture tips")
        .accessibilityIdentifier(AccessibilityID.RallyPlayer.help)
    }

    // MARK: - Back Button
    private var backButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "chevron.left")
                .bscFont(size: 18, weight: .semibold)
                .foregroundColor(.bscOnMedia)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.bscMediaScrim)
                        .overlay(
                            Circle()
                                .stroke(Color.bscOnMedia.opacity(0.4), lineWidth: 1)
                        )
                )
        }
        .accessibilityLabel("Back")
        .accessibilityHint("Return to library")
        .accessibilityIdentifier(AccessibilityID.RallyPlayer.back)
    }

    // MARK: - Rally Counter
    private var rallyCounter: some View {
        Button(action: onShowOverview) {
            HStack(spacing: BSCSpacing.xxs) {
                if isFavorited {
                    Image(systemName: "star.fill")
                        .bscFont(size: 12, weight: .bold)
                        .foregroundColor(.bscOnMedia)
                }

                Text("\(currentIndex + 1)")
                    .bscFont(size: 16, weight: .bold)
                    .foregroundColor(.bscOnMedia)
                    .contentTransition(.numericText())

                Text("/")
                    .bscFont(size: 14)
                    .foregroundColor(.bscOnMediaSecondary)

                Text("\(totalCount)")
                    .bscFont(size: 14, weight: .medium)
                    .foregroundColor(.bscOnMediaSecondary)

                Image(systemName: "square.grid.2x2")
                    .bscFont(size: 11, weight: .semibold)
                    .foregroundColor(.bscOnMediaSecondary)
                    .padding(.leading, BSCSpacing.xxs)
            }
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.sm)
            .background(
                Capsule()
                    .fill(Color.bscMediaScrim)
                    .overlay(
                        Capsule()
                            .stroke(statusBorderColor, lineWidth: isSaved || isRemoved || isFavorited ? 2 : 1)
                    )
            )
        }
        .accessibilityLabel("Rally \(currentIndex + 1) of \(totalCount)")
        .accessibilityHint("Tap to see rally overview")
        .accessibilityIdentifier(AccessibilityID.RallyPlayer.counter)
        .animation(.bscStandard, value: currentIndex)
        .animation(.bscQuick, value: isSaved)
        .animation(.bscQuick, value: isRemoved)
        .animation(.bscQuick, value: isFavorited)
    }

    private var statusBorderColor: Color {
        if isFavorited {
            return .bscPrimary.opacity(0.6)
        } else if isSaved {
            return .bscSuccess.opacity(0.6)
        } else if isRemoved {
            return .bscError.opacity(0.6)
        } else {
            return Color.bscOnMedia.opacity(0.4)
        }
    }
}

// MARK: - Preview
#Preview("RallyPlayerOverlay") {
    ZStack {
        Color.bscMediaBackground
        RallyPlayerOverlay(
            currentIndex: 2,
            totalCount: 10,
            isSaved: true,
            isRemoved: false,
            onDismiss: {}
        )
    }
}
