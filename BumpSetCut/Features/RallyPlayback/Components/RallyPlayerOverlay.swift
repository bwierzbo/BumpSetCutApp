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

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                // Back button
                backButton

                Spacer()

                // Rally counter with status
                HStack(spacing: BSCSpacing.sm) {
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

    // MARK: - Help Button
    private var helpButton: some View {
        Button(action: onShowTips) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.bscSurfaceGlass)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.bscPrimary)
                }

                Text("\(currentIndex + 1)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())

                Text("/")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))

                Text("\(totalCount)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.sm)
            .background(
                Capsule()
                    .fill(Color.bscSurfaceGlass)
                    .overlay(
                        Capsule()
                            .stroke(statusBorderColor, lineWidth: isSaved || isRemoved || isFavorited ? 2 : 1)
                    )
            )
        }
        .accessibilityLabel("Rally \(currentIndex + 1) of \(totalCount)")
        .accessibilityHint("Tap to see rally overview")
        .accessibilityIdentifier(AccessibilityID.RallyPlayer.counter)
        .animation(.easeInOut(duration: 0.25), value: currentIndex)
        .animation(.easeInOut(duration: 0.2), value: isSaved)
        .animation(.easeInOut(duration: 0.2), value: isRemoved)
        .animation(.easeInOut(duration: 0.2), value: isFavorited)
    }

    private var statusBorderColor: Color {
        if isFavorited {
            return .bscPrimary.opacity(0.6)
        } else if isSaved {
            return .bscSuccess.opacity(0.6)
        } else if isRemoved {
            return .bscError.opacity(0.6)
        } else {
            return .white.opacity(0.2)
        }
    }
}

// MARK: - Preview
#Preview("RallyPlayerOverlay") {
    ZStack {
        Color.black
        RallyPlayerOverlay(
            currentIndex: 2,
            totalCount: 10,
            isSaved: true,
            isRemoved: false,
            onDismiss: {}
        )
    }
}
