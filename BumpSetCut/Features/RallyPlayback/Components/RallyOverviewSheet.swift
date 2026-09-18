import SwiftUI

// MARK: - Rally Overview Sheet

struct RallyOverviewSheet: View {
    let rallyVideoURLs: [URL]
    let savedRallies: Set<Int>
    let removedRallies: Set<Int>
    var favoritedRallies: Set<Int> = []
    let currentIndex: Int
    let thumbnailCache: RallyThumbnailCache
    let onSelectRally: (Int) -> Void
    let onExport: () -> Void
    let onPostToCommunity: (Int, Bool) -> Void  // (rallyIndex, postAllSaved)
    let onSaveAll: () -> Void
    let onDeselectAll: () -> Void
    let onEditTimeline: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // Compact height (e.g. iPhone landscape): condense chrome so the grid stays visible.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private var columns: [GridItem] {
        let count = isCompactHeight ? 5 : 3
        return Array(
            repeating: GridItem(.flexible(), spacing: BSCSpacing.md),
            count: count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            BSCSheetGrabber()
                .padding(.top, BSCSpacing.sm)
                .padding(.bottom, isCompactHeight ? BSCSpacing.xs : BSCSpacing.md)

            // Header
            if isCompactHeight {
                compactHeaderSection
            } else {
                headerSection
            }

            // Thumbnail grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: BSCSpacing.md) {
                    ForEach(0..<rallyVideoURLs.count, id: \.self) { index in
                        Button {
                            UIImpactFeedbackGenerator.light()
                            onSelectRally(index)
                        } label: {
                            rallyCell(index: index)
                        }
                        .buttonStyle(RallyCellButtonStyle())
                        .bscStaggered(index: index)
                    }
                }
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.bottom, BSCSpacing.xl)
            }

            // Bottom action area
            bottomActions
        }
        .background(Color.bscBackground.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { appeared = true }
    }

    // MARK: - Compact Header (landscape)

    private var compactHeaderSection: some View {
        HStack(spacing: BSCSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .bscFont(size: 20, weight: .medium)
                .foregroundStyle(Color.bscSuccessText)

            // Inline stats
            HStack(spacing: BSCSpacing.md) {
                statPill(count: savedRallies.count, label: "saved", color: .bscSuccessText)
                statPill(count: removedRallies.count, label: "removed", color: .bscErrorText)
                if !favoritedRallies.isEmpty {
                    statPill(count: favoritedRallies.count, label: "favorited", color: .bscPrimaryText)
                }
            }

            Spacer(minLength: 0)

            // Quick select/deselect actions
            Button {
                UINotificationFeedbackGenerator.success()
                onSaveAll()
            } label: {
                HStack(spacing: BSCSpacing.xs) {
                    Image(systemName: "heart.fill")
                        .bscFont(size: 11, weight: .bold)
                    Text("Save All")
                        .bscFont(size: 13, weight: .semibold)
                }
                .foregroundColor(.bscSuccessText)
                .padding(.horizontal, BSCSpacing.md)
                .padding(.vertical, BSCSpacing.xs)
                .background(Color.bscSuccess.opacity(0.15))
                .clipShape(Capsule())
            }
            .disabled(savedRallies.count == rallyVideoURLs.count)
            .opacity(savedRallies.count == rallyVideoURLs.count ? 0.4 : 1.0)

            Button {
                UIImpactFeedbackGenerator.light()
                onDeselectAll()
            } label: {
                HStack(spacing: BSCSpacing.xs) {
                    Image(systemName: "arrow.uturn.backward")
                        .bscFont(size: 11, weight: .bold)
                    Text("Clear All")
                        .bscFont(size: 13, weight: .semibold)
                }
                .foregroundColor(.bscTextSecondary)
                .padding(.horizontal, BSCSpacing.md)
                .padding(.vertical, BSCSpacing.xs)
                .background(Color.bscSurfaceGlass)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                )
            }
            .disabled(savedRallies.isEmpty && removedRallies.isEmpty)
            .opacity(savedRallies.isEmpty && removedRallies.isEmpty ? 0.4 : 1.0)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.bottom, BSCSpacing.sm)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: BSCSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .bscFont(size: 48, weight: .medium)
                .foregroundStyle(Color.bscSuccessText)
                .symbolEffect(.bounce, value: appeared)

            Text("Review Complete")
                .bscFont(size: 22, weight: .bold)
                .foregroundColor(.bscTextPrimary)

            // Compact stats pill row
            HStack(spacing: BSCSpacing.lg) {
                statPill(count: savedRallies.count, label: "saved", color: .bscSuccessText)
                statPill(count: removedRallies.count, label: "removed", color: .bscErrorText)
                if !favoritedRallies.isEmpty {
                    statPill(count: favoritedRallies.count, label: "favorited", color: .bscPrimaryText)
                }
            }
            .padding(.horizontal, BSCSpacing.xl)

            // Quick select/deselect actions
            HStack(spacing: BSCSpacing.md) {
                Button {
                    UINotificationFeedbackGenerator.success()
                    onSaveAll()
                } label: {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: "heart.fill")
                            .bscFont(size: 11, weight: .bold)
                        Text("Save All")
                            .bscFont(size: 13, weight: .semibold)
                    }
                    .foregroundColor(.bscSuccessText)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscSuccess.opacity(0.15))
                    .clipShape(Capsule())
                }
                .disabled(savedRallies.count == rallyVideoURLs.count)
                .opacity(savedRallies.count == rallyVideoURLs.count ? 0.4 : 1.0)

                Button {
                    UIImpactFeedbackGenerator.light()
                    onDeselectAll()
                } label: {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: "arrow.uturn.backward")
                            .bscFont(size: 11, weight: .bold)
                        Text("Clear All")
                            .bscFont(size: 13, weight: .semibold)
                    }
                    .foregroundColor(.bscTextSecondary)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscSurfaceGlass)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                    )
                }
                .disabled(savedRallies.isEmpty && removedRallies.isEmpty)
                .opacity(savedRallies.isEmpty && removedRallies.isEmpty ? 0.4 : 1.0)
            }
        }
        .padding(.bottom, BSCSpacing.lg)
    }

    private func statPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: BSCSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .bscFont(size: 13, weight: .medium)
                .foregroundColor(.bscTextSecondary)
        }
    }

    // MARK: - Rally Cell

    private func rallyCell(index: Int) -> some View {
        let url = rallyVideoURLs[index]
        let isSaved = savedRallies.contains(index)
        let isRemoved = removedRallies.contains(index)
        let isFavorited = favoritedRallies.contains(index)

        return RallyOverviewCell(
            url: url,
            index: index,
            isSaved: isSaved,
            isRemoved: isRemoved,
            isFavorited: isFavorited,
            thumbnailCache: thumbnailCache
        )
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        Group {
            if isCompactHeight {
                compactBottomActions
            } else {
                regularBottomActions
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.top, BSCSpacing.md)
        .padding(.bottom, BSCSpacing.lg)
        .background(Color.bscBackground)
    }

    private var compactBottomActions: some View {
        HStack(spacing: BSCSpacing.md) {
            if !savedRallies.isEmpty {
                // Export to Camera Roll
                Button(action: onExport) {
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "square.and.arrow.down")
                            .bscFont(size: 15, weight: .semibold)
                        Text(savedRallies.count > 1 ? "Export Rallies" : "Export")
                            .bscFont(size: 15, weight: .semibold)
                    }
                    .foregroundColor(.bscOnPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BSCSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                            .fill(LinearGradient.bscPrimaryGradient)
                    )
                }

                // Post to Community
                Button {
                    if let firstSaved = savedRallies.sorted().first {
                        onPostToCommunity(firstSaved, savedRallies.count > 1)
                    }
                } label: {
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: savedRallies.count > 1 ? "square.stack.fill" : "paperplane.fill")
                            .bscFont(size: 15, weight: .semibold)
                        Text(savedRallies.count > 1 ? "Post Rallies" : "Post")
                            .bscFont(size: 15, weight: .semibold)
                    }
                    .foregroundColor(.bscTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BSCSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                            .stroke(Color.bscSurfaceBorder, lineWidth: 1.5)
                            .fill(Color.bscBackgroundElevated)
                    )
                }
            }

            // Edit timeline (icon-only in compact height)
            Button(action: onEditTimeline) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                    .frame(minWidth: BSCTouchTarget.standard, minHeight: BSCTouchTarget.standard)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                            .stroke(Color.bscSurfaceBorder, lineWidth: 1.5)
                            .fill(Color.bscBackgroundElevated)
                    )
            }
            .accessibilityLabel("Add or fix rallies")

            // Done
            Button(action: onDismiss) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "checkmark")
                        .bscFont(size: 15, weight: .semibold)
                    Text("Done")
                        .bscFont(size: 15, weight: .semibold)
                }
                .foregroundColor(.bscTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BSCSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                        .fill(Color.bscSurfaceGlass)
                        .overlay(
                            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    private var regularBottomActions: some View {
        VStack(spacing: BSCSpacing.md) {
            if !savedRallies.isEmpty {
                // Export to Camera Roll
                Button(action: onExport) {
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "square.and.arrow.down")
                            .bscFont(size: 16, weight: .semibold)
                        // Count omitted for the same reason as Post: this opens the
                        // picker, where the user chooses what actually gets exported.
                        Text(savedRallies.count > 1 ? "Export Rallies" : "Export Rally")
                            .bscFont(size: 16, weight: .semibold)
                    }
                    .foregroundColor(.bscOnPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BSCSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                            .fill(LinearGradient.bscPrimaryGradient)
                    )
                }

                // Post to Community
                Button {
                    if let firstSaved = savedRallies.sorted().first {
                        onPostToCommunity(firstSaved, savedRallies.count > 1)
                    }
                } label: {
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: savedRallies.count > 1 ? "square.stack.fill" : "paperplane.fill")
                            .bscFont(size: 16, weight: .semibold)
                        // Count deliberately omitted: this opens the picker, where the
                        // user chooses which of the saved rallies actually go up.
                        Text(savedRallies.count > 1
                             ? "Post Rallies"
                             : "Post to Community")
                            .bscFont(size: 16, weight: .semibold)
                    }
                    .foregroundColor(.bscTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BSCSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                            .stroke(Color.bscSurfaceBorder, lineWidth: 1.5)
                            .fill(Color.bscBackgroundElevated)
                    )
                }
            }

            // Edit timeline (add missed rallies, delete false positives)
            Button(action: onEditTimeline) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .bscFont(size: 16, weight: .semibold)
                    Text("Add or Fix Rallies")
                        .bscFont(size: 16, weight: .semibold)
                }
                .foregroundColor(.bscTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BSCSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                        .stroke(Color.bscSurfaceBorder, lineWidth: 1.5)
                        .fill(Color.bscBackgroundElevated)
                )
            }

            // Done
            Button(action: onDismiss) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "checkmark")
                        .bscFont(size: 16, weight: .semibold)
                    Text("Done")
                        .bscFont(size: 16, weight: .semibold)
                }
                .foregroundColor(.bscTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BSCSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                        .fill(Color.bscSurfaceGlass)
                        .overlay(
                            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                        )
                )
            }
        }
    }
}

