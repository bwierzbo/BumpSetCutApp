import SwiftUI

// MARK: - Rally Action Buttons
/// Bottom action row of the rally player. The caller anchors it to the bottom
/// of the player chrome.
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
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    private var isPortrait: Bool { verticalSizeClass == .regular }

    /// Four circles share one row, so they grow with Dynamic Type only a
    /// little; the Large Content Viewer covers larger sizes.
    private var scale: CGFloat { min(textScale, RallyActionButton.maxScale) }

    var body: some View {
        HStack(spacing: scale > 1 ? BSCSpacing.lg : BSCSpacing.xl) {
            RallyActionButton(
                icon: "xmark",
                color: .bscError,
                size: .large,
                scale: scale,
                isActive: isRemoved,
                action: onRemove
            )
            .accessibilityLabel("Remove rally")
            .accessibilityValue(isRemoved ? "Removed" : "")
            .accessibilityAddTraits(isRemoved ? .isSelected : [])
            .accessibilityIdentifier(AccessibilityID.RallyPlayer.remove)
            .id("remove-\(isRemoved)")

            RallyActionButton(
                icon: "arrow.uturn.backward",
                color: .bscOnMediaSecondary,
                size: .medium,
                scale: scale,
                isActive: false,
                action: onUndo
            )
            .opacity(canUndo ? 1.0 : 0.4)
            .disabled(!canUndo)
            .accessibilityLabel("Undo")
            .accessibilityValue(canUndo ? "Available" : "No action to undo")
            .accessibilityIdentifier(AccessibilityID.RallyPlayer.undo)
            .id("undo-\(canUndo)")

            // Button equivalent of swipe-up
            RallyActionButton(
                icon: isFavorited ? "star.fill" : "star",
                color: .bscPrimary,
                size: .medium,
                scale: scale,
                isActive: isFavorited,
                action: onFavorite
            )
            .accessibilityLabel(isFavorited ? "Favorited rally" : "Favorite rally")
            .accessibilityAddTraits(isFavorited ? .isSelected : [])
            .accessibilityIdentifier(AccessibilityID.RallyPlayer.favorite)
            .id("favorite-\(isFavorited)")

            RallyActionButton(
                icon: isSaved ? "heart.fill" : "heart",
                color: .bscSuccessFill,
                size: .large,
                scale: scale,
                isActive: isSaved,
                action: onSave
            )
            .accessibilityLabel(isSaved ? "Unsave rally" : "Save rally")
            .accessibilityAddTraits(isSaved ? .isSelected : [])
            .accessibilityIdentifier(AccessibilityID.RallyPlayer.save)
            .id("save-\(isSaved)")
        }
        .padding(.bottom, isPortrait ? 60 : 20)
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
            case .medium: return BSCIconSize.md
            case .large: return 28
            }
        }
    }

    /// Upper bound on Dynamic Type growth for the action row.
    static let maxScale: CGFloat = 1.1

    let icon: String
    let color: Color
    let size: Size
    /// Dynamic Type factor (already capped) applied to circle and glyph
    /// together, so the glyph can never outgrow its circle.
    let scale: CGFloat
    let isActive: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var circleSize: CGFloat { size.frameSize * scale }

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
                                startRadius: circleSize / 2,
                                endRadius: circleSize / 2 + 20
                            )
                        )
                        .frame(width: circleSize + 40, height: circleSize + 40)
                }

                // Glass background
                Circle()
                    .fill(
                        isActive
                            ? color.opacity(0.9)
                            : Color.bscMediaScrim
                    )
                    .frame(width: circleSize, height: circleSize)
                    .overlay(
                        Circle()
                            .stroke(Color.bscOnMedia.opacity(0.4), lineWidth: 1.5)
                    )
                    .shadow(
                        color: isActive ? color.opacity(0.5) : BSCShadow.md.color,
                        radius: BSCShadow.md.radius,
                        x: BSCShadow.md.x,
                        y: BSCShadow.md.y
                    )

                // Sized with the circle (not bscFont) so it can't clip.
                Image(systemName: icon)
                    .font(.system(size: size.iconSize * scale, weight: .bold))
                    .foregroundColor(.bscOnMedia)
            }
        }
        .buttonStyle(RallyActionButtonStyle())
        // Fixed container (circle + room for the active scale) prevents layout shift.
        .frame(width: circleSize + 10, height: circleSize + 10)
        .accessibilityShowsLargeContentViewer()
        // Reduce Motion: the active state is the fill and glow — no bounce.
        .scaleEffect(isActive && !reduceMotion ? 1.15 : 1.0)
        .animation(reduceMotion ? .bscQuick : .bscBounce, value: isActive)
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
/// Toast confirming a rally action. The caller places it just above the
/// action row; RallyActionManager announces the message for VoiceOver.
struct RallyActionFeedbackView: View {
    let feedback: RallyActionFeedback
    let isShowing: Bool
    /// Optional tappable action appended to the toast capsule (e.g. "Choose
    /// Folder" on a favorite). When nil the toast is purely visual and lets
    /// every touch pass through to the player.
    var actionLabel: String? = nil
    var onAction: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
            .accessibilityHidden(true)

            Text(feedback.message)
                .bscFont(size: 16, weight: .semibold)
                .foregroundColor(.bscOnMedia)

            if let actionLabel, let onAction {
                Button(action: onAction) {
                    Text(actionLabel)
                        .bscFont(size: 15, weight: .bold)
                        .foregroundColor(feedback.type.feedbackColor)
                        .padding(.horizontal, BSCSpacing.md)
                        .padding(.vertical, BSCSpacing.sm)
                        .background(
                            Capsule().fill(feedback.type.feedbackColor.opacity(0.18))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.RallyPlayer.chooseFolder)
            }
        }
        .padding(.horizontal, BSCSpacing.xl)
        .padding(.vertical, BSCSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                .fill(Color.bscMediaScrim)
                .overlay(
                    RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                        .stroke(feedback.type.feedbackColor.opacity(0.4), lineWidth: 2)
                )
        )
        .bscShadow(BSCShadow.lg)
        // Reduce Motion: fade only, no grow-in.
        .scaleEffect(isShowing || reduceMotion ? 1.0 : 0.8)
        .opacity(isShowing ? 1.0 : 0.0)
        .animation(reduceMotion ? .bscQuick : .bscBounce, value: isShowing)
        // Purely-visual toasts pass every touch through to the player; with an
        // action only the capsule itself is tappable.
        .allowsHitTesting(onAction != nil)
    }
}

// MARK: - Action Type Extension
extension RallyActionFeedback.ActionType {
    var feedbackColor: Color {
        switch self {
        case .save:
            return .bscSuccessText
        case .remove:
            return .bscErrorText
        case .undo:
            return .bscPrimaryText
        case .favorite:
            return .bscPrimaryText
        case .trim:
            return .bscWarningText
        }
    }
}

// MARK: - Preview
#Preview("RallyActionButtons") {
    ZStack(alignment: .bottom) {
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
    ZStack(alignment: .bottom) {
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
