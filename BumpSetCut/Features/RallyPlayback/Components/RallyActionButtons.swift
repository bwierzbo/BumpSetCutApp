import SwiftUI

// MARK: - Rally Action Buttons
struct RallyActionButtons: View {
    let isSaved: Bool
    let isRemoved: Bool
    var isFavorited: Bool = false
    let canUndo: Bool
    let onRemove: () -> Void
    let onUndo: () -> Void
    var onFavorite: () -> Void = {}
    let onSave: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool { verticalSizeClass == .regular }

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: BSCSpacing.xl) {
                // Remove button - fixed container prevents layout shift
                RallyActionButton(
                    icon: "xmark",
                    color: .bscError,
                    size: .large,
                    isActive: isRemoved,
                    action: onRemove
                )
                .frame(width: 80, height: 80)
                .accessibilityLabel("Remove rally")
                .accessibilityIdentifier(AccessibilityID.RallyPlayer.remove)
                .id("remove-\(isRemoved)")

                // Undo button - fixed container
                RallyActionButton(
                    icon: "arrow.uturn.backward",
                    color: .bscTextSecondary,
                    size: .medium,
                    isActive: false,
                    action: onUndo
                )
                .frame(width: 65, height: 65)
                .opacity(canUndo ? 1.0 : 0.4)
                .disabled(!canUndo)
                .accessibilityLabel("Undo")
                .accessibilityValue(canUndo ? "Available" : "No action to undo")
                .accessibilityIdentifier(AccessibilityID.RallyPlayer.undo)
                .id("undo-\(canUndo)")

                // Favorite button - fixed container (button equivalent of swipe-up)
                RallyActionButton(
                    icon: isFavorited ? "star.fill" : "star",
                    color: .bscPrimary,
                    size: .medium,
                    isActive: isFavorited,
                    action: onFavorite
                )
                .frame(width: 65, height: 65)
                .accessibilityLabel(isFavorited ? "Favorited rally" : "Favorite rally")
                .accessibilityIdentifier(AccessibilityID.RallyPlayer.favorite)
                .id("favorite-\(isFavorited)")

                // Save button - fixed container
                RallyActionButton(
                    icon: isSaved ? "heart.fill" : "heart",
                    color: .bscSuccess,
                    size: .large,
                    isActive: isSaved,
                    action: onSave
                )
                .frame(width: 80, height: 80)
                .accessibilityLabel(isSaved ? "Unsave rally" : "Save rally")
                .accessibilityIdentifier(AccessibilityID.RallyPlayer.save)
                .id("save-\(isSaved)")
            }
            .padding(.bottom, isPortrait ? 60 : 20)
        }
    }
}

// MARK: - Rally Action Button
private struct RallyActionButton: View {
    enum Size {
        case medium
        case large

        var frameSize: CGFloat {
            switch self {
            case .medium: return 56
            case .large: return 70
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .medium: return 20
            case .large: return 28
            }
        }
    }

    let icon: String
    let color: Color
    let size: Size
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow ring (when active)
                if isActive {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [color.opacity(0.4), Color.clear],
                                center: .center,
                                startRadius: size.frameSize / 2,
                                endRadius: size.frameSize / 2 + 20
                            )
                        )
                        .frame(width: size.frameSize + 40, height: size.frameSize + 40)
                }

                // Glass background
                Circle()
                    .fill(
                        isActive
                            ? color.opacity(0.9)
                            : Color.bscSurfaceGlass
                    )
                    .frame(width: size.frameSize, height: size.frameSize)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.bscOnMedia.opacity(0.3),
                                        Color.bscOnMedia.opacity(0.1),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: isActive ? color.opacity(0.5) : Color.bscMediaScrimBase.opacity(0.3), radius: 8, x: 0, y: 4)

                // Icon
                Image(systemName: icon)
                    .bscFont(size: size.iconSize, weight: .bold)
                    .foregroundColor(.bscOnMedia)
            }
        }
        .buttonStyle(RallyActionButtonStyle())
        .scaleEffect(isActive ? 1.15 : 1.0)
        .animation(.bscBounce, value: isActive)
    }
}

// MARK: - Button Style
private struct RallyActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            // Parent view handles animation timing - removed to avoid double-animation conflict
    }
}

// MARK: - Action Feedback View
struct RallyActionFeedbackView: View {
    let feedback: RallyActionFeedback
    let isShowing: Bool

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool { verticalSizeClass == .regular }

    var body: some View {
        VStack {
            if isPortrait {
                Spacer()
            } else {
                Spacer().frame(height: 60)
            }

            // Feedback toast
            HStack(spacing: BSCSpacing.md) {
                // Icon with glow
                ZStack {
                    Circle()
                        .fill(feedback.type.feedbackColor.opacity(0.2))
                        .frame(width: 40, height: 40)

                    Image(systemName: feedback.type.iconName)
                        .bscFont(size: 20, weight: .bold)
                        .foregroundColor(feedback.type.feedbackColor)
                }

                Text(feedback.message)
                    .bscFont(size: 16, weight: .semibold)
                    .foregroundColor(.bscOnMedia)
            }
            .padding(.horizontal, BSCSpacing.xl)
            .padding(.vertical, BSCSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                    .fill(Color.bscSurfaceGlass)
                    .overlay(
                        RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                            .stroke(feedback.type.feedbackColor.opacity(0.4), lineWidth: 2)
                    )
            )
            .bscShadow(BSCShadow.lg)
            .scaleEffect(isShowing ? 1.0 : 0.8)
            .opacity(isShowing ? 1.0 : 0.0)
            .animation(.bscBounce, value: isShowing)

            if isPortrait {
                Spacer()
                    .frame(height: 190)  // Spacing to clear buttons
            } else {
                Spacer()
            }
        }
    }
}

// MARK: - Action Type Extension
extension RallyActionFeedback.ActionType {
    var feedbackColor: Color {
        switch self {
        case .save:
            return .bscSuccess
        case .remove:
            return .bscError
        case .undo:
            return .bscBlue
        case .favorite:
            return .bscPrimary
        case .trim:
            return .bscWarning
        }
    }
}

// MARK: - Preview
#Preview("RallyActionButtons") {
    ZStack {
        Color.bscMediaBackground
        RallyActionButtons(
            isSaved: false,
            isRemoved: false,
            canUndo: true,
            onRemove: {},
            onUndo: {},
            onSave: {}
        )
    }
}

#Preview("RallyActionButtons - Saved") {
    ZStack {
        Color.bscMediaBackground
        RallyActionButtons(
            isSaved: true,
            isRemoved: false,
            canUndo: true,
            onRemove: {},
            onUndo: {},
            onSave: {}
        )
    }
}
