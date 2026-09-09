import SwiftUI

/// Pills and banners cap at 500pt wide by convention (see design-system.md).
private let pillMaxWidth: CGFloat = 500
private let ringLineWidth: CGFloat = 2.5

// MARK: - BSCProgressRing
/// Compact circular progress indicator used inside status pills: a
/// `bscSurfaceBorder` track with a `bscPrimary` trim starting at 12 o'clock,
/// and an arbitrary glyph or label centered inside.
struct BSCProgressRing<Center: View>: View {
    let progress: Double
    private let center: Center

    init(progress: Double, @ViewBuilder center: () -> Center) {
        self.progress = progress
        self.center = center()
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.bscSurfaceBorder, lineWidth: ringLineWidth)
                .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.bscPrimary, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                .rotationEffect(.degrees(-90))

            center
        }
    }
}

// MARK: - BSCStatusPillLabel
/// The standard pill text stack: 13pt-semibold title (with an optional inline
/// accessory glyph after it) over an 11pt single-line secondary subtitle.
struct BSCStatusPillLabel<Accessory: View>: View {
    let title: String
    let subtitle: String?
    private let accessory: Accessory

    init(title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
            HStack(spacing: BSCSpacing.xxs) {
                Text(title)
                    .bscFont(size: 13, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                accessory
            }

            if let subtitle {
                Text(subtitle)
                    .bscFont(size: 11)
                    .foregroundColor(.bscTextSecondary)
                    .lineLimit(1)
            }
        }
    }
}

extension BSCStatusPillLabel where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - BSCStatusPill
/// Floating status pill/banner shown above the tab bar (uploads, processing,
/// storage warnings): leading indicator + label stack + trailing element on the
/// standard elevated chrome, capped at 500pt wide with a 44pt minimum height.
///
/// Layout notes for call sites:
/// - Content hugs and centers when it fits; include a `Spacer()` in `trailing`
///   to push the trailing element to the edge (progress pills do, completion
///   states stay centered).
/// - `borderColor` swaps the hairline `bscSurfaceBorder` stroke for a status
///   stroke (e.g. the low-storage banner's warning border).
struct BSCStatusPill<Leading: View, Content: View, Trailing: View>: View {
    private let borderColor: Color?
    private let leading: Leading
    private let content: Content
    private let trailing: Trailing

    init(
        borderColor: Color? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.borderColor = borderColor
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        chromed
            .padding(.horizontal, BSCSpacing.lg)
    }

    private var framed: some View {
        HStack(spacing: BSCSpacing.sm) {
            leading
            content
            trailing
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
        .frame(maxWidth: pillMaxWidth, minHeight: BSCTouchTarget.standard)
    }

    @ViewBuilder
    private var chromed: some View {
        if let borderColor {
            framed
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                        .fill(Color.bscBackgroundElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .bscShadow(BSCShadow.md)
        } else {
            framed
                .bscSurfaceChrome(cornerRadius: BSCRadius.lg)
        }
    }
}

extension BSCStatusPill where Content == BSCStatusPillLabel<EmptyView> {
    /// Standard pill with the title/subtitle label stack as its content.
    init(
        title: String,
        subtitle: String? = nil,
        borderColor: Color? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(borderColor: borderColor, leading: leading, content: {
            BSCStatusPillLabel(title: title, subtitle: subtitle)
        }, trailing: trailing)
    }
}

// MARK: - Preview
#Preview("BSCStatusPill") {
    VStack(spacing: BSCSpacing.lg) {
        // In-progress pill with ring + percentage
        BSCStatusPill(
            title: "Uploading beach-finals.mov…",
            subtitle: "keep the app open",
            leading: {
                BSCProgressRing(progress: 0.42) {
                    Image(systemName: "arrow.up")
                        .bscFont(size: 9, weight: .bold)
                        .foregroundColor(.bscPrimary)
                }
            },
            trailing: {
                Spacer()
                Text("42%")
                    .bscFont(size: 14, weight: .bold, design: .monospaced)
                    .foregroundColor(.bscPrimaryText)
            }
        )

        // Centered completion state (no trailing spacer)
        BSCStatusPill(title: "Processing complete!") {
            Image(systemName: "checkmark.circle.fill")
                .bscFont(size: 20)
                .foregroundColor(.bscSuccessText)
        } trailing: {}

        // Warning banner with border override and bespoke content
        BSCStatusPill(borderColor: Color.bscWarning.opacity(0.4)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .bscFont(size: 16)
                .foregroundColor(.bscWarningText)
        } content: {
            Text("Storage nearly full — 900 MB remaining. Free up space to avoid issues.")
                .bscFont(size: 12, weight: .medium)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(2)
        } trailing: {
            Spacer(minLength: 0)
            Button {} label: {
                Image(systemName: "xmark")
                    .bscFont(size: 12, weight: .bold)
                    .foregroundColor(.bscTextSecondary)
                    .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
    }
    .padding(.vertical, BSCSpacing.xl)
    .frame(maxWidth: .infinity)
    .background(Color.bscBackground)
}
