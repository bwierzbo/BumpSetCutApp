import SwiftUI

// MARK: - StatsCard
/// Glass card displaying video and rally statistics
struct StatsCard: View {
    let stats: [StatItem]
    var isLoading: Bool = false

    @State private var hasAppeared = false

    var body: some View {
        BSCCard(style: .glass, cornerRadius: BSCRadius.lg, padding: BSCSpacing.md) {
            if isLoading {
                loadingView
            } else {
                statsContent
            }
        }
    }

    // MARK: - Stats Content
    private var statsContent: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                statItem(stat, index: index)

                if index < stats.count - 1 {
                    divider
                }
            }
        }
    }

    // MARK: - Stat Item
    private func statItem(_ stat: StatItem, index: Int) -> some View {
        VStack(spacing: 6) {
            // Icon
            ZStack {
                Circle()
                    .fill(stat.color.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: stat.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(stat.color)
            }

            // Value
            Text(stat.value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.bscTextPrimary)

            // Label
            Text(stat.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.bscTextSecondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .opacity(hasAppeared ? 1 : 0)
        .animation(
            .bscSpring.delay(Double(index) * 0.05),
            value: hasAppeared
        )
        .onAppear {
            hasAppeared = true
        }
    }

    // MARK: - Divider
    private var divider: some View {
        Rectangle()
            .fill(Color.bscSurfaceBorder)
            .frame(width: 1, height: 50)
    }

    // MARK: - Loading View
    private var loadingView: some View {
        HStack(spacing: BSCSpacing.lg) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(spacing: BSCSpacing.sm) {
                    Circle()
                        .fill(Color.bscSurfaceGlass)
                        .frame(width: 44, height: 44)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.bscSurfaceGlass)
                        .frame(width: 40, height: 24)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.bscSurfaceGlass)
                        .frame(width: 60, height: 12)
                }
                .frame(maxWidth: .infinity)
                .bscShimmer()
            }
        }
    }
}

// MARK: - Single Stat Card
/// A compact single statistic display
struct SingleStatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: BSCSpacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(color)
            }

            // Text
            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(value)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.bscTextSecondary)
            }

            Spacer()
        }
        .bscGlass(cornerRadius: BSCRadius.lg, padding: BSCSpacing.md)
    }
}

// MARK: - Preview
#Preview("StatsCard") {
    VStack(spacing: BSCSpacing.lg) {
        StatsCard(stats: [
            StatItem(icon: "video.fill", value: "24", label: "Videos", color: .bscBlue),
            StatItem(icon: "figure.volleyball", value: "156", label: "Rallies", color: .bscOrange),
            StatItem(icon: "checkmark.seal.fill", value: "18", label: "Processed", color: .bscTeal)
        ])

        StatsCard(stats: [], isLoading: true)

        SingleStatCard(
            icon: "video.fill",
            value: "24",
            label: "Total Videos",
            color: .bscBlue
        )
    }
    .padding()
    .background(Color.bscBackground)
}
