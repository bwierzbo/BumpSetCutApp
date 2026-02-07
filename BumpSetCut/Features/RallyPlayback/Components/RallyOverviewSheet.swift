import SwiftUI

// MARK: - Rally Overview Sheet

struct RallyOverviewSheet: View {
    let rallyVideoURLs: [URL]
    let savedRallies: Set<Int>
    let removedRallies: Set<Int>
    let currentIndex: Int
    let thumbnailCache: RallyThumbnailCache
    let onSelectRally: (Int) -> Void
    let onExport: () -> Void
    let onDismiss: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: BSCSpacing.md),
        GridItem(.flexible(), spacing: BSCSpacing.md),
        GridItem(.flexible(), spacing: BSCSpacing.md)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Summary bar
                summaryBar
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.vertical, BSCSpacing.md)

                // Thumbnail grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: BSCSpacing.md) {
                        ForEach(0..<rallyVideoURLs.count, id: \.self) { index in
                            rallyCell(index: index)
                                .onTapGesture {
                                    onSelectRally(index)
                                    onDismiss()
                                }
                        }
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.bottom, BSCSpacing.xl)
                }

                // Export button
                if !savedRallies.isEmpty {
                    exportButton
                        .padding(.horizontal, BSCSpacing.lg)
                        .padding(.bottom, BSCSpacing.lg)
                }
            }
            .background(Color.black)
            .navigationTitle("Rally Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                        .foregroundColor(.bscOrange)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: BSCSpacing.lg) {
            summaryItem(count: savedRallies.count, label: "saved", color: .bscSuccess)
            summaryItem(count: removedRallies.count, label: "removed", color: .bscError)
            summaryItem(count: remainingCount, label: "remaining", color: .white.opacity(0.6))
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                .fill(Color.bscSurfaceGlass)
        )
    }

    private var remainingCount: Int {
        rallyVideoURLs.count - savedRallies.count - removedRallies.count
    }

    private func summaryItem(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rally Cell

    private func rallyCell(index: Int) -> some View {
        let isCurrent = index == currentIndex
        let url = rallyVideoURLs[index]

        return ZStack(alignment: .topTrailing) {
            // Thumbnail
            Group {
                if let thumbnail = thumbnailCache.getThumbnail(for: url) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(minHeight: 100, maxHeight: 140)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(isCurrent ? Color.bscOrange : Color.clear, lineWidth: 3)
            )

            // Status badge
            if savedRallies.contains(index) {
                statusBadge(icon: "heart.fill", color: .bscSuccess)
            } else if removedRallies.contains(index) {
                statusBadge(icon: "xmark", color: .bscError)
            }

            // Rally number
            VStack {
                Spacer()
                HStack {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.6))
                        )
                        .padding(BSCSpacing.xs)
                    Spacer()
                }
            }
        }
    }

    private func statusBadge(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color))
            .padding(BSCSpacing.xs)
    }

    // MARK: - Export Button

    private var exportButton: some View {
        Button(action: onExport) {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                Text("Export \(savedRallies.count) Saved")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                    .fill(Color.bscOrange)
            )
        }
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
        onDismiss: {}
    )
}
