import SwiftUI

// MARK: - Rally Player Overlay
struct RallyPlayerOverlay: View {
    let currentIndex: Int
    let totalCount: Int
    let savedCount: Int
    let removedCount: Int
    let isSaved: Bool
    let isRemoved: Bool
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
                    // Saved/Removed tally pill (tappable -> overview)
                    selectionTally

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
                .frame(width: 36, height: 36)
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
    }

    // MARK: - Selection Tally
    private var selectionTally: some View {
        Button(action: onShowOverview) {
            HStack(spacing: BSCSpacing.xs) {
                if savedCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.bscSuccess)
                        Text("\(savedCount)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.bscSuccess)
                            .contentTransition(.numericText())
                    }
                }
                if savedCount > 0 && removedCount > 0 {
                    Text("/")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                if removedCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.bscError)
                        Text("\(removedCount)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.bscError)
                            .contentTransition(.numericText())
                    }
                }
            }
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.xs)
            .background(
                Capsule()
                    .fill(Color.bscSurfaceGlass)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .opacity(savedCount > 0 || removedCount > 0 ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.2), value: savedCount)
        .animation(.easeInOut(duration: 0.2), value: removedCount)
        .accessibilityLabel("\(savedCount) saved, \(removedCount) removed")
    }

    // MARK: - Rally Counter
    private var rallyCounter: some View {
        HStack(spacing: BSCSpacing.xxs) {
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
                        .stroke(statusBorderColor, lineWidth: isSaved || isRemoved ? 2 : 1)
                )
        )
        .animation(.easeInOut(duration: 0.25), value: currentIndex)
        .animation(.easeInOut(duration: 0.2), value: isSaved)
        .animation(.easeInOut(duration: 0.2), value: isRemoved)
    }

    private var statusBorderColor: Color {
        if isSaved {
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
            savedCount: 3,
            removedCount: 1,
            isSaved: true,
            isRemoved: false,
            onDismiss: {}
        )
    }
}