// MARK: - Rally Overview Cell

private struct RallyOverviewCell: View {
    let url: URL
    let index: Int
    let isSaved: Bool
    let isRemoved: Bool
    var isFavorited: Bool = false
    let thumbnailCache: RallyThumbnailCache

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    BSCSkeletonView()
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .stroke(borderColor, lineWidth: 2)
            )
            .bscShadow(BSCShadow.sm)

            // Rally number badge
            Text("\(index + 1)")
                .bscFont(size: 11, weight: .bold)
                .foregroundColor(.bscOnMedia)
                .padding(.horizontal, BSCSpacing.sm)
                .padding(.vertical, BSCSpacing.xxs)
                .background(
                    Capsule()
                        .fill(Color.bscMediaScrimBase.opacity(0.7))
                )
                .padding(BSCSpacing.xs)

            // Star badge for favorited rallies
            if isFavorited {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "star.fill")
                            .bscFont(size: 14, weight: .bold)
                            .foregroundColor(.bscPrimary)
                            .shadow(color: Color.bscMediaScrimBase.opacity(0.5), radius: 2)
                            .padding(BSCSpacing.xs)
                    }
                    Spacer()
                }
            }
        }
        .accessibilityLabel("Rally \(index + 1), \(rallyStatus)")
        .onAppear {
            thumbnail = thumbnailCache.getThumbnail(for: url)
        }
        .task {
            guard thumbnail == nil else { return }
            thumbnail = await thumbnailCache.getThumbnailAsync(for: url)
        }
    }

    private var rallyStatus: String {
        if isFavorited { return "favorited" }
        if isSaved { return "saved" }
        if isRemoved { return "removed" }
        return "unsorted"
    }

    private var borderColor: Color {
        if isFavorited { return .bscPrimaryText }
        if isSaved { return .bscSuccessText }
        if isRemoved { return .bscErrorText }
        return Color.bscOnMedia.opacity(0.1)
    }
}

// MARK: - Rally Cell Button Style

private struct RallyCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.bscQuick, value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview("RallyOverviewSheet") {
    RallyOverviewSheet(
        rallyVideoURLs: (0..<12).map { URL(string: "file:///rally_\($0)")! },
        savedRallies: [0, 2, 5],
        removedRallies: [1, 3],
        currentIndex: 4,
        thumbnailCache: RallyThumbnailCache(),
        onSelectRally: { _ in },
        onExport: {},
        onPostToCommunity: { _, _ in },
        onSaveAll: {},
        onDeselectAll: {},
        onEditTimeline: {},
        onDismiss: {}
    )
}
