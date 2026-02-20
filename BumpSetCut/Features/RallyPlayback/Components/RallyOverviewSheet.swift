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
    let onDismiss: () -> Void

    @State private var appeared = false

    private let columns = [
        GridItem(.flexible(), spacing: BSCSpacing.md),
        GridItem(.flexible(), spacing: BSCSpacing.md),
        GridItem(.flexible(), spacing: BSCSpacing.md)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, BSCSpacing.sm)
                .padding(.bottom, BSCSpacing.md)

            // Header
            headerSection

            // Thumbnail grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: BSCSpacing.md) {
                    ForEach(0..<rallyVideoURLs.count, id: \.self) { index in
                        rallyCell(index: index)
                            .bscStaggered(index: index)
                            .onTapGesture {
                                onSelectRally(index)
                            }
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

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: BSCSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.bscSuccess)
                .symbolEffect(.bounce, value: appeared)

            Text("Review Complete")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.bscTextPrimary)

            // Compact stats pill row
            HStack(spacing: BSCSpacing.lg) {
                statPill(count: savedRallies.count, label: "saved", color: .bscSuccess)
                statPill(count: removedRallies.count, label: "removed", color: .bscError)
                if !favoritedRallies.isEmpty {
                    statPill(count: favoritedRallies.count, label: "favorited", color: .bscPrimary)
                }
            }
            .padding(.horizontal, BSCSpacing.xl)

            // Quick select/deselect actions
            HStack(spacing: BSCSpacing.md) {
                Button {
                    onSaveAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Save All")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.bscSuccess)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscSuccess.opacity(0.15))
                    .clipShape(Capsule())
                }
                .disabled(savedRallies.count == rallyVideoURLs.count)
                .opacity(savedRallies.count == rallyVideoURLs.count ? 0.4 : 1.0)

                Button {
                    onDeselectAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .bold))
                        Text("Clear All")
                            .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 13, weight: .medium))
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
        VStack(spacing: BSCSpacing.md) {
            if !savedRallies.isEmpty {
                // Export to Camera Roll
                Button(action: onExport) {
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Export \(savedRallies.count) \(savedRallies.count == 1 ? "Rally" : "Rallies")")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
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
                            .font(.system(size: 16, weight: .semibold))
                        Text(savedRallies.count > 1
                             ? "Post \(savedRallies.count) Rallies"
                             : "Post to Community")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BSCSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
                            .fill(Color.bscBackgroundElevated)
                    )
                }
            }

            // Done
            Button(action: onDismiss) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
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
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.top, BSCSpacing.md)
        .padding(.bottom, BSCSpacing.lg)
        .background(Color.bscBackground)
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
                    ZStack {
                        Color.bscSurfaceGlass
                        ProgressView()
                            .tint(.white.opacity(0.5))
                            .scaleEffect(0.8)
                    }
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .stroke(borderColor, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.2), radius: BSCShadow.sm.radius)

            // Rally number badge
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, BSCSpacing.sm)
                .padding(.vertical, BSCSpacing.xxs)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.7))
                )
                .padding(BSCSpacing.xs)

            // Star badge for favorited rallies
            if isFavorited {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "star.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.bscPrimary)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(BSCSpacing.xs)
                    }
                    Spacer()
                }
            }
        }
        .accessibilityLabel("Rally \(index + 1), \(rallyStatus)")
        .accessibilityAddTraits(.isButton)
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
        if isFavorited { return .bscPrimary.opacity(0.7) }
        if isSaved { return .bscSuccess.opacity(0.7) }
        if isRemoved { return .bscError.opacity(0.7) }
        return Color.white.opacity(0.1)
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
        onDismiss: {}
    )
}
