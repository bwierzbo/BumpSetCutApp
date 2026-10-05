import SwiftUI

// MARK: - Rally Player Overlay
/// Top chrome bar of the rally player: rally counter on the leading edge,
/// share / help / close on the trailing edge. The caller positions it.
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

    /// Circular chrome buttons grow with Dynamic Type so their glyphs never clip.
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = BSCTouchTarget.standard

    var body: some View {
        HStack(alignment: .top, spacing: BSCSpacing.sm) {
            rallyCounter

            Spacer(minLength: 0)

            shareButton

            helpButton

            BSCMediaCloseButton(action: onDismiss)
                .accessibilityIdentifier(AccessibilityID.RallyPlayer.back)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.top, BSCSpacing.md)
        // Four controls share one row: past xxxLarge they can't all fit.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
            .frame(width: buttonSize, height: buttonSize)
            .background(chromeCircle)
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
                .foregroundColor(.bscOnMedia)
                .frame(width: buttonSize, height: buttonSize)
                .background(chromeCircle)
        }
        .accessibilityLabel("Help")
        .accessibilityHint("Shows gesture tips")
        .accessibilityIdentifier(AccessibilityID.RallyPlayer.help)
    }

    private var chromeCircle: some View {
        Circle()
            .fill(Color.bscMediaScrim)
            .overlay(
                Circle()
                    .stroke(Color.bscOnMedia.opacity(0.4), lineWidth: 1)
            )
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

                Text(verbatim: (currentIndex + 1).formatted())
                    .bscFont(size: 16, weight: .bold)
                    .foregroundColor(.bscOnMedia)
                    .contentTransition(.numericText())

                Text(verbatim: "/")
                    .bscFont(size: 14)
                    .foregroundColor(.bscOnMedia)

                Text(verbatim: totalCount.formatted())
                    .bscFont(size: 14, weight: .medium)
                    .foregroundColor(.bscOnMedia)

                Image(systemName: "square.grid.2x2")
                    .bscFont(size: 11, weight: .semibold)
                    .foregroundColor(.bscOnMediaSecondary)
                    .padding(.leading, BSCSpacing.xxs)
            }
            .padding(.horizontal, BSCSpacing.lg)
            .frame(minHeight: buttonSize)
            .background(
                Capsule()
                    .fill(Color.bscMediaScrim)
                    .overlay(
                        Capsule()
                            .stroke(statusBorderColor, lineWidth: isSaved || isRemoved || isFavorited ? 2 : 1)
                    )
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Rally \(currentIndex + 1) of \(totalCount)"))
        .accessibilityValue(statusDescription)
        .accessibilityHint("Shows the rally overview")
        .accessibilityAction { onShowOverview() }
        .accessibilityIdentifier(AccessibilityID.RallyPlayer.counter)
        .animation(.bscStandard, value: currentIndex)
        .animation(.bscQuick, value: isSaved)
        .animation(.bscQuick, value: isRemoved)
        .animation(.bscQuick, value: isFavorited)
    }

    /// Spoken status — the border color alone carries it visually.
    private var statusDescription: String {
        var parts: [String] = []
        if isSaved { parts.append(String(localized: "Saved", comment: "Rally review status")) }
        if isRemoved { parts.append(String(localized: "Removed", comment: "Rally review status")) }
        if isFavorited { parts.append(String(localized: "Favorited", comment: "Rally review status")) }
        return parts.isEmpty
            ? String(localized: "Not reviewed", comment: "Rally review status")
            : parts.formatted(.list(type: .and, width: .narrow))
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
    ZStack(alignment: .top) {
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
