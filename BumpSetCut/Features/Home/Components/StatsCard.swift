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
                    .bscFont(size: 16, weight: .semibold)
                    .foregroundColor(stat.color)
            }

            // Value
            Text(stat.value)
                .bscFont(size: 22, weight: .bold)
                .foregroundColor(.bscTextPrimary)

            // Label
            Text(stat.label)
                .bscFont(size: 10, weight: .medium)
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
                        .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)

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
                    .bscFont(size: 18, weight: .semibold)
                    .foregroundColor(color)
            }

            // Text
            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(value)
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text(label)
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextSecondary)
            }

            Spacer()
        }
        .bscGlass(cornerRadius: BSCRadius.lg, padding: BSCSpacing.md)
    }
}

// MARK: - Sign-In Card
/// Fills the stats slot while signed out — lifetime stats live on the account.
struct StatsSignInCard: View {
    let onSignIn: () -> Void

    var body: some View {
        BSCCard(style: .glass, cornerRadius: BSCRadius.lg, padding: BSCSpacing.md) {
            HStack(spacing: BSCSpacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.bscPrimary.opacity(0.15))
                        .frame(width: 36, height: 36)

                    Image(systemName: "chart.bar.fill")
                        .bscFont(size: 16, weight: .semibold)
                        .foregroundColor(.bscPrimaryText)
                }

                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text("Your stats live on your account")
                        .bscFont(size: 15, weight: .semibold)
                        .foregroundColor(.bscTextPrimary)

                    Text("Sign in to see rallies found and time cut")
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }

                Spacer(minLength: BSCSpacing.sm)

                Button(action: onSignIn) {
                    Text("Sign In")
                        .bscFont(size: 14, weight: .semibold)
                        .foregroundColor(.bscOnPrimary)
                        .padding(.horizontal, BSCSpacing.md)
                        .frame(minHeight: 36)
                        .background(LinearGradient.bscPrimaryGradient)
                        .clipShape(Capsule())
                }
                .accessibilityIdentifier(AccessibilityID.Home.statsSignIn)
            }
        }
    }
}

// MARK: - Preview
#Preview("StatsCard") {
    VStack(spacing: BSCSpacing.lg) {
        StatsCard(stats: [
            StatItem(icon: "video.fill", value: "24", label: "Videos", color: .bscBlue),
            StatItem(icon: "figure.volleyball", value: "156", label: "Rallies", color: .bscWarmAccent),
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
